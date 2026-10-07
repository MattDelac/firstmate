# Live validation — harden contributions observation against slow forge reads

- Change under test: `bin/fm-contributions.sh` @ `1fa7d8a` (branch `fm/harden-contributions-observation-retries`), base `ac0811c`.
- Product driven: `bin/fm-contributions.sh poll` in a disposable marked lab home
  (`bin/fm-lab-home.sh create`), from the gate worktree, against the **real GitHub API**
  with the machine's real logged-in `gh` 2.97.0.
- Perturbation: a local CONNECT proxy (`raw/perturbing-connect-proxy.pl`) that delays or
  502s a chosen CONNECT ordinal to `api.github.com:443`. The product, `gh`, TLS and the forge
  responses are real; only the network path is perturbed, to reproduce the reported latency
  spikes and transient read failures on demand.
- The `base` runs use the unmodified `ac0811c` source extracted from this repository into the
  throwaway lab (`git archive ac0811c`), to show the old behaviour side by side.
- Lab home, proxy, and the base/probe source copies were all removed at the end of this run.

## Results

| # | Scenario | Perturbation | Product | Result |
|---|----------|--------------|---------|--------|
| S0 | Healthy poll, no perturbation | none | fixed | pass — fresh observation, no wake |
| S1 | Healthy poll through the proxy (control) | passthrough | fixed | pass — fresh observation, no wake |
| S2 | Read spikes to ~7.5s (the recorded 7.5s core read) | CONNECT #1 delayed 7s | base | URL left **unmeasured** (record untouched), silent |
| S2 | same | same | fixed | pass — read completes, fresh observation, no wake |
| S3 | Read beyond the raised bound | CONNECT #1 delayed 14s | fixed | pass — killed at the 10s bound (elapsed 10s), exactly one attempt, silent, record untouched |
| S4 | One transient forge failure (the reported wake) | CONNECT #1 502 | base | `contributions: observation unavailable for <url>` + error record — the reported symptom |
| S4 | same | same | fixed | pass — retried once, observation recorded, no error, no wake |
| S5 | Transient failure whose retry the budget cuts | #1 502, #2 delayed 25s | fixed | pass — budget refusal, record untouched, no error, no wake |
| S6 | Persistent forge outage, two consecutive polls | #1-#4 502 | fixed | pass — one wake for the episode; error evidence names the failed call; exactly one retry per poll |
| S7 | Shared URL (two owners), transient failure | #1 502 | fixed | pass — one observation + one retry for both owners, both fresh, no wake |
| S8 | Genuine GitHub failure followed by an unreadable GitLab URL in one poll | #1-#2 502 | fixed | **fail** — the GitLab record inherits the GitHub URL's failed-read detail (see Finding) |
| S8 | same | #1 502 | base | generic error only, no stale detail |
| S8 | same, with a candidate one-line remedy | #1-#2 502 | probe | generic error only; GitHub record keeps its own detail |

## The finding, in one line

`note_forge_error` stores the detail in `$TMP/last-forge.err`, and `observe()` only clears it
*after* its GitHub-scheme check. A canonical-but-unreadable URL (GitLab `merge_requests`,
which poll necessarily records as unmeasured) returns early and therefore inherits the
previous URL's stderr detail. Move the `: > "$TMP/last-forge.err"` reset above the scheme
check; the S8 probe run confirms that remedy.

## Transcripts

### s0-plain

```
=== scenario: s0-plain-healthy (no proxy at all)
=== when: 2026-10-07T15:50:00Z
$ LAB=$LAB /tmp/fm-lab.7alkC6/fixture.sh reset
$ before: {"task":"delivery","checked_at":"2026-01-01T00:00:00Z","error":null,"pending":0,"head":"e032f755e72ef9771458ae0064ef215900062c3a","state":"open"}
$ env -u NO_MISTAKES_GATE ... FM_HOME=$LAB bin/fm-contributions.sh poll
poll rc=0 elapsed=2s
--- poll stdout/stderr (verbatim):

--- record after:
{"task":"delivery","checked_at":"2026-10-07T15:50:00Z","error":null,"pending":0,"head":"e032f755e72ef9771458ae0064ef215900062c3a","state":"open"}
--- wake queue:
(empty)
=== end scenario: s0-plain-healthy
```

### s1-proxy-passthrough

