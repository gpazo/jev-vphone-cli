# General state memory experiment — 2026-09-21

**Retired on 2026-09-21 under the user's KISS direction.** The implementation,
CLI/recorder flags, additional prompt rules, and experiment-only Swift tests
were removed. The existing bounded action journal and default controller
behavior remain. Neither reference project uses this transition-memory design.
The historical traces, frozen replay ablation, and independent evaluator metrics
remain so the negative result is inspectable. The descriptions below document
the removed experiment, not a currently available controller mode.

## Mechanism

The journal retains at most 96 aggregated transitions between observed control
values. Named actions share their owning control, so an unrelated changing
timer does not make the same owner/action/value appear untried. Ordinary inputs
also require the same observed screen when describing prior attempts inline.
Memory is scoped by app, document, role/label and context. Ambiguous owners or
missing post-action owners do not establish an outcome. These are semantic
matches, not claims of persistent native identity across all possible UIs.

Each target choice gets evidence of what that action previously did from the
current state. Untried choices are explicitly unknown, not recommendations or
proof of safety. No actions are removed or automatically chosen by this memory.
Returning to prior states remains possible, including browser Back.

Repeated settling reads replace the pending observation rather than counting
as repeated executions. Delayed results can replace an apparent no-op before
the next acknowledged input. The model receives six detailed recent outcomes,
up to 20 compact action-history entries, document visits, and the relevant
transition table. Earlier navigation evidence remains available in candidate
descriptions. Unchanged control values are not declared proof of no effect;
effects elsewhere may be unobserved. Memory remains untrusted UI text.

## Live results

The game test resumed the unchanged 69%-cleared board from the previous demo.
It was not a matched fresh-board trial and must not be presented as an A/B win.
Artifact: `research/artifacts/jev-donpa/20260921-065230/`.

- Jev moved beyond the earlier four-cell loop, but added **zero clearance**.
- The audit saw the loss panel at 6.393 s; Jev then pressed
  Retry instead of respecting the goal's instruction to stop after win/loss.
- The run stopped at 8.562 s after a native write rejection on an optional
  Game Center prompt. It did not claim completion.
- The final new-board screen alone reads as incomplete. The evaluator now also
  retains the first observed terminal outcome and inputs after it, so restarting
  cannot erase evidence of a loss or of failing to stop.

The evaluation also reports additional clearance **after the first nonzero
reading**. The earlier demo's automatic 69% opening therefore counts as zero
subsequent clearing progress. Those game-specific metrics live only in the
Donpa evaluator and never enter the controller. Recomputed comparisons are in
`research/artifacts/jev-state-memory/20260921/game-comparison.json`.

Safari on iOS 26.5 did not yield a completed live regression check. The initial
session failed during initialization; subsequent trials stopped on an Address
input timeout (`20260921-065507`) and a rejected Continue input during onboarding
(`20260921-065556`). Both reported failure. The second had a clean read-only
audit. Neither reached the search/result/Back sequence. A release build was
running during the last trial, so its timing is not a clean latency measurement.
These runs do not establish that memory helps or harms browser navigation.

## Frozen-decision ablation

Replay of the game decision after four actions, three trials per variant:
**all six selected the same Move down action**. Added memory/rules/candidate
evidence consumed 7,669 input tokens versus 6,825 without them on this sample.
The six-outcome compaction is held fixed by this ablation; it is not a test of
compaction against the original 20-outcome prompt. Nor is one frozen decision a
test of task completion. Artifact:
`research/artifacts/jev-state-memory/20260921/frozen-choice-ablation.json`.

Use `tests/jev_replay.py --variants original without_state_memory` to reproduce
the evidence-removal experiment. It calls Jev without operating a device.

## Validation and disposition

Focused tests cover polling versus execution counts, delayed results, clocks,
source-state specificity, app scope, ambiguous owners, bounded retention,
preserved browser order/Back choices, and valueless controls. Separate evaluator
tests distinguish an opening cascade from further clearance and retain losses
across restarts. Validation passed: 41 focused Swift tests, three game-evaluator tests, six
Safari-evaluator tests, signed release build, and signature verification. The
leaking full BundleOps suite was not run.

No better gameplay or cross-app success rate was demonstrated, so the feature
was removed instead of retaining another mode to maintain. Future changes need
matched live trials, without importing evaluator facts into the controller or
adding game-specific strategy.


## Removal validation — 2026-09-21

After removal, 33 focused Swift tests and nine independent evaluator tests
passed. Both debug and signed release builds completed; release signature
verification passed. The simulator/debug CLI and both recorders' help outputs
confirm the retired flag is absent. A release CLI help launch was killed by
macOS (SIGKILL); release launch is not validated on this host. No new live game
or Safari run was made, and no task-success or latency improvement is claimed.
