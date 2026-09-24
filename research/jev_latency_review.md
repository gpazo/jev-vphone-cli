# Jev control-loop latency review — 2026-09-20

## Broader alarm tests: 6 AM, noon, 6 PM

Later requested tests used the same controller, with new UUID checks and
existing-record preservation. Results (ready session, setup excluded):

| Goal | Outcome | Goal time | Artifact |
|---|---|---:|---|
| 6 AM | Saved 06:00, new UUID | 2.970 s | `20260920-155032` |
| 12 PM | Failed before Save: incompatible picker value format | not captured | `20260920-155039` |
| 6 PM | Saved 18:00, new UUID | 2.390 s | `20260920-155107` |
| 12 PM retry | Failed before Save: native AX write rejected (-25200) | not captured | `20260920-155132` |

Both noon failures left the existing saved records unchanged. The first
reached a visible 12/00/PM wheel state before the next choice failed. The
second used three individual increments and then received a native input
rejection. These are different errors; neither saved an alarm. Unsaved editors
were dismissed between tests. No controller changes were made during this set.
The result is two successful goals out of three, with noon failing twice;
these measurements do not support a reliable 1–2 second completion claim.

The recorder now accepts `--times 6AM 12PM 6PM`, checks exact 24-hour stored
values and preservation of prior records, and saves an audit even if the
agent process exits early. The first two fatal traces predate that recording
fix; their saved-state audits were added from independent subsequent reads,
and their exact termination times are deliberately left unknown.

## Final validation

After the bounded button retry and numeric frame fix, a clean repeat (no
concurrent build) succeeded twice: **1.799 s and 1.696 s**, with 1.746 s of
one-time session initialization. Both created new 06:00 UUIDs, independently
confirmed in 0.414 s and 0.341 s respectively. Artifacts:
`artifacts/jev-alarm/20260920-151251/` and `20260920-151255/`.
The first contains `jev-6am-timed.mp4`, original speed with timing annotations
and a two-second static end card. Eleven Swift accessibility/facts tests,
eight command tests, and signed `make build` passed.

## Native input and ready sessions (latest)

The earlier profile below identified mechanics as the bottleneck. Replacing
per-action processes and timed wheel drags produced independently verified
ready-session runs of **1.664, 1.730, 1.890, 1.894, and 1.951 seconds**. Each
used five live model decisions: open Alarms, add, choose hour 6, save, finish.
Startup is reported separately (about 2 seconds); this is not a cold CLI claim.

Representative artifact: `artifacts/jev-alarm/20260920-150548/`:

| Stage | Seconds |
|---|---:|
| Five Jev requests, including HTTP and validation | 0.794 |
| Input and verification | 0.461 |
| Observe and settle | 0.671 |
| Facts and other loop work | 0.026 |
| Ready goal to verified completion | **1.951** |
| One-time session startup (excluded above) | 2.144 |
| Additional independent saved-record audit (excluded above) | 0.526 |

Buttons use the existing idb bridge's native press operation with an asserted
label. Native picker increments/decrements run in a persistent guest helper;
code checks every resulting value, with a 64-adjustment bound. The model
chooses a literal target from the goal, which collapses three row-level model
decisions into one bounded operation. `setvalue` was tested and ignored by the
stock wheel, so it is not used. Guest app launch also avoids another process.

Observation returns on semantic change; the guest asserts the target at action
time. Three bounded retries are allowed only after confirmed no-action results,
with another target check. No ambiguous action is automatically repeated.

Fast Save exposed another false-negative: host preference files may lag seconds
behind cfprefsd. Agent facts now read live container-scoped defaults; a separate
guest process independently checks that a new UUID has hour 6 and minute 0.
The app, its stock picker and its storage code are unchanged.

**Variability remains.** Further runs measured 2.190 and 2.622 seconds; the
latter used three incremental model choices instead of one target selection.
A third run safely stopped on an inconsistent action probability answer and
saved nothing. An earlier stale button target exposed an animation race and
motivated the bounded retry. Keep failures alongside successes; this is not a
1–2 second SLA. Benchmark without concurrent builds for less host contention.

Repeat with `make setup_jev`, `make jev_session SIM=booted`, or
`python3 tests/AlarmDemoApp/record.py --simulator booted --runs 3` after building.
The recorder reports initialization, goal timing and independent audit separately.

## Earlier measurement