```
=== scenario: s1-proxy-passthrough
=== when: 2026-10-07T15:50:02Z
=== product: bin/fm-contributions.sh
=== proxy rules (CONNECT ordinal:action[:seconds]): 
=== budget: 20s, polls: 1

$ LAB=$LAB /tmp/fm-lab.7alkC6/fixture.sh reset
$ before: {"task":"delivery","checked_at":"2026-01-01T00:00:00Z","error":null,"pending":0,"head":"e032f755e72ef9771458ae0064ef215900062c3a","state":"open"}
$ /tmp/fm-lab.7alkC6/proxy-run.sh 18920 
$ env -u NO_MISTAKES_GATE ... FM_HOME=$LAB HTTPS_PROXY=http://127.0.0.1:18920 FM_CONTRIBUTIONS_BUDGET=20 bin/fm-contributions.sh poll   # poll 1/1
poll 1 rc=0 elapsed=2s
--- poll 1 stdout/stderr (verbatim):

--- record after poll 1:
{"task":"delivery","checked_at":"2026-10-07T15:50:03Z","error":null,"pending":0,"head":"e032f755e72ef9771458ae0064ef215900062c3a","state":"open"}
--- wake queue:
(empty)
--- forge connection log (proxy-18920.log):
11:50:02 proxy listening on 127.0.0.1:18920
11:50:03 #1 api.github.com:443 TUNNEL
11:50:04 #1 api.github.com:443 CLOSE
11:50:04 #2 api.github.com:443 TUNNEL
11:50:04 #7 api.github.com:443 TUNNEL
11:50:04 #4 api.github.com:443 TUNNEL
11:50:04 #6 api.github.com:443 TUNNEL
11:50:04 #5 api.github.com:443 TUNNEL
11:50:04 #3 api.github.com:443 TUNNEL
11:50:04 #5 api.github.com:443 CLOSE
11:50:04 #6 api.github.com:443 CLOSE
11:50:04 #2 api.github.com:443 CLOSE
11:50:04 #4 api.github.com:443 CLOSE
11:50:05 #7 api.github.com:443 CLOSE
11:50:05 #3 api.github.com:443 CLOSE
11:50:05 #8 api.github.com:443 TUNNEL
11:50:05 #8 api.github.com:443 CLOSE
=== end scenario: s1-proxy-passthrough
```

### s2-fixed

```
=== scenario: s2-fixed
=== when: 2026-10-07T15:44:54Z
=== product: bin/fm-contributions.sh
=== proxy rules (CONNECT ordinal:action[:seconds]): 1:delay:7
=== budget: 20s

$ LAB=$LAB /tmp/fm-lab.7alkC6/fixture.sh reset
$ before: {"checked_at":"2026-01-01T00:00:00Z","error":null,"head":"e032f755e72ef9771458ae0064ef215900062c3a","state":"open","reviews":0,"events":0}
$ /tmp/fm-lab.7alkC6/proxy-run.sh 18921 1:delay:7
$ env -u NO_MISTAKES_GATE ... FM_HOME=$LAB HTTPS_PROXY=http://127.0.0.1:18921 FM_CONTRIBUTIONS_BUDGET=20 bin/fm-contributions.sh poll
poll rc=0 elapsed=10s
--- poll stdout/stderr (verbatim):

--- record after:
{"checked_at":"2026-10-07T15:44:55Z","error":null,"head":"e032f755e72ef9771458ae0064ef215900062c3a","state":"open","reviews":0,"events":0}
--- wake queue:
(empty)
--- forge connection log (proxy-18921.log):
11:44:54 proxy listening on 127.0.0.1:18921
11:44:56 #1 api.github.com:443 DELAY 7s begin
11:45:03 #1 api.github.com:443 DELAY 7s end
11:45:03 #1 api.github.com:443 TUNNEL
11:45:03 #1 api.github.com:443 CLOSE
11:45:04 #2 api.github.com:443 TUNNEL
11:45:04 #6 api.github.com:443 TUNNEL
11:45:04 #4 api.github.com:443 TUNNEL
11:45:04 #7 api.github.com:443 TUNNEL
11:45:04 #5 api.github.com:443 TUNNEL
11:45:04 #3 api.github.com:443 TUNNEL
11:45:04 #2 api.github.com:443 CLOSE
11:45:04 #7 api.github.com:443 CLOSE
11:45:04 #5 api.github.com:443 CLOSE
11:45:04 #6 api.github.com:443 CLOSE
11:45:04 #4 api.github.com:443 CLOSE
11:45:04 #3 api.github.com:443 CLOSE
11:45:04 #8 api.github.com:443 TUNNEL
11:45:05 #8 api.github.com:443 CLOSE
=== end scenario: s2-fixed
```

