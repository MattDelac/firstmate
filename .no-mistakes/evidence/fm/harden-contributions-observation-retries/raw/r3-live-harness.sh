#!/usr/bin/env bash
# Round-3 live validation harness for the contributions-observation hardening
# on branch fm/harden-contributions-observation-retries (target 92c1683).
#
# Drives the real bin/fm-contributions.sh poll from the gate worktree against
# the real GitHub API with the machine's logged-in gh, using a disposable
# marked lab home (bin/fm-lab-home.sh create, removed on exit) and a local
# perturbing CONNECT proxy (raw/perturbing-connect-proxy.pl) that delays or
# 502s chosen CONNECT ordinals. TLS/gh/the forge response are real; only the
# network path is perturbed, to reproduce the recorded latency spikes and
# transient read failures on demand.
#
# A/B legs extract ac0811c (base) and f8ecd43 (round-1 fix, pre-round-2 fix)
# from this repository into the throwaway lab.
#
# Usage: bash raw/r3-live-harness.sh
set -u

ROOT=/home/matt/.no-mistakes/worktrees/62c0a9471fe0/01M4BFZH3G7J8QYS8V515S9SC1
EVID=/home/matt/.no-mistakes/evidence/01M4BFZH3G7J8QYS8V515S9SC1
RAW="$EVID/raw"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
PROXY=/tmp/r3-proxy.pl
BASE="$LAB/base"
PREFIX="$LAB/prefix"
PROXY_PID=
PORT=19000

cleanup() {
  [ -z "$PROXY_PID" ] || kill "$PROXY_PID" 2>/dev/null
  pkill -f "$PROXY" 2>/dev/null
  rm -rf -- "$LAB"
}
trap cleanup EXIT

"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux" "$BASE" "$PREFIX"
git -C "$ROOT" archive ac0811c bin | tar -x -C "$BASE" || exit 1
git -C "$ROOT" archive f8ecd43 bin | tar -x -C "$PREFIX" || exit 1
cp "$RAW/perturbing-connect-proxy.pl" "$PROXY" || exit 1

PR=https://github.com/kunchenguid/firstmate/pull/6780
GL=https://gitlab.com/foo/bar/-/merge_requests/1
HEAD=e032f755e72ef9771458ae0064ef215900062c3a
TARGET="$ROOT/bin/fm-contributions.sh"
BASE_SCRIPT="$BASE/bin/fm-contributions.sh"
PREFIX_SCRIPT="$PREFIX/bin/fm-contributions.sh"

# Two fixed clocks one bucket apart: with two known URLs the rotation offset is
# bucket % 2, so these pin GitHub-first and GitLab-first processing orders.
_ep=$(date -u -d 2026-07-15T12:00:00Z +%s)
if [ $(( (_ep / 300) % 2 )) -eq 1 ]; then _ep=$((_ep + 300)); fi
NOW_GH_FIRST=$(date -u -d "@$_ep" +%Y-%m-%dT%H:%M:%SZ)
NOW_GL_FIRST=$(date -u -d "@$((_ep + 300))" +%Y-%m-%dT%H:%M:%SZ)

rec() { # dir task url
  jq -n --arg t "$2" --arg u "$3" --arg head "$HEAD" '
    {schema:"fm-contributions.v1",task:$t,records:[{
      url:$u,kind:"pr",checked_at:"2026-01-01T00:00:00Z",error:null,
      pending:[],seen:[],notified:[],verdict:null,
      observation:{head:$head,state:"open",draft:false,mergeable:"mergeable",
        can_merge:false,review_decision:"APPROVED",checks:[],reviews:[],events:[]}}]}' \
    > "$1/contributions.json"
}

fixture_reset() { # mode
  local mode=$1
  rm -rf "$LAB/data" "$LAB/state"
  mkdir -p "$LAB/data" "$LAB/state"
  printf '# Backlog\n\n## Queued\n' > "$LAB/data/backlog.md"
  printf -- '- [ ] delivery - Contribution %s (repo: sample) (kind: ship)\n' "$PR" >> "$LAB/data/backlog.md"
  mkdir -p "$LAB/data/delivery"
  rec "$LAB/data/delivery" delivery "$PR"
  case "$mode" in
    gitlab)   mkdir -p "$LAB/data/gitlab";   rec "$LAB/data/gitlab"   gitlab   "$GL" ;;
    shared)   mkdir -p "$LAB/data/duplicate"; rec "$LAB/data/duplicate" duplicate "$PR" ;;
  esac
}

