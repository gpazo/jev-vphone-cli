# Donpa / Jev audit — 2026-09-25

The current implementation can operate Donpa's native named actions. A verified
win is not established. This audit changes neither the game nor the controller.

## Findings

1. **Task strategy remains unproven.** Donpa exposes one selected cell through
   `Board`, with movement, dig/chord and flag actions. `JevProgress.executed`
   retains only 20 action outcomes; there is no persistent cell map or explicit
   constraint reasoning. This is an architectural limitation for this task,
   not proof that a win is impossible. The earlier state-memory experiment
   failed to establish an improvement and was removed.
2. **Timers defeat exact-screen repetition checks.**
   `JevObservation.signature` includes all exposed values and nearby context.
   Both unchanged-screen detection and `JevProgress.repeatedCycleLength` depend
   on those signatures. Donpa's `Time, seconds` changes even when the selected
   cell and board do not. The existing cycle tests use static screens and do
   not cover this case. Acknowledged Dig on an open cell need not change play.
3. **Fresh-game navigation currently fails.** In two audited trials Jev
   repeatedly selected `New game` while its sheet was open, then stopped for
   unchanged state. A separate screenshot showed the sheet and its Continue
   control. End-to-end startup must be evaluated separately from prepared-board
   gameplay.
4. **The evaluator needs stronger outcome guarantees before claiming wins.**
   `summarize` traverses every native node without visibility filtering, and
   `terminal_outcome` accepts label prefixes without checking the result panel's
   identity. The live tree includes underlying screens. Polling can also miss a
   transient result/reset, and clearance-drop segmentation can miss a restart
   whose opening percentage is higher than the previous board. These are
   validation gaps, not evidence that an existing recorded win was false.
   The separate audit and retained first terminal observation are useful;
   a controller success claim alone is correctly insufficient.
5. **Provenance is partial.** The recorder hashes controller/helper binaries
   and records a source checkout SHA, but does not establish that the installed
   game binary was built from that checkout. This audit restored the documented
   game source revision in `/tmp/jev-donpa` for inspection; it did not reinstall
   the game or verify its build identity.

## Verification

- `swift test --filter JevTests`: all 64 tests passed across eight suites.
- `python3 -m unittest discover -s tests/Donpa -p 'test_*.py' -v`:
  all four evaluator tests passed. They cover progress accounting, absent
  audits and loss retention; they do not demonstrate playing to a win.
- `make patcher_build`: debug Jev client rebuilt successfully using the
  repository's simulator-client target.
- Named actions re-resolve native identifiers and check owner label/value
  before execution. Duplicate names are rejected. Existing tests establish
  binding/freshness mechanics, not Minesweeper strategy.

## Live trials

All artifacts are under `research/artifacts/jev-donpa/`; local timestamps below
follow the recorder's host clock. All trials used a 100-step maximum.

| Directory | Result |
| --- | --- |
| `20260925-201518` | Default goal stopped at device-migration prompt after one judgment, 0.428 s, no input. |
| `20260925-201539` | Goal explicitly allowing Start fresh also stopped at that prompt, 0.353 s, no input. Source inspection subsequently clarified that this was a device-identity choice, not a board reset. |
| `20260925-201611` | After an operator Cancel tap, three New game inputs; stopped unchanged after four judgments, 9.045 s. |
| `20260925-201636` | After an operator New game tap, again three New game inputs; stopped unchanged after four judgments, 8.906 s. |

The operator then tapped Continue on the visible XS Drills sheet. This resumed
an existing 66%-cleared board. The subsequent `20260925-201703` trial uses a
play-current-board goal and must not be described as a fresh-board or unassisted
end-to-end run. No board storage, hidden mines, solver output, or move sequence
was supplied to Jev. Screenshots were only used for operator setup/review.

Result: **100 acknowledged actions in 58.626 seconds, 11 distinct observed
cells, 66% initial and maximum clearance, zero additional clearing**. The step
budget was exhausted. No win/loss panel was observed, no success was claimed,
and the independent audit reported no errors. The controller repeatedly dug
open cells. See the trial's `result.json`, `agent.log`, raw audits, decisions,
and `raw.mov`. This confirms working input on this installed game, not useful
Minesweeper strategy or a win.

## Next evidence needed

First reproduce and fix modal target selection and irrelevant-clock repetition
handling with focused regressions. Then evaluate generic observed-state
retention and decision quality on fixed, reproducible visible-board scenarios,
keeping game-specific outcome checks outside the controller. Require an
independently visible win and correct stopping across multiple trials before
calling Minesweeper completion reliable. More step budget alone is not evidence
of better play.