### s2-base

```
=== scenario: s2-base
=== when: 2026-10-07T15:45:08Z
=== product: /tmp/fm-lab.7alkC6/base/bin/fm-contributions.sh
=== proxy rules (CONNECT ordinal:action[:seconds]): 1:delay:7
=== budget: 20s

$ LAB=$LAB /tmp/fm-lab.7alkC6/fixture.sh reset
$ before: {"checked_at":"2026-01-01T00:00:00Z","error":null,"head":"e032f755e72ef9771458ae0064ef215900062c3a","state":"open","reviews":0,"events":0}
$ /tmp/fm-lab.7alkC6/proxy-run.sh 18922 1:delay:7
$ env -u NO_MISTAKES_GATE ... FM_HOME=$LAB HTTPS_PROXY=http://127.0.0.1:18922 FM_CONTRIBUTIONS_BUDGET=20 /tmp/fm-lab.7alkC6/base/bin/fm-contributions.sh poll
poll rc=0 elapsed=5s
--- poll stdout/stderr (verbatim):

--- record after:
{"checked_at":"2026-01-01T00:00:00Z","error":null,"head":"e032f755e72ef9771458ae0064ef215900062c3a","state":"open","reviews":0,"events":0}
--- wake queue:
(empty)
--- forge connection log (proxy-18922.log):
11:45:08 proxy listening on 127.0.0.1:18922
11:45:09 #1 api.github.com:443 DELAY 7s begin
=== end scenario: s2-base
```

### s3-beyond-bound

```
=== scenario: s3-beyond-bound
=== when: 2026-10-07T15:45:17Z
=== product: bin/fm-contributions.sh
=== proxy rules (CONNECT ordinal:action[:seconds]): 1:delay:14
=== budget: 20s

$ LAB=$LAB /tmp/fm-lab.7alkC6/fixture.sh reset
$ before: {"checked_at":"2026-01-01T00:00:00Z","error":null,"head":"e032f755e72ef9771458ae0064ef215900062c3a","state":"open","reviews":0,"events":0}
$ /tmp/fm-lab.7alkC6/proxy-run.sh 18923 1:delay:14
$ env -u NO_MISTAKES_GATE ... FM_HOME=$LAB HTTPS_PROXY=http://127.0.0.1:18923 FM_CONTRIBUTIONS_BUDGET=20 bin/fm-contributions.sh poll
poll rc=0 elapsed=10s
--- poll stdout/stderr (verbatim):

--- record after:
{"checked_at":"2026-01-01T00:00:00Z","error":null,"head":"e032f755e72ef9771458ae0064ef215900062c3a","state":"open","reviews":0,"events":0}
--- wake queue:
(empty)
--- forge connection log (proxy-18923.log):
11:45:17 proxy listening on 127.0.0.1:18923
11:45:18 #1 api.github.com:443 DELAY 14s begin
=== end scenario: s3-beyond-bound
```

### s4-fixed

