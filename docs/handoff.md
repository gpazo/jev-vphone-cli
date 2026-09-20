# Handoff

What this project is, what actually works, and the traps that cost real time to
find. Read this before changing the Jev agent.

## What it is

`vphone-cli` boots a virtual iPhone and can drive it — tap, swipe, type, launch
apps. This work added an agent that decides *what* to drive: you give a goal in
plain language, and **Jev** (TypeSafe's System One model) picks one bounded
action per step.

`docs/jev.md` is the design document. This file is the state of play.

## Status

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

## Traps

Each of these cost hours. They are not obvious from the code.

**Jev takes text only.** No images. The screen must be textified before it can
be judged. This constrains everything.

**Jev cannot generate text.** `text_span` has code extract candidate spans from
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

## What is blocked

The accessibility tree — a semantic observation with roles, values and control
frames — is the single change that would lift most remaining limits: picker
components, icon-only controls, toggle states, and the label-vs-control problem
all dissolve. It needs the vphone VM, which needs:

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
