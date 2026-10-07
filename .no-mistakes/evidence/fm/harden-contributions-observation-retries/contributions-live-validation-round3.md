# Live validation round 3 — harden contributions observation against slow forge reads

- Change under test: `bin/fm-contributions.sh` @ `92c1683` (branch
  `fm/harden-contributions-observation-retries`), base `ac0811c`. The target includes the
  original hardening (`1fa7d8a`), the round-1 cross-URL stderr fix (`f8ecd43`), and the
  round-2 rotated-order fix (`92c1683`).
- Product driven: `bin/fm-contributions.sh poll`, run from the gate worktree in a disposable
  marked lab home (`bin/fm-lab-home.sh create`, removed at the end of the run), against the
  **real GitHub API** with the machine's logged-in `gh` 2.97.0 (PR
  `kunchenguid/firstmate#6780`, head `e032f75…`, still open).
- Perturbation: the local CONNECT proxy (`raw/perturbing-connect-proxy.pl`) delays or 502s a
  chosen CONNECT ordinal to `api.github.com:443`. `gh`, TLS and the forge responses are real;
  only the network path is perturbed, reproducing the recorded latency spikes and transient
  read failures on demand.
- A/B legs: unmodified `ac0811c` (base) and `f8ecd43` (round-1 fix, pre-round-2 fix) sources
  were extracted into the throwaway lab.
- Harness: `raw/r3-live-harness.sh`; per-scenario verbatim transcripts
  `raw/transcript-r3-*.txt`; combined run `raw/r3-harness-run.log`.
- Lab home, proxy, base/prefix source copies and the scratch red-slice root were all removed
  when the run exited; the worktree was left clean.

## Results

| # | Scenario | Perturbation | Product | Result |
|---|----------|--------------|---------|--------|
| S1 | Healthy poll, no proxy | none | target | pass — fresh observation, no error, no wake |
| S1b | Healthy poll through the proxy | passthrough | target | pass — fresh observation, no wake |
| S2 | Core read spikes to 7s (recorded 7.5s class, past the old 5s bound) | CONNECT #1 delayed 7s | target | pass — read completes (elapsed 9s), fresh observation, no wake |
| S2-base | Same 7s spike | CONNECT #1 delayed 7s | base | base kills the read at 5s: record untouched (unmeasured), silent |
| S3 | Read past the raised bound | CONNECT #1 delayed 14s | target | pass — killed at the 10s bound, exactly one attempt, silent, record untouched |
| S4 | One transient forge failure (the reported wake) | CONNECT #1 502 | target | pass — retried once, observation recorded, no error, no wake |
| S4-base | Same single 502 | CONNECT #1 502 | base | base wakes `contributions: observation unavailable for <url>` — the reported symptom |
| S5 | Transient failure whose retry is cut by the budget | #1 502, #2 delayed 25s | target | pass — retry attempted once and killed at the 10s bound; record untouched, no wake |
| S6 | Persistent outage, two consecutive polls | #1–#4 502 | target | pass — wake once for the episode, second poll silent; error names the failed call; exactly one retry per poll |
| S7 | Shared URL (two owners), transient failure | #1 502 | target | pass — one retry serves both owners, both fresh, no wake |
| S8 | GitHub failure + unreadable GitLab URL, GitHub-first | #1–#2 502 | target | pass — GitHub record keeps its own stderr detail, GitLab record generic |
| S8b | Same poll rotated so the unreadable GitLab URL is visited first | #1–#2 502 | target | pass — `rc=0`; GitLab generic, GitHub keeps its own detail (round-2 regression fixed) |
| S8b-prefix | Same rotated poll at `f8ecd43` | #1–#2 502 | f8ecd43 | pre-fix abort reproduced: `BUDGET_EXHAUSTED: unbound variable`, `rc=1`, both records untouched |

## Key excerpts

### S2 — 7s spike past the old bound, inside the raised bound (target)

```
$ poll 1/1 rc=0 elapsed=9s
--- poll 1 stdout/stderr (verbatim):
(empty)
--- records after poll 1:
delivery: {"checked_at":"2026-07-15T12:00:00Z","error":null,...,"state":"open"}
--- forge connection log (proxy-19002.log):
12:16:37 #1 api.github.com:443 DELAY 7s begin
12:16:44 #1 api.github.com:443 DELAY 7s end
12:16:44 #1 api.github.com:443 TUNNEL
```

The same 7s delay against base `ac0811c` leaves the record untouched (silent, unmeasured) —
the transient that previously cost the observation.

### S3 — beyond the raised bound stays budget refusal

```
$ poll 1/1 rc=0 elapsed=10s
--- poll 1 stdout/stderr (verbatim):
(empty)
--- records after poll 1:
delivery: {"checked_at":"2026-01-01T00:00:00Z","error":null,...,"state":"open"}
--- forge connection log (proxy-19004.log):
12:16:51 #1 api.github.com:443 DELAY 14s begin
```

Only CONNECT #1 exists in the proxy log: the budget-refused attempt was not retried.

### S4 — one transient 502 is retried and self-heals; base wakes

target:

```
$ poll 1/1 rc=0 elapsed=2s
--- poll 1 stdout/stderr (verbatim):
(empty)
--- records after poll 1:
delivery: {"checked_at":"2026-07-15T12:00:00Z","error":null,...,"state":"open"}
--- forge connection log (proxy-19005.log):
12:17:02 #1 api.github.com:443 FAIL (CONNECT 502)
12:17:02 #2 api.github.com:443 TUNNEL
```