```
=== scenario: s4-fixed
=== when: 2026-10-07T15:45:30Z
=== product: bin/fm-contributions.sh
=== proxy rules (CONNECT ordinal:action[:seconds]): 1:fail
=== budget: 20s

$ LAB=$LAB /tmp/fm-lab.7alkC6/fixture.sh reset
$ before: {"checked_at":"2026-01-01T00:00:00Z","error":null,"head":"e032f755e72ef9771458ae0064ef215900062c3a","state":"open","reviews":0,"events":0}
$ /tmp/fm-lab.7alkC6/proxy-run.sh 18924 1:fail
$ env -u NO_MISTAKES_GATE ... FM_HOME=$LAB HTTPS_PROXY=http://127.0.0.1:18924 FM_CONTRIBUTIONS_BUDGET=20 bin/fm-contributions.sh poll
poll rc=0 elapsed=2s
--- poll stdout/stderr (verbatim):

--- record after:
{"checked_at":"2026-10-07T15:45:31Z","error":null,"head":"e032f755e72ef9771458ae0064ef215900062c3a","state":"open","reviews":0,"events":0}
--- wake queue:
(empty)
--- forge connection log (proxy-18924.log):
11:45:30 proxy listening on 127.0.0.1:18924
11:45:31 #1 api.github.com:443 FAIL (CONNECT 502)
11:45:32 #2 api.github.com:443 TUNNEL
11:45:32 #2 api.github.com:443 CLOSE
11:45:32 #3 api.github.com:443 TUNNEL
11:45:32 #5 api.github.com:443 TUNNEL
11:45:32 #7 api.github.com:443 TUNNEL
11:45:32 #6 api.github.com:443 TUNNEL
11:45:32 #4 api.github.com:443 TUNNEL
11:45:33 #8 api.github.com:443 TUNNEL
11:45:33 #5 api.github.com:443 CLOSE
11:45:33 #6 api.github.com:443 CLOSE
11:45:33 #7 api.github.com:443 CLOSE
11:45:33 #3 api.github.com:443 CLOSE
11:45:33 #8 api.github.com:443 CLOSE
11:45:33 #4 api.github.com:443 CLOSE
11:45:33 #9 api.github.com:443 TUNNEL
11:45:33 #9 api.github.com:443 CLOSE
=== end scenario: s4-fixed
```

### s4-base

```
=== scenario: s4-base
=== when: 2026-10-07T15:45:36Z
=== product: /tmp/fm-lab.7alkC6/base/bin/fm-contributions.sh
=== proxy rules (CONNECT ordinal:action[:seconds]): 1:fail
=== budget: 20s

$ LAB=$LAB /tmp/fm-lab.7alkC6/fixture.sh reset
$ before: {"checked_at":"2026-01-01T00:00:00Z","error":null,"head":"e032f755e72ef9771458ae0064ef215900062c3a","state":"open","reviews":0,"events":0}
$ /tmp/fm-lab.7alkC6/proxy-run.sh 18925 1:fail
$ env -u NO_MISTAKES_GATE ... FM_HOME=$LAB HTTPS_PROXY=http://127.0.0.1:18925 FM_CONTRIBUTIONS_BUDGET=20 /tmp/fm-lab.7alkC6/base/bin/fm-contributions.sh poll
poll rc=0 elapsed=0s
--- poll stdout/stderr (verbatim):
contributions: observation unavailable for https://github.com/kunchenguid/firstmate/pull/6780
--- record after:
{"checked_at":"2026-10-07T15:45:37Z","error":"forge observation unavailable or changed during read","head":"e032f755e72ef9771458ae0064ef215900062c3a","state":"open","reviews":0,"events":0}
--- wake queue:
(empty)
--- forge connection log (proxy-18925.log):
11:45:36 proxy listening on 127.0.0.1:18925
11:45:37 #1 api.github.com:443 FAIL (CONNECT 502)
=== end scenario: s4-base
```

### s5-retry-cut

```
=== scenario: s5-retry-cut
=== when: 2026-10-07T15:45:45Z
=== product: bin/fm-contributions.sh
=== proxy rules (CONNECT ordinal:action[:seconds]): 1:fail 2:delay:25
=== budget: 20s, polls: 1

$ LAB=$LAB /tmp/fm-lab.7alkC6/fixture.sh reset
$ before: {"checked_at":"2026-01-01T00:00:00Z","error":null,"head":"e032f755e72ef9771458ae0064ef215900062c3a","state":"open","reviews":0,"events":0}
$ /tmp/fm-lab.7alkC6/proxy-run.sh 18926 1:fail 2:delay:25
$ env -u NO_MISTAKES_GATE ... FM_HOME=$LAB HTTPS_PROXY=http://127.0.0.1:18926 FM_CONTRIBUTIONS_BUDGET=20 bin/fm-contributions.sh poll   # poll 1/1
poll 1 rc=0 elapsed=10s
--- poll 1 stdout/stderr (verbatim):

--- record after poll 1:
{"checked_at":"2026-01-01T00:00:00Z","error":null,"head":"e032f755e72ef9771458ae0064ef215900062c3a","state":"open","reviews":0,"events":0}
--- wake queue:
(empty)
--- forge connection log (proxy-18926.log):
11:45:45 proxy listening on 127.0.0.1:18926
11:45:46 #1 api.github.com:443 FAIL (CONNECT 502)
11:45:46 #2 api.github.com:443 DELAY 25s begin
=== end scenario: s5-retry-cut
```

