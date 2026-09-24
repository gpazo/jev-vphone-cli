# Observed progress and navigation readiness — 2026-09-20

## Scope

Follow-up to [the Safari evaluation](jev_safari_evaluation.md). The goal remains
general phone control through native accessibility, with Jev choosing from
available actions. No OCR, app-specific navigation script, goal decomposition
heuristic, or privileged saved-state facts were added to the controller.

## Concrete fixes

`JevProgress` records acknowledged execution and subsequent UI observations.
Passive waits and rejected inputs do not replace the action whose outcome is
being observed. It retains document visits in order, edited control values
before forms disappear, and bounded before/after control summaries. These are
observations, not declarations that a task or a subgoal is complete.

Prior executions and observed destination titles are included in matching link
candidates, scoped by source app/document and semantic target context. This is
not persistent native identity: same-title pages and duplicate semantic links
remain limitations. Later actions freeze earlier outcomes. Both the short
history and the richer state now derive from this one journal; the previous
history sometimes attributed late navigation to a wait or left a Back action
pointing to its old document, contradicting the richer evidence.

The operation question now includes its actual available target descriptions.
Jev can judge whether a useful target exists before choosing an abstract `tap`.
Nearby off-screen native controls are exposed as bounded, read-only context,
with explicit above/below labels. They are never added to executable choices.

Link taps wait for document change within the existing settle budget. Scrolls
and drags require two matching layout/semantic readings within that budget.
The layout fingerprint includes native positions **before** hit filtering;
otherwise a moving page could appear stable after every link was filtered out,
leaving only browser chrome. Coordinates remain private to code. Completion
also re-reads the current UI and rejudges if the decision became stale.

## What the device showed

All IDs below are under `research/artifacts/jev-safari/`. Startup is separate.
The first four runs used evolving implementations; they are not an ablation.

| Artifact | Query | Agent time | Independently observed result |
|---|---|---:|---|
| 20260920-171913 | swift programming language | 36.821 s | Wrong second destination; false success claim |
| 20260920-172414 | swift programming language | 23.999 s | Correctly chose scrolling after Back, then scrolled past the target while observations were moving; stopped |
| 20260920-172759 | swift programming language | 24.149 s | Entire sequence verified at 21.801 s; correct completion claim |
| 20260920-172902 | swift programming language | 24.614 s | Entire sequence verified at 22.919 s; correct completion claim |
| 20260920-173037 | python programming language | 40.314 s | Visited correct first and second organic results, then left the second page; false success claim |
| 20260920-173829 | python programming language | 24.919 s | Unified history: full sequence and correct endpoint verified at 23.106 s; Finish selected, independent done estimate caused false failure |
| 20260920-174354 | python programming language | 29.367 s | Google order changed; selected Wikipedia then W3Schools instead of Python.org second. Both terminal judgments falsely reported completion. |
| 20260920-174649 | swift programming language | 22.505 s | Terminal-choice experiment with explicit stop_unable: sequence and endpoint verified at 18.369 s; majority threshold rejected Finish |

The two Swift passes used the identical debug binary, SHA-256
`f5002daf03879cd1767fe97c5d42d22b5bbfe3d056d957dd42f0de339c2c5a30`.
Neither run overlapped a build or another benchmark. Both remain passes under
the corrected, stricter oracle described below. Their exact requests/responses
are in `decisions/`. This is a small positive sample, not general reliability.

In the first pass, the measured categories were 1.925 s for ten Jev requests
(about 192 ms each), 4.645 s for input/verification, and 17.094 s for observation
and settling. These are wall-clock categories, not pure CPU/network times.
The audit's concurrent AX reader can add device load. The data do not support a
1–2 second promise for the whole live web task.

The same implementation also passed all three alarm regressions without
feeding preferences to Jev. New records were independently audited and every
existing record was preserved:

| Artifact under jev-alarm | Time requested | Agent time | Result |
|---|---|---:|---|
| 20260920-172959 | 6 AM | 3.842 s | New 06:00, correct completion claim |
| 20260920-173007 | 12 PM | 3.140 s | New 12:00, correct completion claim |
| 20260920-173014 | 6 PM | 3.705 s | New 18:00, correct completion claim |

The 6 AM run used three bounded native adjustments rather than direct selection;
it was correct but did not take the shortest offered path. These are saved demo
records, not Apple Clock notifications.

## Measured judgment experiments

Exact replay tooling is `tests/jev_replay.py`. It sends recorded request payloads
to Jev without touching the phone. Results are under `artifacts/jev-progress/`.

A preliminary four-choice diagnostic on a recorded post-Back state chose
scroll in 3/3 replays with progress and reopened the first result in 3/3 without
history. That experiment used a reduced choice set, not the production batch.

