# Live validation round 2 — harden contributions observation against slow forge reads

- Change under test: `bin/fm-contributions.sh` on `fm/harden-contributions-observation-retries`.
  Base `ac0811c`, first fix `1fa7d8a`, round-1 fix `f8ecd43`, plus the test-phase fix from
  this round (initialize `BUDGET_EXHAUSTED` in `poll()`) left in the gate worktree.
- Product driven: `bin/fm-contributions.sh poll`, run from the gate worktree in a disposable
  marked lab home (`bin/fm-lab-home.sh create`, removed at the end of the run), against the
  **real GitHub API** with the machine's logged-in `gh` 2.97.0 (PR `kunchenguid/firstmate#6780`,
  head `e032f75…`). Lab home, proxy and the base source copy were all removed when the harness exited.
- Perturbation: the local CONNECT proxy from round 1 (`raw/perturbing-connect-proxy.pl`)
  delays or 502s a chosen CONNECT ordinal to `api.github.com:443`. gh, TLS and the forge
  responses are real; only the network path is perturbed, reproducing the recorded latency
  spikes and transient read failures on demand.
- Harness: `raw/r2-live-harness.sh`; verbatim per-scenario transcripts `raw/transcript-r2-*.txt`;
  combined run `raw/r2-harness-run.log`.

## Results

| # | Scenario | Perturbation | Result |
|---|----------|--------------|--------|
| S1 | Healthy poll, no proxy | none | pass — fresh observation, no error, no wake |
| S1b | Healthy poll through the proxy | passthrough | pass — fresh observation, no wake |
| S2 | Core read spikes to 7s (the recorded 7.5s class, past the old 5s bound) | CONNECT #1 delayed 7s | pass — read completes, fresh observation, no wake (elapsed 9s) |
| S3 | Read past the raised bound | CONNECT #1 delayed 14s | pass — killed at the 10s bound, one attempt, silent, record untouched |
| S4 | One transient forge failure (the reported wake) | CONNECT #1 502 | pass — retried once, observation recorded, no error, no wake |
| S5 | Transient failure whose retry the budget cuts | #1 502, #2 delayed 25s | pass — budget refusal: record untouched, no error, no wake |
| S6 | Persistent outage, two consecutive polls | #1–#4 502 | pass — wake once for the episode, second poll silent; error names the failed call; exactly one retry per poll |
| S7 | Shared URL (two owners), transient failure | #1 502 | pass — one retry serves both owners, both fresh, no wake |
| S8 | Genuine GitHub failure + unreadable GitLab URL, GitHub-first | #1–#2 502 | pass — GitHub record keeps its own stderr detail, GitLab record stays generic (round-1 regression fixed) |
| S8b | Same poll rotated so the unreadable GitLab URL is visited first | #1–#2 502 | **fail → fixed this round** — poll aborted with `BUDGET_EXHAUSTED: unbound variable`; after the fix, pass: GitLab generic, GitHub keeps its own detail |
| S8-base | Same GitHub-first poll at base `ac0811c` | #1 502 | base records only the generic message (no stderr detail) for both records |

## Round-2 finding: rotated ordering aborted the poll

`poll()`'s new retry check reads `$BUDGET_EXHAUSTED`, but the variable is only assigned
inside `observe()`/`forge()`. A canonical URL this observer cannot read (any non-GitHub
`/-/merge_requests/N`, which poll necessarily records as unmeasured) returns from `observe()`
before that assignment. When such a URL is first in the rotation, the retry check expanded
an unset variable and `set -u` killed the poll:

```
bin/fm-contributions.sh: line 416: BUDGET_EXHAUSTED: unbound variable
poll rc=1
```

The base commit was reachable through the same ordering at its `continue` line
(`... line 399: BUDGET_EXHAUSTED: unbound variable`), so the crash predates this change; but
the change's new retry line is now the first dereference, and its regression test pinned only
the GitHub-first order. Fix: initialize `BUDGET_EXHAUSTED=0` in `poll()` before the loop
(S8b after the fix: `rc=0`, GitLab generic error, GitHub own stderr detail, two retry
attempts on the wire).

Reproduction as a red/green regression test (fixture-level, stub forge):
`tests/fm-contributions.test.sh::test_rotated_unreadable_url_first_does_not_abort_poll`
(`2026-09-16T08:05:00Z` lands one five-minute rotation bucket past the existing cross-URL
test's clock, so the two-URL set visits GitLab first).

- Red (unpatched): `not ok - a poll whose first URL is unreadable aborted`
- Green (patched): `ok - a rotated poll starting on an unreadable URL still records every URL error`
- Full focused file after the fix: 54 `ok`, 0 `not ok` (`raw/focused-test-run-r2.log`).

## Transcript index

- `raw/transcript-r2-s1-healthy-no-proxy.txt`
- `raw/transcript-r2-s1b-healthy-passthrough.txt`
- `raw/transcript-r2-s2-spike-7s-core.txt`
- `raw/transcript-r2-s3-beyond-10s-bound.txt`
- `raw/transcript-r2-s4-single-502-retried-heals.txt`
- `raw/transcript-r2-s5-502-then-budget-cut-retry.txt`
- `raw/transcript-r2-s6-persistent-502-two-polls.txt`
- `raw/transcript-r2-s7-shared-url-transient.txt`
- `raw/transcript-r2-s8-cross-url-detail-github-first.txt`
- `raw/transcript-r2-s8b-cross-url-detail-gitlab-first.txt`
- `raw/transcript-r2-s8-base-cross-url-detail.txt`
- `raw/transcript-r2-s8b-pre-fix-rotated.txt` (live pre-fix reproduction, f8ecd43: rc=1, both records untouched)
- `raw/r2-red-slice.txt` (focused pre-fix red run of the new regression test)
- `raw/r2-harness-run.log` (combined stdout of the harness)
- `raw/focused-test-run-r2.log` (focused test file, post-fix)