### s6-persistent-failure

```
=== scenario: s6-persistent-failure
=== when: 2026-10-07T15:45:59Z
=== product: bin/fm-contributions.sh
=== proxy rules (CONNECT ordinal:action[:seconds]): 1:fail 2:fail 3:fail 4:fail
=== budget: 20s, polls: 2

$ LAB=$LAB /tmp/fm-lab.7alkC6/fixture.sh reset
$ before: {"checked_at":"2026-01-01T00:00:00Z","error":null,"head":"e032f755e72ef9771458ae0064ef215900062c3a","state":"open","reviews":0,"events":0}
$ /tmp/fm-lab.7alkC6/proxy-run.sh 18927 1:fail 2:fail 3:fail 4:fail
$ env -u NO_MISTAKES_GATE ... FM_HOME=$LAB HTTPS_PROXY=http://127.0.0.1:18927 FM_CONTRIBUTIONS_BUDGET=20 bin/fm-contributions.sh poll   # poll 1/2
poll 1 rc=0 elapsed=0s
--- poll 1 stdout/stderr (verbatim):
contributions: observation unavailable for https://github.com/kunchenguid/firstmate/pull/6780
--- record after poll 1:
{"checked_at":"2026-10-07T15:46:00Z","error":"forge observation unavailable or changed during read: Get \"https://api.github.com/repos/kunchenguid/firstmate/pulls/6780\": Bad Gateway","head":"e032f755e72ef9771458ae0064ef215900062c3a","state":"open","reviews":0,"events":0}
$ env -u NO_MISTAKES_GATE ... FM_HOME=$LAB HTTPS_PROXY=http://127.0.0.1:18927 FM_CONTRIBUTIONS_BUDGET=20 bin/fm-contributions.sh poll   # poll 2/2
poll 2 rc=0 elapsed=1s
--- poll 2 stdout/stderr (verbatim):

--- record after poll 2:
{"checked_at":"2026-10-07T15:46:01Z","error":"forge observation unavailable or changed during read: Get \"https://api.github.com/repos/kunchenguid/firstmate/pulls/6780\": Bad Gateway","head":"e032f755e72ef9771458ae0064ef215900062c3a","state":"open","reviews":0,"events":0}
--- wake queue:
(empty)
--- forge connection log (proxy-18927.log):
11:45:59 proxy listening on 127.0.0.1:18927
11:46:00 #1 api.github.com:443 FAIL (CONNECT 502)
11:46:00 #2 api.github.com:443 FAIL (CONNECT 502)
11:46:01 #3 api.github.com:443 FAIL (CONNECT 502)
11:46:01 #4 api.github.com:443 FAIL (CONNECT 502)
=== end scenario: s6-persistent-failure
```

### s7-shared-retry

```
=== scenario: s7-shared-retry
=== when: 2026-10-07T15:46:11Z
=== product: bin/fm-contributions.sh
=== proxy rules (CONNECT ordinal:action[:seconds]): 1:fail
=== budget: 20s, polls: 1

$ LAB=$LAB /tmp/fm-lab.7alkC6/fixture.sh reset
$ before: {"task":"delivery","checked_at":"2026-01-01T00:00:00Z","error":null,"pending":0,"head":"e032f755e72ef9771458ae0064ef215900062c3a","state":"open"}
{"task":"duplicate","checked_at":"2026-01-01T00:00:00Z","error":null,"pending":0,"head":"e032f755e72ef9771458ae0064ef215900062c3a","state":"open"}
$ /tmp/fm-lab.7alkC6/proxy-run.sh 18928 1:fail
$ env -u NO_MISTAKES_GATE ... FM_HOME=$LAB HTTPS_PROXY=http://127.0.0.1:18928 FM_CONTRIBUTIONS_BUDGET=20 bin/fm-contributions.sh poll   # poll 1/1
poll 1 rc=0 elapsed=2s
--- poll 1 stdout/stderr (verbatim):

--- record after poll 1:
{"task":"delivery","checked_at":"2026-10-07T15:46:12Z","error":null,"pending":0,"head":"e032f755e72ef9771458ae0064ef215900062c3a","state":"open"}
{"task":"duplicate","checked_at":"2026-10-07T15:46:12Z","error":null,"pending":0,"head":"e032f755e72ef9771458ae0064ef215900062c3a","state":"open"}
--- wake queue:
(empty)
--- forge connection log (proxy-18928.log):
11:46:11 proxy listening on 127.0.0.1:18928
11:46:12 #1 api.github.com:443 FAIL (CONNECT 502)
11:46:12 #2 api.github.com:443 TUNNEL
11:46:13 #2 api.github.com:443 CLOSE
11:46:13 #3 api.github.com:443 TUNNEL
11:46:13 #8 api.github.com:443 TUNNEL
11:46:13 #6 api.github.com:443 TUNNEL
11:46:13 #5 api.github.com:443 TUNNEL
11:46:13 #7 api.github.com:443 TUNNEL
11:46:13 #4 api.github.com:443 TUNNEL
11:46:14 #8 api.github.com:443 CLOSE
11:46:14 #5 api.github.com:443 CLOSE
11:46:14 #3 api.github.com:443 CLOSE
11:46:14 #7 api.github.com:443 CLOSE
11:46:14 #6 api.github.com:443 CLOSE
11:46:14 #4 api.github.com:443 CLOSE
11:46:14 #9 api.github.com:443 TUNNEL
11:46:14 #9 api.github.com:443 CLOSE
=== end scenario: s7-shared-retry
```

