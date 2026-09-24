# Bounded repetition and measured request simplification — 2026-09-23

The strongest deterministic changes ship in the normal loop. The prompt change
remains optional because a smaller request improved one mistake and introduced
another. No planner, OCR, app-specific input sequence or second history store
was introduced. This follows the reference review's distinction between typed
judgment and bounded code-owned execution; neither reference establishes that
an explicit task-stage planner is necessary.

## Default behavior

**Repeated cycles.** `JevProgress` retains local before/after signatures alongside
the existing bounded journal. Before execution, the controller checks whether
the chosen action would start another identical short cycle. Defaults allow
two repetitions of a 2–4-action cycle; thresholds live in `Policy`. Matching
requires the same action detail, semantic target key, source/destination app and
document, and complete semantic screen states, including observed values.

This differs from merely revisiting a screen: Back followed by a different
result is allowed, as is choosing a new exit after two cycles. Different values
or other visible progress prevent a match. Passive reads, rejected input and
waits do not invent executions. Incomplete evidence cannot establish a cycle.
The guard stops with an explicit reason, never success. It detects short exact
cycles, not every kind of wasted work; intentional repetition without visible
progress can also hit this conservative bound.

`ControlLoopTests` runs the same scripted wheel reversal against the complete
agent twice, changing only `Policy.maxCycleLength` (0 versus 4):

| Regression | Executed inputs | Jev-decider calls | Outcome |
| --- | ---: | ---: | --- |
| Guard disabled | 25 | 25 | Budget exhausted |
| Default guard | 4 | 5 | Third cycle refused |

These are deterministic fake-device counts, not a measured end-to-end speedup
or improved task completion. Additional tests cover cycles of length 2, 3 and
4, transient/passive reads, different exits, monotonic changes, visible progress,
app scope, target identity and incomplete observations.

**Selected-target uncertainty.** The decoder used to discard the consumed
target's confidence after validating its answer. It now retains both confidence
and winning-option probability. The existing risk-conditioned uncertainty gates
use `min(operationConfidence, targetConfidence)`, falling back to operation
confidence for operations with no target. This minimum is not a joint probability.
Unused speculative heads remain irrelevant. Logging retains operation confidence
and adds separate target diagnostics. Tests cover low confidence in either
selected head, unchanged benign execution, and consequential confirmation.

## Paired prompt experiment

`--compact-requests` replaces only the operation/target question instructions
with shorter generic rules. It preserves the full state/history, every offered
operation and target binding, and the readiness, blocked, risk and completion
questions. It adds no request or new execution path. Default is **off**.

Ten recorded Contacts, Calendar and Safari cases were labeled in
[`cases.json`](../tests/DecisionReplay/cases.json) before replay. Labels include
valid alternative field-entry orders, the known wrong Calendar start-minute
selection, correct initial/final edits, completion, Back, and the second organic
search result. This is a small regression set, not a held-out reliability study.
The requests are frozen; current live state and native freshness checks are not
exercised by this replay.

The Swift exporter uses the production transformation. The Python runner checks
identical evidence/choices, alternates arm order within each pair, uses one
persistent HTTP connection, validates selected answer distributions, and saves
all raw answers, request hashes, timing and API-reported token usage. Three
repeats per case, 60 requests total; all returned `jev-1.13.0`, zero API errors.
Transport timing includes the HTTP round trip; it is not model compute time.

| Metric | Original instructions | Compact instructions |
| --- | ---: | ---: |
| Correct frozen decisions | 25/30 | 27/30 |
| Median HTTP request time | 346 ms | 280 ms |
| P90 request time (nearest rank) | 811 ms | 638 ms |
| Median reported input tokens | 16,654 | 14,744 |
| Median serialized request bytes | 55,867 | 45,674 |
| Wrong-start-minute repair | 0/3 | 3/3 |
| Stop after completed Calendar workflow | 1/3 | 0/3 |

Median paired time difference was −54.6 ms; the difference of overall medians
is −66.1 ms. The compact arm selected the correct `00` minute in all three
repair repeats, while the original selected `45`. However, compact selected a
tap instead of Finish on the already completed event in every repeat. The
original chose Finish three times but only one met the unchanged `done` gate.
Correct-save readiness passed 3/3 in both arms. Aggregate improvement cannot
justify promoting a prompt with this stopping regression. No live compact
workflow success or general speedup is claimed.

Artifacts: [raw paired answers](artifacts/jev-control-bounds/replay-compact.json),
[summary](artifacts/jev-control-bounds/summary.json), and exact requests in
`artifacts/jev-control-bounds/requests/`.

## Live default regression

Apple Contacts on the booted iOS 26.5 Simulator created **Avery Sloan / Jev bounded
control**, new ID **28**. An independent read-only SQLite audit observed save at
**7.640770208 s**; the controller reported completion at **10.659033375 s**, seven
judgments. All **27** previous contacts were preserved; no audit errors.
Form validation was ON, compact requests OFF, scoped validation OFF. This is
a correctness regression, not a matched speed comparison. The first Save was
deferred by freshness, then rejudged before execution.

The initial old contact detail exceeded the reader's budget. Fixture setup used
a bounded partial read solely to locate the native Back control, then a fresh
label-checked native press returned to the list before timing. Controller
completeness checks remain unchanged. App storage was never fed to Jev.

[Independent result](artifacts/jev-contacts/20260923-154046/result.json) and
[unedited video](artifacts/jev-contacts/20260923-154046/raw.mov). The media duration
is 10.465 s; the numbers above come from monotonic controller/oracle logs, not
the recording's capture timeline. Final native screen visually checked.

This live run used debug SHA-256
`04cb757695ca99b980b136182b5a1330f59ce668d67bb8711a175511a80f3cb7`.
It preceded moving unchanged cycle defaults into `Policy` for the isolated
ablation. The final configurable guard is covered by the complete offline loop
tests; no final-build end-to-end timing is asserted from that earlier recording.

## Reproduce

No API calls occur in ordinary unit tests:

```sh
swift test --filter 'ControlLoopTests|CompactRequestTests|ActionSpaceTests|ProgressTests|FormValidationTests|CompletionFreshnessTests|TargetFreshnessTests|SimulatorAccessibilityTests'
python3 -m unittest discover -s tests/DecisionReplay -p 'test_*.py'
```

Export through production Swift, then explicitly run paid API replays using the
existing `TYPESAFE_API_KEY` environment variable:

```sh
JEV_REPLAY_EXPORT_DIR=/tmp/jev-compact-replay swift test --filter CompactRequestTests
python3 tests/DecisionReplay/run.py --requests /tmp/jev-compact-replay --runs 3 --output /tmp/jev-compact-results.json
```

Simulator recorders for Contacts and Calendar accept `--compact-requests` to
make future live comparisons reproducible and record the flag in their results.
Use a fresh contact name/event title and fixture setup appropriate to the task.
The compact option currently has a known stopping regression; do not substitute
the replay accuracy total for an independent saved-state/ordered-workflow audit.

Validation: all 64 focused Swift tests passed with the optional offline export
enabled; 23 Python tests passed (Calendar 1, Contacts 3, Safari 8, command
transport 8, replay scoring 3). `make build` and strict code-signature verification
passed. Release runtime was not used for the live measurement. No firmware
patches changed; the expensive/leaky firmware test suite was not run.