The Python terminal state was then replayed with the full production batch:

- Original conflicting history: Finish 1/3, Tap 2/3; `done` 0.21–0.22.
- Remove legacy history, preserve journal: Finish 3/3; `done` 0.42–0.49.
- Derive history from journal: Finish 3/3; `done` 0.40–0.45.
- Additionally retain the earlier source link choices: Finish 3/3, but `done`
  fell to 0.29–0.36. This extra payload was **not implemented**.

The unified history fixes a real evidence contradiction and improves the
selected action in this frozen case. It does not establish calibrated completion:
the independent `done` judgment still disagrees with the Finish choice. Existing
completion thresholds were left unchanged during those trials. Do not relabel
these replays as live passes.

## Completion rule comparison

The next live Python trial with unified history completed the task and remained
on Wikipedia, but the action head selected Finish with probability 0.58 while
the independent `done` head answered 0.19. The latter is another model judgment,
not ground truth. The device oracle verified the complete sequence and endpoint.

`completion-rule-comparison.json` compares final decisions from five recorded
runs with exact API responses and independently checked outcomes (three complete,
two incomplete). The previous rule accepted 2/3 complete and 1/2 incomplete
cases. Requiring a Finish choice with majority probability accepted 3/3 complete
and the same 1/2 incomplete cases. The additional done gate introduced one false
failure and caught no extra false success in this small retrospective sample.

A terminal-choice alternative was tested: require a Finish choice with probability
**greater than 0.5** and a fresh observation, treating the separate done estimate
as diagnostic. A separate `stop_unable` choice represents failure to progress.
The existing risk/human-decision gates and action validation remain in force.

The live results did **not** justify promoting it to default. It still accepted
a wrong-ranked result (Finish probability 0.97, done 0.89, so both rules failed),
and its majority threshold rejected another correctly completed Swift sequence.
It remains opt-in via `--terminal-choice-completion`, including in the Safari
harness. The corroborated completion rule remains the default. The browser
reference accepts a validated DONE choice; the experimental majority condition
is an additional code gate here, not a claim about that reference's policy.

These findings argue for a larger balanced completion evaluation, not tuning
one threshold until one query passes. The useful production changes in this
iteration are the coherent progress journal, richer available-choice context,
scroll readiness, completion freshness, and stricter independent evaluation.

## Evaluator corrections

The held-out Python query exposed two harness weaknesses. The parser excluded
“sponsored” text but not the native `Ads, region` label. It also accepted having
visited the second destination even if the controller later left it. Both are
fixed, with regression tests. Final state must remain the second destination.

Original result files remain untouched. `recheck.json` beside relevant runs
records the updated verifier hash and verdict. The two Swift passes remain
passes; the Python case remains a failure. Its corrected organic order is
python.org then en.wikipedia.org; all four navigation milestones occurred,
but its final observation was Google results again.

## Final default-build checks

After the history unification and keeping the alternative completion policy
opt-in, the final default build passed all four requested regressions:

| Artifact | Task | Agent time | Independent verdict |
|---|---|---:|---|
| jev-alarm/20260920-175202 | 6 AM | 3.311 s | New 06:00, existing records preserved |
| jev-alarm/20260920-175209 | 12 PM | 5.038 s | New 12:00, existing records preserved |
| jev-alarm/20260920-175218 | 6 PM | 4.035 s | New 18:00, existing records preserved |
| jev-safari/20260920-175322 | Swift search → first → Back → second | 26.179 s | Sequence and final Wikipedia page verified |

All four also received a correct controller success claim. Alarm session setup
was 2.403 s; Safari setup was 2.531 s, excluded from the times above. The Safari
audit returned its final confirming tree at 26.698 s, after the controller's
26.179 s success report. Audit timestamps are read-completion times, not exact
paint times. The timed video shows the agent and audit times separately.

The final pass video is
`artifacts/jev-safari/20260920-175322/jev-safari-timed.mp4`. It preserves playback
speed and extends only the final still frame. These passes do not erase the
held-out Python ranking and completion failures recorded above.

Validation: 31 focused Swift tests across four Jev suites and 14 Python tests
(six Safari oracle, eight command/reporting) passed. `make build` completed,
the release binary passed strict signature verification, and `git diff --check`
passed. Live measurements above used the final simulator debug build; the
signed release build was verified separately.

## Remaining work

Completion on unfamiliar tasks remains uncertain. Expand the completion-policy
comparison with genuinely complete and incomplete held-out states. Keep endpoint state distinct from historical
visits. Reduce observation/settling cost only while preserving coherent target
and layout checks; Jev request time is a small part of the measured web run.