Use `vphone-cli jev "<goal>" --simulator booted --profile` to print monotonic,
non-overlapping stage timings. `Jev decision` includes question construction,
encoding, the entire HTTP round trip, decoding, and validation; it is not an
inference-only server metric. External elapsed time also includes process
startup and teardown. No API key, request headers, or response bodies are
logged by profiling.

Two home-screen runs of “Add a new alarm for 6:00 AM in the Alarms app and save
it” each took seven decisions, used semantic accessibility throughout, and
were independently checked for a **new UUID with hour 6, minute 0** in the
unchanged demo app's preferences. Existing records were preserved.

| Stage | Before | After |
|---|---:|---:|
| Jev decisions | 1.632 s | 1.252 s |
| Preference facts, including baseline | 9.481 s | 0.019 s |
| Input and tap verification | 8.934 s | 8.778 s |
| Observation and settling | 1.514 s | 2.333 s |
| Additional post-action pauses | 2.526 s | 0.004 s |
| Setup and initial probe | 2.243 s | 2.849 s |
| External total | **26.631 s** | **15.407 s** |

These are individual runs, not statistical latency guarantees. The before
run's seven Jev decisions were 152–362 ms, median 209 ms. The earlier 33.432 s
video used eight decisions and had no component timings, so it is not the
controlled comparison. Artifacts: `research/artifacts/jev-alarm/20260920-134727/`
and `20260920-135325/`, including logs, before/after records, raw video and
results. The latter also has `jev-6am-timed.mp4` with an original-speed clock.

## Decisions revised

1. **Launching three preference readers per decision.** Keep one read-only
   process in the simulator and fetch all three domains together. It calls
   `CFPreferencesSynchronize` before reading, so it reads cfprefsd rather than
   hoping host plist files have flushed. Cold startup happens once, alongside
   other setup. Warm helper-only reads measured 0.05–0.15 ms; whole-run facts
   cost 19 ms. Preserve broad settings coverage rather than special-casing an
   alarm goal to suppress verification.
2. **Sleeping after a check already waited.** Semantic taps already pause and
   re-observe; other semantic actions are followed by `observeSettled` in the
   next iteration. Remove the additional fixed 400 ms pause. An explicit
   `wait` still waits but no longer demands a subsequent screen change, which
   previously imposed another 2.5 s timeout on a successfully saved alarm.
3. **Treating a failed preference read as an empty domain.** Keep read-success
   markers out of model-visible facts. Only report a removed key when its
   domain was successfully read. Stop a timed-out helper before falling back,
   so a late response cannot be reused for a later request.
4. **Parsing preference lines by `=`.** Parse the actual plist in the fallback.
   This excludes nested keys and normalizes strings consistently with the warm
   reader, preventing invented changes when switching readers.

## Decisions preserved

- Jev receives current text and selects typed actions/element IDs; code owns
  coordinates, timing, validation and execution policy.
- One batched Jev request per step. It was about 6% of baseline elapsed time;
  removing its judgment would target the wrong bottleneck.
- Fresh target checks, bounded settling, risk gates and independent saved-state
  verification. The wheel's visible value alone is not proof of a saved alarm.
- The measured 600 ms wheel gesture. Shrinking it without observing successful
  row movement would repeat the earlier “fast gesture did nothing” failure.

## Earlier remaining input cost (resolved by native path above)

AXe still starts a fresh process/HID connection for each action. The 8.778 s
input category includes process startup, physical gestures, tap freshness
reads, and tap verification pauses; the profiler does not yet split them.
Do not attribute the entire category to process startup.

AXe 1.8.0's `batch --stdin` reads all lines to EOF before executing; it cannot
serve a live observe/decide/act session, and its supported batch vocabulary
does not include the low-level drag used here. Precomputing the alarm taps
would bypass the behavior the demo is meant to prove.

A probe importing AXe's FBSimulatorControl framework into a persistent Swift
helper failed to compile its supplied Swift interface with this Xcode
toolchain (module/class name qualification errors). That experiment made no
production input changes. A supported persistent HID channel remains the next
candidate; it needs its own device verification and disconnect handling.

## Validation

- Warm reader matched independent `defaults export` for all three domains.
- A temporary test domain confirmed external writes, changes and deletion are
  visible to the same long-lived reader; the domain was removed afterward.
- Alarm run independently verified the new 06:00 record.
- A separate settings run turned Bold Text from 0 to 1, independently checked
  through `defaults read`; four decisions, 14.239 s internally measured.
- Eight Swift accessibility/facts tests, including failed-read and nested-plist
  regressions, and eight command tests passed. Signed `make build` passed.

Repeat `make setup_jev` after updating to build the guest preference helper.
