# Existing game evaluation: Donpa Squad

The evaluation uses the unchanged MIT-licensed [Donpa Squad](https://github.com/vlumi/donpa)
at `162955f33769e30d3a2d19cece13e2abac001519`. This is an existing Minesweeper
app, built from its original XcodeGen project. No solver, hidden mine positions,
saved board, or game-specific action sequence is passed to Jev.

## General capability added

`--custom-actions` discovers a native control's named accessibility actions.
They become bound choices in the existing tap selection head, explicitly
described as named actions. Code checks the owning control's current label and
value, resolves the action name to its current opaque native identifier, and
performs it. Missing, duplicate, and stale choices fail before input. An
uncertain input result is not automatically replayed.

This is opt-in. Custom-action discovery adds native reads and has not been
evaluated across arbitrary apps. The controller contains no Donpa action names.
Its existing outcome journal now retains the owner state when a named action
is used, so the next decision can compare observed states.

Donpa exposes one focused board cell through VoiceOver, with directional,
dig/chord, and flag actions. It does not expose all tiles as separate controls.
This makes the evaluation a test of sequential observation and memory, as well
as input. A small board is not necessarily a short control task.

## Mechanic verification

A separate disposable counter fixture verified discovery and execution on iOS
18.5. An Increase action changed 0 to 1; a stale expected value and a missing
action were both rejected. Jev then selected Increase twice to reach 3 in
3.419 s, independently confirmed by a separate native accessibility read.
This fixture is a mechanism test, not the game demo. Evidence lives in
`research/artifacts/jev-donpa/custom-action-probe/`.

Focused validation: 33 Swift tests, eight Python command tests, rebuilt guest
helper, and signed release build passed. The tests include duplicate-name
rejection and invalidating a choice when its owner value changes.

## Runtime setup

iOS 26.5 (23F73), arm64, was installed using Xcode's runtime downloader. The new
simulator is `108417FD-4FA3-4315-9587-0F4A0469E561` (`jev-game-ios26`, iPhone 16 Pro).
The existing iOS 18.5 simulator was shut down and preserved.
Its regenerable dyld cache was removed with the supported `simctl runtime
dyld_shared_cache remove` command to make room for the new runtime's first-boot
cache. The old runtime and device data remain; its next boot may rebuild caches.

Installed Xcode 26.6 (17F113) has an iOS SDK build 23F81a. Its default runtime
mapping requested that build even after runtime 23F73 was installed, producing
the misleading “iOS 26.5 is not installed” destination error. Selecting the
installed build with the supported simulator mapping command allowed normal
Xcode builds to proceed:

```sh
xcrun simctl runtime match set iphoneos26.5 23F73 --sdkBuild 23F81a
```

This is a host SDK/runtime preference, not an app or binary patch. Restore the
default later with `xcrun simctl runtime match set iphoneos26.5 --default` if a
matching newer runtime is installed. The abandoned manual compile workaround
is not used.

The normal Xcode build succeeded. First boot was extremely slow on this 8 GB
Mac while the runtime cache builder and simulator ran together (host swap use
reached 12.7 GB). The phone was shut down to let cache generation finish before
retrying boot. This setup delay is not a Jev latency measurement.

## Recording and outcome

`tests/Donpa/record.py` records a bounded attempt with a separate read-only
native accessibility audit. The controller receives only its goal and its own
normal observations. The evaluator looks for the game's visible win/loss
panel; a Jev success claim alone does not establish either result. Exhausting
the step budget is incomplete. Build/download/startup time is separate from
the ready-session gameplay timer.

Three attempts are retained, without discarding the failures:

| Artifact directory | Result |
|---|---|
| `20260920-200945` | 10.733 s; New game physically opened, but input acknowledgement timed out. The controller stopped. The independent audit also failed during the cold transition, so its result is unknown. A subsequent screenshot confirmed the menu. |
| `20260920-201103` | 20.783 s; selected XS (8×8), then repeatedly invoked Dig without a selected cell. Stopped for unchanged state; independent result incomplete. |
| `20260920-201230` | 22.992 s; 45 decisions, 44 acknowledged native actions, one decision without input. Independent result incomplete, with no audit errors. |

Directories are under `research/artifacts/jev-donpa/`. The last directory holds
`jev-donpa-timed.mp4`, the original recording, decisions, observed UI timeline,
and `verification.json`. The video plays at original speed and holds its final
frame for two seconds. Its timer excludes the 2.292 s session startup and all
installation/build work.

The gameplay attempt used a short control instruction: movement selects a
cell; Dig/chord and Flag act on that selection. This came from Donpa's original
cursor implementation, not hidden board data. The default recorder prompt now
includes the same instruction. It did not contain a move sequence or solution.

The first dig produced a **69% opening cascade**, observed at 1.569 s. Jev made
no further clearing progress. Its cursor repeatedly visited four cells
((5,3), (5,4), (6,3), (6,4)) and tried actions on already open cells. The game
was neither won nor lost, and Jev did not claim completion.

For the last run, median end-to-end Jev decision time was **218.3 ms** (10.498 s
total). Observation/settling totalled 7.017 s, and input/freshness verification
5.266 s. The run averaged 0.523 s per acknowledged input, including the decision without input and all observation work. These are warm-run measurements on this Mac;
the cold attempt's first Jev call took 5.36 s under host memory pressure.

## What this establishes, and what should improve

The general named-action mechanism works against an unchanged third-party game
on iOS 26.5. Jev chooses the action names from native text; code resolves and
executes them. OCR, screenshots, board storage, and solver output do not reach
the controller. Screenshots/video are used only for independent review.

Successful game strategy is not established. The current recent-outcome journal
preserves selected-cell values but does not make Jev build a useful persistent
map. Next work should measure generic state memory and repeated-state detection
across this game and the browser workflow. A direction change currently counts
as a changed screen even when the agent is cycling among the same few states.
Do not solve that by hardcoding a Minesweeper strategy into the controller.

The discovery path remains opt-in. It queries named actions on each reachable
element; a future batched native observation should be measured against this
baseline. The profiler's tree/hit-test submetrics do not separately account for
custom-action discovery, although the complete observation stage includes it.
