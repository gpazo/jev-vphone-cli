# Simulator action binding and speed

Evaluation dated 2026-09-27. Checked route continuation is faster than another planner call. The earlier fresh-board win remains the whole-game speed record.

## Baseline

Run `20260925-215713` took 670.410 seconds, with the first winning observation at 650.804 seconds. It used 68 planner calls and 66 native inputs. Movement accounted for 49 inputs. Decision time was 652.955 seconds, or 97.4% of controller time. Optimizing native input alone cannot remove most of this delay.

The exact debug binary and protocol-v1 helper are retained under `.codex/pstack-runs/simulator-speed/`. `tests/Donpa/compare.py` summarizes run artifacts without interpreting the board.

## Changes under evaluation

Protocol v2 binds a plan to a code-generated observation identifier and the controller's actual offered operation and target. Jev still judges each action. A disagreement causes a wait and replanning, without native input.

The contract covers app opening, text fields, picker values, ordinary controls, and native named actions. Batching is restricted to named actions on one unique owner. Each route step requires a fresh observation and a successful acknowledgment of the preceding input. Predicted values are never treated as observed facts.

The planner helper records monotonic start, end, and duration in each call's `timing.json`. Reasoning effort is configurable through `JEV_PLANNER_REASONING_EFFORT`; the default remains `high`.

## Recorded decision probes

Three frozen cases were tested twice at each reasoning setting. The cases cover a forced mine deduction, the earlier wrong-cell failure, and a completed game. These probes use recorded public observations and a curated action table. They do not measure the entire controller or establish a win rate.

| Setting | Calls | Median wall time | Forced mine deduction | Correct navigation | Correct completion |
| --- | ---: | ---: | ---: | ---: | ---: |
| High | 6 | 11.055 s | 2/2 | 2/2 | 2/2 |
| Medium | 6 | 7.726 s | 1/2 | 2/2 | 2/2 |

Medium chose a safe inspection instead of the forced flag in one probe. Its shorter calls may require more actions, so these results do not justify changing the default. All twelve replies passed protocol validation. No probe executed native input. Raw requests, responses, provider events, and timings are under `.codex/pstack-runs/simulator-speed/probes/`.

An initial launch used the unusable Homebrew Codex binary and failed before model execution. Those failures are retained separately as `probes-unusable-homebrew-cli`. Working probes used `/Applications/ChatGPT.app/Contents/Resources/codex`.

## Generic app pilot

A protocol-v2 pilot asked the controller to open Settings and navigate to General, then About. From Donpa's result panel, the planner offered `open_app` for `com.apple.Preferences`, but Jev repeatedly selected scrolling. The controller rejected all three mismatches and stopped on an unchanged screen after 28.066 seconds. No native input occurred. The in-game Settings label made the textual subgoal ambiguous. The next revision supplies the code-resolved action binding as context for Jev's independent judgment.

## Limits

A named action's `inspection` classification is a model judgment, not proof of the app's implementation. Unknown transitions end route reuse. Generic structural and owner checks cannot establish every app's business semantics. The installed Donpa app and game source are not changed by this work.

## Single-action trial

Run `20260927-132209` started fresh at 0%, opened at 83%, and won. The controller stopped after 1,058.280 seconds and 88 decisions. The first win appeared at 1,039.787 seconds, with 90 stable native samples, no audit errors, and zero subsequent native inputs. The screenshot shows 100% cleared and the Minefield cleared panel. The game clock reads 16:57. This trial was slower than the previous record.

The run executed 81 native inputs, waited six times, and made 88 planner calls. Six mismatches were rejected. The median measured provider call was 10.925 seconds. This trial includes protocol-v2 single-action binding but predates route reuse and the independent original-goal judgment. The random board differs from the earlier baseline; opening percentages alone do not establish equal difficulty. Some offline probes and builds ran concurrently, so this is an operational observation rather than an isolated latency experiment.

The evaluator initially counted one post-win wait as input. Its corrected metric excludes waits and preserves actual native inputs. The original result remains in `result-before-wait-metric-fix.json`; the revised result derives from the same retained timeline and events. The terminal screenshot was captured and visually reviewed before leaving the app.

Additional frozen Settings prompt experiments did not make Jev accept the correct app-opening proposal. Those prompt changes were not integrated. App choice from a screen containing a similarly named in-app control remains a known limitation.

## Settings validation

The completed implementation reached Settings > General > About from the Home screen in 75.602 seconds and nine decisions. It opened Settings, navigated back from the previous Accessibility page, and selected General and About. Five native inputs were acknowledged. Two changing screen structures caused the controller to discard planned taps before input. A separate native accessibility read confirmed About, General, Name, and iOS Version on the final page. No settings were changed. This starting condition avoids the known ambiguous Settings label on Donpa's result panel. Traces are in `.codex/pstack-runs/simulator-speed/settings-phase2-home/`.