### s8-cross-url-detail

```
=== scenario: s8-cross-url-detail
=== when: 2026-10-07T15:46:44Z
=== product: bin/fm-contributions.sh
=== proxy rules (CONNECT ordinal:action[:seconds]): 1:fail 2:fail
=== budget: 20s, polls: 1

$ LAB=$LAB /tmp/fm-lab.7alkC6/fixture.sh reset
$ before: {"task":"delivery","checked_at":"2026-01-01T00:00:00Z","error":null,"pending":0,"head":"e032f755e72ef9771458ae0064ef215900062c3a","state":"open"}
{"task":"gitlab","checked_at":"2026-01-01T00:00:00Z","error":null,"pending":0,"head":null,"state":null}
$ /tmp/fm-lab.7alkC6/proxy-run.sh 18929 1:fail 2:fail
$ env -u NO_MISTAKES_GATE ... FM_HOME=$LAB HTTPS_PROXY=http://127.0.0.1:18929 FM_CONTRIBUTIONS_BUDGET=20 bin/fm-contributions.sh poll   # poll 1/1
poll 1 rc=0 elapsed=0s
--- poll 1 stdout/stderr (verbatim):
contributions: observation unavailable for https://github.com/kunchenguid/firstmate/pull/6780
contributions: observation unavailable for https://gitlab.com/foo/bar/-/merge_requests/1
--- record after poll 1:
{"task":"delivery","checked_at":"2026-10-07T15:40:00Z","error":"forge observation unavailable or changed during read: Get \"https://api.github.com/repos/kunchenguid/firstmate/pulls/6780\": Bad Gateway","pending":0,"head":"e032f755e72ef9771458ae0064ef215900062c3a","state":"open"}
{"task":"gitlab","checked_at":"2026-10-07T15:40:00Z","error":"forge observation unavailable or changed during read: Get \"https://api.github.com/repos/kunchenguid/firstmate/pulls/6780\": Bad Gateway","pending":0,"head":null,"state":null}
--- wake queue:
(empty)
--- forge connection log (proxy-18929.log):
11:46:44 proxy listening on 127.0.0.1:18929
11:46:45 #1 api.github.com:443 FAIL (CONNECT 502)
11:46:45 #2 api.github.com:443 FAIL (CONNECT 502)
=== end scenario: s8-cross-url-detail
```

### s8-cross-url-detail-base

