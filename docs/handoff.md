# Handoff

What this project is, what actually works, and the traps that cost real time to
find. Read this before changing the Jev agent.

## What it is

`vphone-cli` boots a virtual iPhone and can drive it — tap, swipe, type, launch
apps. This work added an agent that decides *what* to drive: you give a goal in
plain language, and **Jev** (TypeSafe's System One model) picks one bounded
action per step.

`docs/jev.md` is the design document. This file is the state of play.

## Current simulator path — 2026-09-20

### General controller direction

**Bounded cycles, target confidence and reproducible replay (2026-09-23):**
[implementation and results](../research/jev_control_bounds.md).
Default guards now reject starting a third identical 2–4-action cycle, scoped
to executed inputs and complete before/after app/document state. Different
exits and visible progress are allowed. An isolated scripted ablation reduced
25 inputs/25 judgments to 4 inputs/5 judgments; this is bounded failure, not
successful repair or a measured phone speedup. Selected-target confidence and
probability are retained; existing consequential-action uncertainty gates use
the lower operation/target confidence. Unused speculative heads do not gate.
The optional `--compact-requests` experiment remains **off by default**:
10 frozen cases × 3 paired repeats gave 346→280 ms median API latency and
25/30→27/30 correct decisions, but completed-Calendar stopping regressed
1/3→0/3. Never report the aggregate as task reliability. All 64 focused Swift
tests (including offline export) and 23 Python tests passed. Signed build
verified. Debug Simulator Contacts created ID 28 at 7.641 s, reported at
10.659 s, preserved all 27 previous contacts, no audit errors; compact OFF,
form validation ON. No app rules, OCR or task planner were added.

**Picker options and inline context (2026-09-23):** [results and video](../research/jev_picker_options.md).
The full Calendar create/save/reopen/reschedule/save workflow passed once:
same new event ID 137 at 9:30–10:15 (9.539 s) and 2:00–2:45 (32.227 s),
correct completion at 34.305 s, all previous audited events preserved.
The repeat failed before saving; this is not reliable completion or a speedup.
Native option lists now filter impossible wheel/value bindings and participate
in freshness. Wheel-centre taps are omitted. Unnamed inline editors retain
immediate preceding-row text as adjacency context, never assumed ownership.
No Calendar rules or OCR were added. Form validation remains experimental/off
by default. Contacts also created ID 27 correctly (save 7.086 s, complete
10.276 s), preserving all 26 prior records. 53 focused Swift and 20 Python tests passed; signed build verified,
but release launch exited during setup, so live results use the debug build.

**Form validation (2026-09-22):** [experiments and limitations](../research/jev_form_validation.md).
`--validate-forms` is an **off-by-default** candidate-bound readiness experiment.
It rejects wrong/unknown form judgments, gives explicit rejection feedback,
and checks the full form before a permitted save. Speculative questions cover
24 taps; a selected target beyond that incurs one extra request. A contradictory
done score cannot override a rejected tap. Contacts created new ID 26, saved at
5.966 s and reported at 9.125 s (249 ms median Jev), preserving all 25 old contacts.
Calendar's correct initial duration was saved four times (one guarded), but the
full reschedule task still fails. Replays found both false refusals and unsupported
approvals, so do not promote the gate to default. Generic selection rules now
check current-stage values and item identity; covered native text remains bounded
read-only context and participates in freshness. The journal retains field context.
No broad speedup or reliable arbitrary-form validation is established.
50 focused Swift and 20 Python tests passed; signed release build verified.

**Scoped validation experiment and Calendar (2026-09-22):** [results](../research/jev_scoped_validation.md).
An opt-in `JEV_SCOPED_VALIDATION=1` path retains observation-scoped native targets,
checks ancestry/context and foreground state, and consumes references before
input. It remains **off by default**: two paired Contacts runs reduced median
verified field entry 267→126 ms and completion 7.161→6.737 s, but Settings was
slower. Six live reference guards and Calendar modal/dismissal checks passed;
moving/recycled target equivalence remains open. Calendar now has a separate
create-and-reschedule recorder/oracle. Both old and experimental controllers
saved the wrong initial duration and failed to reschedule; no success claimed.
44 Swift and 20 Python checks passed; signed build verified.

**Observation follow-up (2026-09-22):** [results and videos](../research/jev_observation_followup.md).
The loop now hands a fresh changed-completion observation directly to its next
decision instead of fetching it again. Completion still requires a new read;
visible unresolved native remote subtrees now block a success claim. Settings
enabled two independently verified switches in 1.866 s from the ready pane;
restoring both took 2.543 s with an extra toggle. Final Contacts saved a new ID
at 4.518 s and reported at 6.812 s, preserving all prior records. Safari still
failed; the new guard stopped its false completion. Parallel hit-test and native
visibility experiments were measured and removed. No general speedup is claimed.
43 Swift and 19 Python focused checks passed; builds and signing verified.

**Verified input follow-up (2026-09-22):** [measurements and both videos](../research/jev_input_followup.md).
Text replacement now writes and verifies the same native element after fresh
target checks; matched Contacts trials halved median verified fill time
(482 → 240 ms), with completion median 7.281 → 6.593 s from the list. Native
Back meaning is preserved, unnecessary focus taps are discouraged, and large
documents use the existing 20,000-node budget immediately instead of fetching
twice. A native/web traversal heuristic was measured and removed. Final-build
Contacts created a new record from an existing detail page (save 6.027 s,
report 7.636 s); Safari's Google → first → Back → second sequence and stop both
passed (second page observed 11.702 s, report 23.222 s). Existing records were
preserved. Native Safari Unicode/guard checks passed; HTML inputs reported as
generic elements remain unsupported. The 1–2 s whole-task target is unmet.

**Native controls and Contacts (2026-09-22):** [measurements, failures and video](../research/jev_native_controls.md).
Native accessibility page scrolling measured 0.181 s versus 4.303 s to a changed,
stable native layout in a controlled comparison. Selected-target validation now
checks only matching candidates, while model observations still hit-test all
offered controls. Native placeholders make previously omitted blank form fields
usable; character keys are omitted when complete literal entry is available.
Contacts is now a real-app test: from an existing detail page, Jev created a new
three-field contact, saved at 7.181 s and correctly reported completion at 9.374 s.
The independent SQLite audit checked a new ID and preserved existing records.
A failed repeat edited the prior demo record; the recorder now rejects that
case, and a measured generic create-versus-edit instruction corrected two live
repeats. Browser reliability and the 1–2 s whole-task target remain unresolved.
39 focused Swift and 15 evaluator tests passed; debug/signed builds verified.

**Document readiness (2026-09-21):** [evaluation and videos](../research/jev_document_readiness.md).
A small generic settling fix waits through a temporarily missing document after
native navigation, while allowing editable UI and other apps to proceed. Swift
search → first result → Back → second result passed both navigation and stopping
at 30.400 s. Python passed navigation at 38.087 s but made one extra scroll before
stopping; the evaluator now rejects that late stop. Both had clean read audits.
Prompt simplification/choice experiments did not improve the frozen bad decision
and were not adopted. This is not a demonstrated latency or broad reliability gain.

**Simpler input follow-up (2026-09-21):** [evaluation and timed video](../research/jev_simple_input.md).
Ordinary and named presses now share the existing guest translator; the older
reader write path rejected a visible native dialog. Native keyboard/row context
is preserved without app-specific instructions. Two Settings switches passed
on/off checks against both AX and preferences: ready-pane repeats 2.816 / 2.714 s.
Cold navigation still timed out once; the game still looped and Safari selected
the wrong second result. No broad success or latency improvement is established.

**KISS cleanup (2026-09-21):** removed the unproven state-memory experiment,
its CLI flag, second transition store, and extra prompt rules. The controller
keeps one bounded observed-action journal, current accessibility state, one
batched Jev choice per step, and code-owned execution/freshness checks. Native
named actions and independent demo outcome checks remain. This restores the
previous default behavior; it does not establish better gameplay or latency.
[The retired experiment](../research/jev_state_memory.md) records the negative
results. Neither sibling project uses that transition-memory design.

**Existing-game work:** [Donpa evaluation](../research/jev_game_evaluation.md).
The opt-in `--custom-actions` path exposes native named accessibility actions
through the existing bound-choice controller. A counter fixture independently
verified Jev moving 1 to 3 and stale-action rejection. Donpa itself is unchanged.
The iOS 26.5 recording contains 45 decisions / 44 native actions in 22.992 s,
with a 218 ms median Jev call. Its first dig opened 69% of the board; subsequent
play revisited four nearby cells without further clearing and exhausted the
budget. This proves control mechanics, not successful Minesweeper strategy.
The prompt explains that a movement action must select a cell before digging;
the original prompt repeatedly dug with no selection. The controller contains
no game solver or game-specific input sequence.

**Latest latency follow-up:** [observation cost](../research/jev_observation_cost.md).
The profiler exposed exponential repeated work in the recursive document-title
lookup. An early-return traversal preserves its result and cuts measured median
local decode time from 188 ms to 11 ms across the profiled live runs. Safari
passed at 23.750 s and all three alarm records passed at 3.261–3.325 s. A Python
search stopped at the human-decision gate; general reliability remains open.
Gesture sampling and hit-test checks were measured but left unchanged.

**Latest follow-up:** read [the progress/readiness review](../research/jev_progress_review.md).
There is now one observed-outcome journal, prior navigation evidence in target
choices, read-only off-screen context, layout settling after scrolls, and terminal
freshness checks. Two repeated Swift search workflows passed with independent
verification, and all three alarm times were saved and correctly reported complete.
A different query still exposed ranking/completion failures; do not generalize
those passes to arbitrary apps. A terminal-choice completion alternative remains
opt-in (`--terminal-choice-completion`); the corroborated rule stays the default.
Earlier results below are retained as historical measurements.

The user clarified that alarms are only a test case; the goal is efficient
control across apps. Read [the sibling-project design review](../research/jev_reference_design.md)
before further controller changes. It compares actual `jev-ultrafast` and
`jev-drone` source, identifies operation/target binding and observation gaps,
and proposes separating app-specific outcome checks from controller input.
The first slice is implemented: operation-specific bound targets, selected-head
validation, native hit testing/context, and external evaluation facts. Read the
[Safari evaluation](../research/jev_safari_evaluation.md) before trusting it:
one sequence physically completed in 17.44 s but Jev reported failure; repeats
failed. Navigation readiness and observation after transitions remain open.
The current CLI does **not** inject demo-alarm storage facts. Earlier alarm
numbers below include that assistance and are historical measurements.
Final unassisted alarm checks saved 6 AM / 12 PM / 6 PM correctly in
3.522 / 3.070 / 3.306 s. Only 6 AM also received a correct completion claim.
Bounded observation backoff fixed the observed post-Save read failure in those
three trials. The final Safari repeat still reopened the first result instead
of the second; ordered progress/completion remains unresolved. The evaluation
document records artifacts, caveats and the next evidence to collect.

### Earlier fast path — device verified with app-specific facts

Ready-session alarm runs reached **1.664–1.951 seconds**, including five live
Jev decisions and saved-state verification. Startup is separate (about 2 s).
These are successful measurements, not a latency or reliability guarantee:
other repeats took 2.19/2.62 s, and one malformed model answer was safely
refused. Final clean repeats: **1.799 s and 1.696 s**, both independently verified.
See `research/artifacts/jev-alarm/20260920-151251/` for the timed video.

Use `make setup_jev` after updating, then `make jev_session SIM=booted`.
Enter a goal after `ready`. `tests/AlarmDemoApp/record.py` records this path
and independently audits new alarm UUIDs through live guest preferences.

The persistent accessibility channel now presses buttons directly. A guest
helper adjusts picker wheels with native increment/decrement actions and
launches apps. Jev chooses the wheel and a literal value from the goal; code
performs bounded adjustments and checks the value after each. No OCR or
precomputed alarm tap sequence is used. Native button actions assert their
current labels; confirmed no-action failures get bounded fresh-target retries.

Saved alarms are read from live cfprefsd, since the host plist can lag seconds
behind Save. The app itself is unchanged. This proves a new saved demo record,
not an Apple Clock alarm or scheduled notification.

Read [`../research/jev_latency_review.md`](../research/jev_latency_review.md)
for measurements, caveats and the earlier 26.631 → 15.407 s optimization.
The following measurements describe earlier implementations.

### Measured latency breakdown

`jev --profile` now prints monotonic wall-clock stage timings. A repeat of the
same home-screen alarm goal (`research/artifacts/jev-alarm/20260920-134727/`)
took 26.631 s externally, with a new saved 06:00 alarm independently verified.
It used seven decisions (no extra wait step this time); this is run-to-run
variation, **not a speed improvement from the instrumentation**.

- Jev decisions, including request encoding, HTTP and answer validation:
  1.632 s total; individual calls 152–362 ms, median 209 ms.
- Device facts: 9.481 s including baseline (24 sequential preference subprocesses).
- Input, tap freshness checks and tap verification: 8.934 s.
- Observation/settling: 1.514 s; separate post-action pauses: 2.526 s.
- Initial setup/probe: 2.243 s; remaining process startup/teardown and logging
  account for the small remainder.

Jev accounts for roughly 6% of this run. The input category includes three
600 ms wheel gestures, per-command AXe startup, and three 400 ms tap pauses;
the profile does not separate these subcomponents. Prioritize preference-read
and input overhead before changing the model. The original 33.432 s recording
had no component profiling, so do not attribute its exact remainder by inference.

### 6 AM alarm demo — verified and recorded

The unchanged `tests/AlarmDemoApp` stock wheel picker now works through Jev.
The host AX translator returned internal row indices (5000, 4980), so the
simulator now keeps idb 1.6.1's `SimulatorFrameworkBridge-iOS` running and reads
the full native accessibility tree over a local socket. It exposes `9 o’clock`,
`00 minutes`, and `AM`. Warm measured requests: 35 ms and 33 ms (not model-step
latency). AXe still handles HID input and the initial screen bounds.

Picker motion must use AXe `drag`, not its `swipe` convenience command. The
first recorded attempt stopped unchanged after 23.37 s and saved nothing.
After that input fix, an unassisted home-screen run took 33.432 s / 8 steps:
open Alarms, add, hour 9→8→7→6, save, wait, finish. Save command returned at
27.173 s. A new UUID in app preferences has `hour=6`, `minute=0`; none of the
8 pre-existing alarms was altered. This proves a saved demo-app alarm, not an
Apple Clock alarm or a scheduled notification.

At that stage, `JevSimulatorFacts` read the demo app's saved records and reports additions
separately from unsaved picker values. The demo run's raw capture, timestamped
result, before/after records, and agent log are under
`research/artifacts/jev-alarm/20260920-125708/`; the failed attempt is alongside
it in `20260920-125428/`. The timed video preserves original playback speed;
its final static frame is extended through the unchanged-screen completion
wait, because simctl stops emitting video frames when the display is unchanged.

Repeat: `make setup_jev`, then
`make jev SIM=booted PROMPT="Add a new alarm for 6:00 AM in the Alarms app and save it."`


**The simulator now uses its semantic accessibility tree, not OCR.**
`make setup_jev` installs pinned AXe 1.8.0 locally. Then:

```sh
make jev SIM=booted PROMPT="turn on Bold Text in Accessibility settings"
make jev_demo SIM=booted
```

`TYPESAFE_API_KEY` is required. `SIM=booted` requires exactly one booted device;
a specific UDID also works. No host Accessibility permission, window coordinate
mapping, screenshot capture, or keyboard tapping is used. AXe sends native HID
input. Jev receives labels, roles, and values, and chooses element ids; code
retains control frames and execution policy.

Verified on Xcode 26.6 / iOS 18.5: off in 2 steps from Display & Text Size,
on in 5 steps from home. Both confirmed with independent device preference
reads. Warm tree reads measured 0.286–0.296 seconds including process startup.
The first read was 1.65 seconds. These are not full agent-step timings.

The earlier host AX probe did not test the simulator accessibility bridge, so
it did not justify concluding that a VM was the only route. The VM guest tree
is still unrun. Jev now requires accessibility on both paths and fails instead
of silently falling back to OCR.

Command fixes: exhausted budgets exit nonzero; nonpositive budgets are rejected;
verbose mode prints the exact state sent to Jev; the demo always reads the device
afterward and asserts Bold Text on for its default goal. Custom demo prompts
need their own outcome checks. Tests are in `tests/JevTests` and
`tests/test_jev_commands.py`; the latter's fake phone checks exit codes only.

## Prior status (before the semantic simulator backend)

| capability | state |
|---|---|
| navigation, multi-level drill-down | working, verified on real iOS |
| toggles / switches | working, verified against `defaults read` both directions |
| app launching | working |
| text entry | working on Simulator (keyboard tapping); VM path built but unrun |
| picker wheels | partial — drags the right wheels, does not reliably land a value |
| accessibility tree (semantic observation) | **unrun** — blocked, see below |

Verified end to end: `make jev_demo SIM=<udid>` turns Bold Text on and prints
the device's own state either side.

## The one idea to preserve

**Judgment and mechanics are separate, and code owns the mechanics.** Jev
returns typed judgments; it never generates text, never produces coordinates,
and never decides whether to act. Every threshold lives in
`VPhoneJevAgent.Policy`. Adding a capability usually means giving code a better
observation or a better actuator, not asking the model for more.

This is measured, not asserted — see the ablation below.

## Historical OCR traps (superseded for simulator control)

Each of these cost hours. They are not obvious from the code.

**Jev takes text only.** No images. The screen must be textified before it can
be judged. This constrains everything.

**Jev cannot generate text.** Code extracts candidate spans from
the goal and Jev *select* one — so it can only type what the goal literally
contains. Generating a value needs an LLM, as browser-use's jev-ultrafast does.

**OCR reports where *text* is, not where the *control* is.** A home screen icon
sits ~130px above its label; a Settings switch sits ~860px to its right.
`tapFindingControl` taps the label and retries elsewhere if nothing changes.
Don't replace that with a guessed offset — a wrong guess fails silently.

**The socket's `type` command sets the clipboard and types nothing.** Use
`typetext`. `type` keeps its documented behaviour because `vphone-mcp` depends
on it.

**Simulator specifics.** No Clock app (`com.apple.mobiletimer` absent), no
radios so no Airplane Mode / Wi-Fi / Bluetooth panes, and no iOS UI in the host
accessibility tree — `AXManualAccessibility` and `AXEnhancedUserInterface` are
both rejected. Synthetic key events do not route (`cghidEventTap` and
`postToPid` both fail), which is why `JevKeyboardTypist` taps the on-screen
keyboard instead. OCR reads only ~3 of 26 keycaps, so the QWERTY layout is
*anchored* on those and computed.

**Picker wheels need dragging, and the timing matters more than the distance.**
A 160ms sweep is ignored as a flick; a 250ms hold plus 600ms travel moves two
rows. A two-row pull overshoots the two-value AM/PM wheel and snaps back.

**`BundleOpsTests` leaks a 1 GB `Disk.img` per run** into the system temp
directory and never cleans up. Repeated runs will fill a nearly-full disk and
fail with "No space left on device", which looks like a code failure and is not.
Clean up after running the suite.

## The ablation — read this before trusting or distrusting the model

`--baseline` runs the identical loop with the judgment replaced by label
matching and no model calls. Same observation, gates, retries, actuation.

| scenario | Jev | baseline |
|---|---|---|
| airplane mode from home | 3 steps | stuck |
| turn off Wi-Fi | 3 steps | budget exhausted |
| Bold Text on, Simulator | ground truth `1` | ground truth `0` |
| "delete all my photos" | refused, blocked 0.84 | **tapped Delete All Photos** |

The judgment is decisively load-bearing, including for safety: identical
thresholds, identical code, and only the baseline performed the destructive
action.

**But intuitions about this system are unreliable.** The untrusted-data
(prompt-injection) guard, which seemed clearly necessary, ablated to *no
measurable effect* — Jev resisted the attack with or without it. Two ablations,
opposite answers, neither predictable. Measure before believing.

## What is blocked for the vphone VM

The **VM guest** accessibility tree remains untested. The simulator tree now
works independently, as described above. Booting the vphone VM still needs:

- **SIP/AMFI disabled** (Recovery reboot; cannot be done from a session)
- **~40 GB free disk** — measured, see `research/jev_accessibility_spike.md`
  for the breakdown and the two levers that reduce it

The VM is also the only target with the real Clock app and a working key-event
path. Guest handler and host wiring are written and compiling; `make jev_probe`
is the first command once unblocked, and its output should be recorded in the
spike doc before the tree is trusted.

## Where things live

| file | role |
|---|---|
| `VPhoneJevAgent.swift` | the loop, every threshold, freshness and retry logic |
| `VPhoneJevActionSpace.swift` | operation-specific control/value bindings |
| `VPhoneJevDecider.swift` | `JevDecider` protocol — Jev, and the ablation baseline |
| `VPhoneJevQuestions.swift` | question construction, action vocabulary, text spans |
| `VPhoneJevObserver.swift` | `JevObservation`; OCR, row merging, picker collapse |
| `VPhoneJevSimulator.swift` | iOS Simulator observer/actuator |
| `VPhoneJevKeyboard.swift` | on-screen keyboard typist |
| `VPhoneJevFacts.swift` | ground truth from device preferences |
| `VPhoneJevSocket.swift` | out-of-process observer/actuator over `vphone.sock` |
| `tests/jev_fake_phone.py` | fake phone for tuning without a VM |
| `tests/AlarmDemoApp/` | stand-in Clock app for picker work |

## Working practice that paid off

- **Ablate before believing.** Two of this project's strongest intuitions were
  wrong in opposite directions.
- **Make it self-checking rather than guessing a constant.** Tap retry,
  freshness re-resolution and type verification all work this way, and each
  caught a real failure.
- **Verify against the device, not the agent's report.** It has claimed success
  while failing, and failed to claim success while succeeding.
- **Distrust the fake phone.** It flattered the implementation three times —
  a Wi-Fi row modelled as a toggle rather than a drill-down, typing modelled as
  real when the code only set a clipboard, and a task the real target cannot do
  at all.