## Verification

The current implementation passes 107 Swift tests and 23 Python tests. The signed release build and strict signature verification pass. Live trials use the debug Simulator build. Tests cover route acknowledgment, stale or ambiguous owners, changing structure, all-operation execution checks, original-goal terminal precedence, broken value chains, and provider protocol rejection. An independent review found no remaining confirmed route-advance or terminal regression. Comment review removed three lines of internal narration and retained the documented process-pipe constraint.

The real Jev service also passed two frozen terminal probes with a conflicting proposal to press Retry. It selected `complete` for native win evidence with probability 0.75, and `stop` for native loss evidence with probability 0.99. These probes use the production original-goal question with recorded public observations. No native input was executed. They are examples, not a reliability estimate.

Live route testing exposed transient native snapshots after input. Several snapshots omitted passive labels that appeared in the next read, forcing a planned action to be discarded after the expensive planner call. The final revision uses the existing layout-settling check after acknowledged planner-bound input. It adds no new timing constants and leaves the ordinary Jev fast path unchanged. A real-agent regression test covers both paths. The batched game trial began before this final settling revision, so its timings cannot measure that revision's effect.

## Batched game trial

Run `20260927-134306` used medium reasoning and a route limit of six. It started fresh at 0%, opened at 82%, and won in 964.101 seconds. The native result appeared at 949.045 seconds and remained stable for 75 samples. The complete audit has no errors and no native input after the result. The terminal screenshot was visually reviewed.

Five plans contained multiple steps, with lengths 2, 2, 2, 3, and 3. All seven continuations had acknowledged native input. Their decision times ranged from 174.2 to 230.6 milliseconds, with a median of 207.4 milliseconds. Each continuation retained its Jev judgment and execution-time checks. The run used 85 planner calls for 92 decisions and 83 native inputs. Seven changing structures and one changed terminal screen caused planned input to be skipped. No planner/Jev target disagreement reached execution.

| Run | Configuration | Opening | Planner calls | Decisions | Native inputs | Controller time |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `20260925-215713` | Earlier protocol, high, atomic | 82% | 68 | 68 | 66 | 670.410 s |
| `20260927-132209` | Bound protocol, high, atomic | 83% | 88 | 88 | 81 | 1058.280 s |
| `20260927-134306` | Bound protocol, medium, routes | 82% | 85 | 92 | 83 | 964.101 s |

The batched trial was 8.9% shorter than the new single-action trial. Different boards, reasoning settings, and trajectories prevent attributing that difference to batching alone. It did not beat the earlier 670.410-second controller record, whose game clock was 10:36.2. Do not report a general whole-game speedup or improved win rate from these samples.

Planner decision time still accounts for 935.033 of the batched run's 964.101 seconds. The provider's measured median call was 9.880 seconds. Medium remains opt-in. Both game trials leave the app and its source unchanged, with the same bundle hash as the earlier win. The final settling revision was applied after these game trials and has separate unit and native Settings validation.

## Final settling validation

The final binary repeated the same Settings > General > About goal from the Home screen, with Settings restored to its earlier Display & Text Size page. It used the same five native inputs and completed in 64.158 seconds over seven decisions. The earlier run took 75.602 seconds over nine decisions. The new run had zero stale-action replans, compared with two before. It deferred one completion judgment after the observation changed and then verified completion. A separate native read confirmed the About page. No settings were changed.

This is one paired workflow example. The 15.1% reduction in observed wall time includes model and runtime variation; the traces directly establish the reduction from two stale-action replans to zero. The settling change does not establish that every simulator action or every app is faster. The final debug binary and source snapshot are retained under `.codex/pstack-runs/simulator-speed/settled/`; its signed release build passes strict signature verification.

The simulator was returned to Donpa's verified win panel after the Settings checks. No further game input was issued.

## Reproduce the summaries

Run `python3 tests/Donpa/compare.py research/artifacts/jev-donpa/20260925-215713 research/artifacts/jev-donpa/20260927-132209 research/artifacts/jev-donpa/20260927-134306` for game metrics. Run `swift test --filter JevTests` and `python3 -m unittest tests/JevPlanner/test_codex_planner.py tests/Donpa/test_metrics.py tests/Donpa/test_compare.py` for focused verification.

The [batched win result](artifacts/jev-donpa/20260927-134306/result.json) and [terminal screenshot](artifacts/jev-donpa/20260927-134306/terminal.png) retain the game evidence. The [single-action result](artifacts/jev-donpa/20260927-132209/result.json) includes the wait-metric reanalysis note. Failed probes and both Settings starting conditions remain in the pstack trace directory.