start_proxy() { # rules...
  PORT=$((PORT + 1))
  : > "$LAB/proxy-$PORT.log"
  perl "$PROXY" "$PORT" "$LAB/proxy-$PORT.log" "$@" &
  PROXY_PID=$!
  local i=0
  while [ "$i" -lt 50 ]; do
    grep -q 'proxy listening' "$LAB/proxy-$PORT.log" 2>/dev/null && return 0
    sleep 0.1; i=$((i + 1))
  done
  echo "proxy on $PORT did not start" >&2
  return 1
}

stop_proxy() { # port
  [ -z "$PROXY_PID" ] || kill "$PROXY_PID" 2>/dev/null
  [ -z "$PROXY_PID" ] || wait "$PROXY_PID" 2>/dev/null
  [ -z "${1:-}" ] || pkill -f "$PROXY $1" 2>/dev/null
  PROXY_PID=
  return 0
}

records_dump() {
  local f
  for f in "$LAB"/data/*/contributions.json; do
    [ -f "$f" ] || continue
    jq -c '.records[0] | {checked_at, error, fresh_head:.observation.head, state:.observation.state}' "$f" 2>/dev/null \
      | sed "s#^#$(basename "$(dirname "$f")"): #" \
      || echo "$(dirname "$f"): unparsable"
  done
}

wake_dump() {
  if [ -s "$LAB/state/.wake-queue" ]; then cat "$LAB/state/.wake-queue"; else echo '(empty)'; fi
}

# scenario <name> <mode> <now> <product> <npolls> <rules...>
scenario() {
  local name=$1 mode=$2 now=$3 product=$4 npolls=$5
  shift 5
  local out="$RAW/transcript-r3-$name.txt"
  local port=
  {
    echo "=== scenario: $name"
    echo "=== when: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "=== product: $product"
    echo "=== proxy rules: ${*:-<none>}"
    echo "=== budget: 20s, polls: $npolls"
    echo
    fixture_reset "$mode"
    echo "\$ before:"
    records_dump
    if [ "$#" -gt 0 ]; then
      start_proxy "$@"
      port=$PORT
      echo "\$ proxy on 127.0.0.1:$port"
    fi
    local poll i
    for ((i = 1; i <= npolls; i++)); do
      local started ended elapsed out_file
      out_file="$LAB/poll-$i.out"
      started=$(date +%s)
      env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
        -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
        ${port:+HTTPS_PROXY=http://127.0.0.1:$port} \
        FM_HOME="$LAB" FM_CONTRIBUTIONS_NOW="$now" FM_CONTRIBUTIONS_BUDGET=20 \
        "$product" poll > "$out_file" 2>&1
      poll=$?
      ended=$(date +%s)
      elapsed=$((ended - started))
      echo "\$ poll $i/$npolls rc=$poll elapsed=${elapsed}s"
      echo "--- poll $i stdout/stderr (verbatim):"
      cat "$out_file"
      echo "--- records after poll $i:"
      records_dump
    done
    [ -z "$PROXY_PID" ] || { echo "--- forge connection log (proxy-$port.log):"; cat "$LAB/proxy-$port.log"; }
    echo "--- wake queue:"
    wake_dump
    echo "=== end scenario: $name"
    echo
  } > "$out" 2>&1
  stop_proxy "$port"
  cat "$out"
}

scenario s1-healthy-no-proxy plain "$NOW_GH_FIRST" "$TARGET" 1
scenario s1b-healthy-passthrough plain "$NOW_GH_FIRST" "$TARGET" 1 1:delay:0
scenario s2-spike-7s-core plain "$NOW_GH_FIRST" "$TARGET" 1 1:delay:7
scenario s2-base-spike-7s-core plain "$NOW_GH_FIRST" "$BASE_SCRIPT" 1 1:delay:7
scenario s3-beyond-10s-bound plain "$NOW_GH_FIRST" "$TARGET" 1 1:delay:14
scenario s4-single-502-retried-heals plain "$NOW_GH_FIRST" "$TARGET" 1 1:fail
scenario s4-base-single-502-wakes plain "$NOW_GH_FIRST" "$BASE_SCRIPT" 1 1:fail
scenario s5-retry-budget-cut plain "$NOW_GH_FIRST" "$TARGET" 1 1:fail 2:delay:25
scenario s6-persistent-502-two-polls plain "$NOW_GH_FIRST" "$TARGET" 2 1:fail 2:fail 3:fail 4:fail
scenario s7-shared-url-transient shared "$NOW_GH_FIRST" "$TARGET" 1 1:fail
scenario s8-cross-url-detail-github-first gitlab "$NOW_GH_FIRST" "$TARGET" 1 1:fail 2:fail
scenario s8b-cross-url-detail-gitlab-first gitlab "$NOW_GL_FIRST" "$TARGET" 1 1:fail 2:fail
scenario s8b-prefix-rotated-aborts gitlab "$NOW_GL_FIRST" "$PREFIX_SCRIPT" 1 1:fail 2:fail

echo "harness complete; lab removed"