```
=== scenario: s8-cross-url-detail-base
=== when: 2026-10-07T15:46:48Z
=== product: /tmp/fm-lab.7alkC6/base/bin/fm-contributions.sh
=== proxy rules (CONNECT ordinal:action[:seconds]): 1:fail
=== budget: 20s, polls: 1

$ LAB=$LAB /tmp/fm-lab.7alkC6/fixture.sh reset
$ before: {"task":"delivery","checked_at":"2026-01-01T00:00:00Z","error":null,"pending":0,"head":"e032f755e72ef9771458ae0064ef215900062c3a","state":"open"}
{"task":"gitlab","checked_at":"2026-01-01T00:00:00Z","error":null,"pending":0,"head":null,"state":null}
$ /tmp/fm-lab.7alkC6/proxy-run.sh 18930 1:fail
$ env -u NO_MISTAKES_GATE ... FM_HOME=$LAB HTTPS_PROXY=http://127.0.0.1:18930 FM_CONTRIBUTIONS_BUDGET=20 /tmp/fm-lab.7alkC6/base/bin/fm-contributions.sh poll   # poll 1/1
poll 1 rc=0 elapsed=0s
--- poll 1 stdout/stderr (verbatim):
contributions: observation unavailable for https://github.com/kunchenguid/firstmate/pull/6780
contributions: observation unavailable for https://gitlab.com/foo/bar/-/merge_requests/1
--- record after poll 1:
{"task":"delivery","checked_at":"2026-10-07T15:40:00Z","error":"forge observation unavailable or changed during read","pending":0,"head":"e032f755e72ef9771458ae0064ef215900062c3a","state":"open"}
{"task":"gitlab","checked_at":"2026-10-07T15:40:00Z","error":"forge observation unavailable or changed during read","pending":0,"head":null,"state":null}
--- wake queue:
(empty)
--- forge connection log (proxy-18930.log):
11:46:48 proxy listening on 127.0.0.1:18930
11:46:49 #1 api.github.com:443 FAIL (CONNECT 502)
=== end scenario: s8-cross-url-detail-base
```

### s8-cross-url-detail-probe

```
=== scenario: s8-cross-url-detail-probe
=== when: 2026-10-07T15:49:51Z
=== product: /tmp/fm-lab.7alkC6/probe/bin/fm-contributions.sh
=== proxy rules (CONNECT ordinal:action[:seconds]): 1:fail 2:fail
=== budget: 20s, polls: 1

$ LAB=$LAB /tmp/fm-lab.7alkC6/fixture.sh reset
$ before: {"task":"delivery","checked_at":"2026-01-01T00:00:00Z","error":null,"pending":0,"head":"e032f755e72ef9771458ae0064ef215900062c3a","state":"open"}
{"task":"gitlab","checked_at":"2026-01-01T00:00:00Z","error":null,"pending":0,"head":null,"state":null}
$ /tmp/fm-lab.7alkC6/proxy-run.sh 18931 1:fail 2:fail
$ env -u NO_MISTAKES_GATE ... FM_HOME=$LAB HTTPS_PROXY=http://127.0.0.1:18931 FM_CONTRIBUTIONS_BUDGET=20 /tmp/fm-lab.7alkC6/probe/bin/fm-contributions.sh poll   # poll 1/1
poll 1 rc=0 elapsed=1s
--- poll 1 stdout/stderr (verbatim):
contributions: observation unavailable for https://github.com/kunchenguid/firstmate/pull/6780
contributions: observation unavailable for https://gitlab.com/foo/bar/-/merge_requests/1
--- record after poll 1:
{"task":"delivery","checked_at":"2026-10-07T15:40:00Z","error":"forge observation unavailable or changed during read: Get \"https://api.github.com/repos/kunchenguid/firstmate/pulls/6780\": Bad Gateway","pending":0,"head":"e032f755e72ef9771458ae0064ef215900062c3a","state":"open"}
{"task":"gitlab","checked_at":"2026-10-07T15:40:00Z","error":"forge observation unavailable or changed during read","pending":0,"head":null,"state":null}
--- wake queue:
(empty)
--- forge connection log (proxy-18931.log):
11:49:51 proxy listening on 127.0.0.1:18931
11:49:53 #1 api.github.com:443 FAIL (CONNECT 502)
11:49:53 #2 api.github.com:443 FAIL (CONNECT 502)
=== end scenario: s8-cross-url-detail-probe
```

## Focused regression test (stub-based supporting check, not live)

```
ok - rotation preserves timed-out records and refreshes every slow PR on successive cycles
ok - the effective budget is cut down to the watcher per-check bound with margin
ok - generated checks enforce configured and inherited budgets at runtime
ok - a genuinely unavailable forge records an error and wakes once per failure episode
ok - a late owner does not restart a shared forge failure episode
ok - retire stops the unavailable check, leaves rotation and restores complete coverage
ok - a late owner settled beside a retired final record stays unretired and known
ok - retire is idempotent and refuses non-captain, unknown, malformed and signal-bearing pairs
... 52 ok, 0 not ok total
```