base `ac0811c`:

```
$ poll 1/1 rc=0 elapsed=0s
--- poll 1 stdout/stderr (verbatim):
contributions: observation unavailable for https://github.com/kunchenguid/firstmate/pull/6780
--- record after poll 1:
error:"forge observation unavailable or changed during read"
--- forge connection log (proxy-19006.log):
12:17:04 #1 api.github.com:443 FAIL (CONNECT 502)
```

### S5 — a retry cut by the budget stays unmeasured

```
$ poll 1/1 rc=0 elapsed=10s
--- poll 1 stdout/stderr (verbatim):
(empty)
--- records after poll 1:
delivery: {"checked_at":"2026-01-01T00:00:00Z","error":null,...,"state":"open"}
--- forge connection log (proxy-19007.log):
12:17:04 #1 api.github.com:443 FAIL (CONNECT 502)
12:17:04 #2 api.github.com:443 DELAY 25s begin
```

### S6 — persistent outage: one wake per episode, error names the failed call

```
$ poll 1/2 rc=0
contributions: observation unavailable for https://github.com/kunchenguid/firstmate/pull/6780
record error: "forge observation unavailable or changed during read: Get \"https://api.github.com/repos/kunchenguid/firstmate/pulls/6780\": Bad Gateway"
$ poll 2/2 rc=0
(empty)
record error: unchanged
--- forge connection log (proxy-19008.log):
#1 FAIL #2 FAIL   (poll 1: initial + retry)
#3 FAIL #4 FAIL   (poll 2: initial + retry)
```

### S8b — rotated poll: unreadable GitLab first, poll still completes

```
$ poll 1/1 rc=0
contributions: observation unavailable for https://gitlab.com/foo/bar/-/merge_requests/1
contributions: observation unavailable for https://github.com/kunchenguid/firstmate/pull/6780
delivery: {"error":"forge observation unavailable or changed during read: Get \".../pulls/6780\": Bad Gateway",...}
gitlab:   {"error":"forge observation unavailable or changed during read",...}
--- forge connection log (proxy-19011.log):
#1 api.github.com FAIL (CONNECT 502)
#2 api.github.com FAIL (CONNECT 502)   (one retry)
```

### S8b-prefix — the same ordering at `f8ecd43` aborts

```
$ poll 1/1 rc=1
/tmp/fm-lab.WH6E30/prefix/bin/fm-contributions.sh: line 416: BUDGET_EXHAUSTED: unbound variable
--- records after poll 1:
delivery: {"checked_at":"2026-01-01T00:00:00Z","error":null,...}
gitlab:   {"checked_at":"2026-01-01T00:00:00Z","error":null,...}
--- forge connection log (proxy-19012.log):
12:17:18 proxy listening on 127.0.0.1:19012
```

## Focused regression suite (stub forge, supporting check)

`bash tests/fm-contributions.test.sh` on `92c1683`: **54 ok, 0 not ok**, exit 0
(`raw/focused-test-run-r3.log`). Includes the new targeted checks:

```
ok - a read between the old and raised per-call bounds completes without a wake
ok - one transient forge failure is retried once and self-heals without a wake
ok - a retry cut short by the poll budget stays unmeasured and silent
ok - an unreadable non-GitHub URL records no other URL's forge error detail
ok - a rotated poll starting on an unreadable URL still records every URL error
```

Red slice for the round-2 regression, running the current test file's
`test_rotated_unreadable_url_first_does_not_abort_poll` against `f8ecd43`
(`raw/r3-red-slice-rotated.txt`):

```
/tmp/r3-red.cDvDhF/bin/fm-contributions.sh: line 416: BUDGET_EXHAUSTED: unbound variable
not ok - a poll whose first URL is unreadable aborted
not ok - 1 contribution regressions
```

## Notes

- The head-changed-during-observation retry is part of the same retry path but cannot be
  forced deterministically against the live GitHub API (would require altering the real PR
  head). It is covered by the fixture test
  `test_shared_url_observed_once` (`head` mode expects the retry and the generic error).
- No production consumer in `bin/` matches the exact error string; the recorded message
  keeps the existing `forge observation unavailable or changed during read` prefix and
  appends `: <first bounded stderr line>`, shown live in S6.

## Transcript index

- `raw/transcript-r3-s1-healthy-no-proxy.txt`
- `raw/transcript-r3-s1b-healthy-passthrough.txt`
- `raw/transcript-r3-s2-spike-7s-core.txt`
- `raw/transcript-r3-s2-base-spike-7s-core.txt`
- `raw/transcript-r3-s3-beyond-10s-bound.txt`
- `raw/transcript-r3-s4-single-502-retried-heals.txt`
- `raw/transcript-r3-s4-base-single-502-wakes.txt`
- `raw/transcript-r3-s5-retry-budget-cut.txt`
- `raw/transcript-r3-s6-persistent-502-two-polls.txt`
- `raw/transcript-r3-s7-shared-url-transient.txt`
- `raw/transcript-r3-s8-cross-url-detail-github-first.txt`
- `raw/transcript-r3-s8b-cross-url-detail-gitlab-first.txt`
- `raw/transcript-r3-s8b-prefix-rotated-aborts.txt`
- `raw/r3-harness-run.log` (combined stdout of the harness)
- `raw/focused-test-run-r3.log` (focused test file, 54/54)
- `raw/r3-red-slice-rotated.txt` (pre-fix red slice)
- `raw/r3-live-harness.sh` (harness used this round)
