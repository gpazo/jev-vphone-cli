# Remote Clef evaluation

## Bounded visual recovery follow-up — 2026-10-05

The user requested pstack-assisted improvements after the stalled board review.
The change keeps the existing opt-in Jev-first routing. An uncertain accessibility
judgment still permits at most one conditional Clef request for that decision.
The screenshot request now includes one fixed-choice diagnosis of the planner's
local proposal. Its answer and confidence remain explicitly unverified inference.
Clef does not generate a board description or a replacement plan.

Successful but unresolved visual judgments can now return a typed request to
replan. The planner discards the old route and action binding, and the agent
obtains fresh evidence without input or an execution-history entry. The planner
excludes the rejected action while the relevant evidence is unchanged. It matches
the operation, control, owner, and literal payload rather than transient element
IDs, and retains prior exclusions to prevent A/B/A repetition. After three consumed
recoveries, it stops before another planner or model cycle. The existing request,
step, time, and $5 lifetime limits remain independent.

One frozen replay used the original stopped screenshot and production questions,
plus the new diagnosis question copied from the implementation. It returned
HTTP 200 in **2.640 seconds**, with no phone input. Clef still weakly selected local
`finish`, with confidence **0.136**, probability 0.3647, and done 0.1689. The
original-goal answer was `continue` with probability 0.9501. The diagnosis was
`stillNeeded`, but only at **0.1105 confidence** and probability 0.4357. This does
not support trusting the diagnosis as fact. The useful control change is the
ability to reject an unsupported proposal and reconsider it without acting.

The replay used the existing free Workers AI access and reserved two more cents
in the original ledger. At this checkpoint, 31 entries reserve **$0.57**, leaving
**$4.43** under the unchanged local cap. These are conservative reservations, not
charges. No billing, token permissions, automatic top-ups, or schedule changed.

Evidence: [replay result](artifacts/clef-vision-recovery/20261005/diagnostic-replay/result.json)
and [replay provenance](artifacts/clef-vision-recovery/20261005/diagnostic-replay/provenance.json).
The full Jev suite reports **129 passing Swift tests**, with two optional export
tests skipped. The Python suites pass **24 replay, 7 planner, and 16 Donpa tests**.
Generic fixtures prove zero input during recovery, a fresh independently approved
action afterward, preserved acknowledgment, semantic exclusions across changed IDs
and ticking labels, A/B/A feedback, and exhaustion before another request. The
fresh recovery observation also bypasses automatic popup dismissal so that the
planner sees the screen before any input. Required done/blocked/risky answers now
reject missing, malformed, nonfinite, or out-of-range values for both classifiers.

`make build` and signature validation pass. The signed release still receives
SIGKILL before `--help` on this host, while the Simulator debug executable starts.
The bounded live continuation uses that tested debug executable. No security
settings changed. No retrospective board solution is supplied to the controller.

The subsequent live continuation
[20261005-202055](artifacts/jev-donpa/20261005-202055/result.json) ran for **371.22
seconds**, with 31 decisions and 26 native inputs. It started and ended at **87%**,
placed two additional flags, and observed 23 distinct cells. There was no win,
loss, or additional clearance. The independent accessibility audit completed
without errors. The final selection is row 7, column 2, and the mine counter is 005.

At steps 23 and 27, uncertain Jev judgments triggered conditional Clef calls.
Both returned HTTP 200, taking 17.286 s and 2.381 s. Clef's action confidence
remained 0.0969 and 0.1097. Its `stillNeeded` diagnoses also remained weak, at
0.1159 and 0.264 confidence. Each result produced a no-input recovery. The next
planner request retained the unverified diagnosis, excluded the prior operation
on the unchanged owner, and proposed a different action. Jev independently
approved those actions, which then executed with the existing native checks.
This establishes live recovery and continued inspection, not stronger board
reasoning from the visual diagnosis.

The third conditional call, at step 31, returned **HTTP 529**, with Cloudflare
code 5012 and `inference_error: Clef inference failed`. The controller stopped
immediately without retry or further input. The response does not identify a
billing or quota problem. The recorder's own `error` field is null because the
recording completed correctly; the controller's provider failure is recorded in
its stop event and the third Clef report.

The final original ledger has **34 entries, $0.63 conservatively reserved, and
$4.37 reservable** under the $5 cap. All original 30 entries are unchanged. The
four new requests include the frozen replay and all three live attempts; the
failed attempt retains its full reservation. Known usage equivalent is $0.0205842,
with three failed requests of unknown usage. These figures are not card charges.
No further inference was attempted after the 529 response.

Evidence: [recovery audit](artifacts/jev-donpa/20261005-202055/recovery-audit.json),
[agent log](artifacts/jev-donpa/20261005-202055/agent.log),
[stopped board](artifacts/jev-donpa/20261005-202055/stopped.png), and
[video](artifacts/jev-donpa/20261005-202055/raw.mov).

## Jev first, conditional Clef vision: live game — 2026-10-05

The user requested another Minesweeper game and then clarified the desired
routing: **Jev judges accessibility first; call Clef with a screenshot only
when that judgment lacks confidence**. This supersedes using Clef for every
text-and-image decision. The new opt-in `--clef-vision-fallback` implements
that routing without changing the default controller.

The fresh XS Drills trial [193959](artifacts/jev-donpa/20261005-193959/result.json)
ran for **211.38 seconds**, with 22 Jev decisions, 18 acknowledged native
inputs, and **one Clef request**. The first reveal cleared 87%; the controller
inspected 14 distinct cells and flagged one mine. It stopped at 87%, with
seven mines remaining on the counter and no win or loss. The independent AX
audit completed without errors. No input followed the final uncertain
decision. This was an incomplete attempt, not a win or reliability estimate.

The optional external planner was unchanged: AX/history in, one proposed
native action out, followed by Jev's independent judgment and all existing
contract and freshness checks. Clef only supplemented the low-confidence
judgment; the planner did not receive screenshots or hidden game state.

At step 22 the planner proposed chording row 4, column 7. Jev chose tap with
action confidence 0.94 but selected-target confidence **0.38**, triggering
the single vision request. Clef received the exact production state and
question batch plus a current small full-frame JPEG. It weakly preferred
`finish` for the **local subgoal**: action confidence **0.1368**, probability
0.368, and done 0.1644. Its separate original-goal judgment was `continue`
with probability 0.9513. This was not a claim that the game was won. The
planner translated the local finish to wait; the normal confidence/risk
guard stopped that wait, and no new native input occurred.

Post-run visual review confirmed an active board at 87%. It also suggests
the proposed chord was redundant: the selected cell's neighbors were already
open or flagged. That is a retrospective observation, not a fact fed back
to either model during play. The experiment validates conditional routing
and stopping; it does not show that visual fallback improved game progress.

Implementation and guard details:

- `JevVisionFallbackDecider` uses the existing policy's 0.85 confirmation
  threshold on the smaller of selected action/target confidence. A confident
  Jev decision does not invoke the screenshot helper. Errors, terminal status,
  and blocked/risky judgments are not fallback triggers.
- Clef selects from the same offered native actions, never screen coordinates.
  The wrapper checks app structure and target/owner state before and after
  inference, preserves the larger blocked/risky scores, and leaves planner
  binding and native input validation in place.
- At most 12 fallbacks are allowed per goal. The read-only Python helper
  requires the original ledger, reserves before HTTP, saves full evidence,
  and never retries. An HTTP, transport, budget, or malformed-answer failure
  propagates as a stop. No paid routing or token changes were introduced.
- After this run, weak local `finish` choices that do not satisfy the existing
  completion thresholds were made to stop directly at the fallback boundary.
  Previously the planner could convert one into another uncertain wait. A
  regression test covers the observed 0.1368/0.368/0.1644 case even with low
  risk, so stopping no longer depends on the model's risk estimate. No new
  inference or gameplay retry was used for that fix.

The one Clef request succeeded through direct free Workers AI access in
**2.413 seconds**, reporting 10,255 input tokens ($0.00246120 equivalent before
the free allowance, not a charge). The original shared ledger now contains
30 entries, **$0.55 conservatively reserved and $4.45 reservable** under the
unchanged $5 local cap. Total known usage equivalent is $0.01289004, and the
two original quota failures still have unknown usage. The one-time reminder
remains paused; no billing or permission changes.

Setup was operator-assisted and separately recorded: boot the existing
Simulator, preserve the existing tally with “Continue as before,” then New
game → XS Drills → Start. Those four setup taps occurred before the trial;
all 18 gameplay inputs came from the controller. The old `/tmp/jev-donpa`
checkout no longer resolves as a Git repository, so the recorder now records
unavailable source provenance explicitly while retaining the installed app
bundle hash. Two preflight attempts stopped at that provenance issue before
inference. A third stopped at controller startup: the VM-entitled release
binary passed build and signature verification but exited 137 on this host,
including for `--help`. The trial therefore used the tested Simulator debug
binary, as earlier Simulator trials did; its hash is in the run provenance.
No system security settings were changed.

Validation after the final guard/configuration changes: **119 Jev Swift tests,
24 DecisionReplay Python tests, and 16 Donpa audit tests passed**. The source
provenance failure was reproduced without network requests. No firmware
patches changed. `make build` is still required for the signed VM build; the
Simulator trial uses the debug executable because the signed release fails
at startup on this host; the cause remains unconfirmed. The recorder now
accepts `--binary` for explicit selection.

Evidence: [run result](artifacts/jev-donpa/20261005-193959/result.json),
[agent log](artifacts/jev-donpa/20261005-193959/agent.log),
[stopped board](artifacts/jev-donpa/20261005-193959/stopped.png),
[video](artifacts/jev-donpa/20261005-193959/raw.mov), and
[Clef request/response/budget report](artifacts/jev-donpa/20261005-193959/decisions/clef-vision-1422dc68671540099b7806b748546d0f/report.json).
The current Simulator is still on that active board; start a new top-level
goal if continuing it, and do not treat this partial run as fresh-game success.

## Manual combined-input retry — 2026-10-05, 19:20 Pacific

The user requested another attempt. One fresh pass of the three evidence
modes completed with the existing frozen paired screenshot/accessibility
state and unchanged questions and labels. All three requests returned HTTP
200 through existing direct Workers AI free access, with no retries, phone
input, billing changes, or live-controller changes. The retired scheduled
reminder was not reactivated.

All answers, probability distributions, and confidence scores exactly matched
the earlier nine-request comparison. Text correctly recognized completion
and appropriately returned unknown for the absent clue. Vision read the clue
but retained low status confidence (0.2634). Combined input answered all three
questions correctly, with status confidence 0.8674 and clue confidence 0.8424,
passing the unchanged diagnostic status gate. API times were 0.999 s for text,
1.017 s for vision, and **0.942 s for combined input**. One additional pass over
the same screen confirms repeatability, not general decision reliability.

The three requests reported 5,891 input tokens, corresponding to $0.00141384
at the previously recorded rates before the free allowance, **not a charge**.
The unchanged $5 local cap's original ledger now has 29 entries, **$0.53
conservatively reserved and $4.47 reservable**. Total known usage equivalent
is $0.01042884, with the two original failures still lacking usage.

Evidence: [fresh comparison and raw responses](artifacts/clef-multimodal/20261005/comparison-retry-20261006T022040Z.json).
No code changed; this used the existing tested comparison harness.

## Duplicate scheduled follow-up retired — 2026-10-05

The one-time reminder fired again at 17:05 Pacific on October 5 (00:05 UTC
on October 6). The October 4 scheduled attempt was already finished, and the
October 5 manual retry had completed the requested loss probe and six-case
comparison. To honor the single-follow-up limit, no new inference or phone
input was made. The saved reminder was still ACTIVE despite its one-occurrence
schedule; the scheduling cause is unconfirmed. The automation tool changed
`resume-clef-vision-after-free-quota-reset` to PAUSED, preserving its other
fields. No billing or permission change was made.

The original ledger was read but not modified: 26 reservations, **$0.47
conservatively reserved and $4.53 reservable** under the $5 local cap. These
remain internal accounting figures, not paid spending. The combined-input
experiment below remains the latest inference result.

## Combined accessibility text and vision — 2026-10-05

The user clarified that “both” means **one Clef model consuming the screenshot
and the same text/state currently supplied to Jev**, not a Jev/Clef ensemble.
A read-only comparison tested this directly using the completed Donpa board
without its victory overlay. Nine requests succeeded through existing free
Workers AI access: text, vision, and combined evidence, each repeated three
times with rotating order. No phone input or billing change was made.

The text was captured from the production Jev CLI using baseline dry-run mode
with custom accessibility actions enabled. It includes the actual goal,
device constraints, elements, native-action bindings, and history. Screenshots
before and after capture were identical below the system status area (y=180),
so the two modalities describe the same app state. The explicit accessibility
value “Cleared: 100%” is present; the board exposes only the current cell,
row 8, column 1, rather than every visible clue. Visual review established
that row 1, column 2 shows clue 2 before labels were frozen.

[`compare_modalities.py`](../tests/DecisionReplay/compare_modalities.py)
preserves the exact captured state in the text and combined arms. The vision
arm receives only the same goal plus the screenshot, without accessibility
evidence. The image is the same full-frame small JPEG in both image arms.
All arms use identical diagnostic questions about status, completion progress,
and clue r1c2. These are **perception questions, not the production controller's
action-selection batch**. Input files and labels are frozen with hashes.

| Clef evidence | Status / progress correct | Clue r1c2 | Status confidence | Status confidence gate ≥0.60 | Median API time |
| --- | --- | --- | --- | --- | --- |
| Existing Jev text | 3/3 each | Unknown in 3/3 | 0.9565 | 3/3 | 0.776 s |
| Screenshot | 3/3 each | Correct in 3/3 | 0.2634 | 0/3 | 0.990 s |
| Text + screenshot | 3/3 each | Correct in 3/3 | 0.8674 | 3/3 | 1.267 s |

Text-only “unknown” was appropriate: that cell is absent from the text. Its
zero ground-truth clue matches in the raw report must not be described as
three hallucinations. Both image arms read clue 2 correctly; combined clue
confidence was 0.8424, compared with vision-only 0.9037. Combined completion
progress confidence was 0.9112, compared with vision-only 0.1133. The status
gate also requires the selected option's probability to reach 0.60; combined
met both checks. This diagnostic gate records confidence, never permits input.

The combined arm retained the visual clue while giving substantially stronger
completion confidence than vision alone on this screen. Its answers and
scores were identical across repeats, as were the other arms. Repeating one
frozen screen does not establish cross-screen reliability or calibration.
Vision chose the correct status here, unlike the earlier restart probe;
that earlier probe used different questions and a different goal, so the
paired comparison above is the relevant evidence for the modality effect.

The integration direction is a single Clef request with existing semantic
state/native-action bindings plus a contemporaneous screenshot. It could use
image evidence for details absent from accessibility while retaining explicit
control names, values, and bounded native actions. This remains an opt-in
research harness: the production provider option still sends text only, Jev
remains the default, and no live combined controller was enabled. Additional
held-out active/loss/menu screens and action decisions are needed before
changing that default or claiming that Clef replaces Jev reliably.

Artifacts: [frozen case](artifacts/clef-multimodal/20261005/case.json),
[captured Jev state](artifacts/clef-multimodal/20261005/jev-state.json),
[paired screenshot](artifacts/clef-multimodal/20261005/after-text.png), and
[all responses and comparison](artifacts/clef-multimodal/20261005/comparison.json).
All 23 DecisionReplay tests pass, including evidence isolation between arms.

The nine calls reported 17,673 input tokens, equivalent to **$0.00424152 before
the free allowance, not a charge**. All requests, including text-only arms,
reuse the original lifetime ledger. It now has 26 entries, **$0.47 conservatively
reserved and $4.53 reservable** under the unchanged $5 local cap. Total known
usage equivalent is $0.009015; the two original quota failures still have
unknown usage. No purchase, subscription, token change, or future run.

To repeat the same frozen comparison with a new result file:

```sh
.venv/bin/python tests/DecisionReplay/compare_modalities.py \
  --case research/artifacts/clef-multimodal/20261005/case.json \
  --output research/artifacts/clef-multimodal/next-comparison.json \
  --model clef --runs 3
```

The harness requires the existing budget ledger and stops at the first
request or budget failure without retrying.

## First live visual tap — 2026-10-05

The user authorized testing what the free allowance can support. Eight more
requests completed without quota or transport failures, using the existing
direct Workers AI access and shared ledger. No billing changes or purchase
were made. The experiment produced **one verified physical tap located from
screenshots**, plus useful failures; it did not play a new game.

The new opt-in [`vision_live.py`](../tests/DecisionReplay/vision_live.py) takes
a human-specified visual target and goal, obtains Simulator screenshots, asks
Clef for bounded image regions, and maps the selected region to native device
points. An optional generic numbered grid provides spatial references. The
coarse region selects a read-only crop; a separate close-up must pass the
fixed target-presence gate (0.90) and both axis confidence/probability gates
(0.60). A fresh screenshot checks the target pixels before one physical HID
tap. A final before/after image request verifies the effect. Each invocation
has at most three inference calls and one tap, with no retries. Raw screenshots
are retained alongside model-input grids and crops.

No accessibility tree, OCR, app files, game oracle, or human-supplied screen
coordinates entered the decisions. The existing AXe executable was used only
for explicit x/y physical HID input. Screen size and scale came from Simulator
display metadata. This is a supervised target-grounding test; high-level
target descriptions were supplied by the operator, not an autonomous planner.

| Trial | Result | Native taps |
| --- | --- | --- |
| Live victory screen, Flash | Recognized won (confidence 0.9042); terminal guard stopped | 0 |
| Close X, Flash, unmarked image | Presence 0.8231 and poor localization; blocked | 0 |
| Close X, Clef, unmarked image | Axis confidence 0.3365 / 0.0914; blocked | 0 |
| Close X, Clef, coordinate grid | Correct coarse bins but x confidence 0.2344; blocked by initial coarse gate | 0 |
| Close X, Clef, grid and read-only refinement | Refined x/y confidence 0.8724 / 0.8159; tap and visual verification succeeded | 1 |
| New-board control, Clef, grid | Completed 100% board classified playing with confidence 0.392; status guard blocked | 0 |

The refinement revision allowed a valid low-confidence **coarse crop proposal**
to gather more evidence; it did not lower the final input thresholds. In the
successful trial, the final crop's target-presence score was 0.9830. Code mapped
the selection to (335.9375, 310.7708) device points. Clef judged the requested
panel dismissal achieved (confidence 0.7229), and the resulting raw screenshot
was independently reviewed: the illustration was gone and the completed board
was unobscured. The three API calls took 1.594, 0.944, and 1.327 seconds.

The successful dismissal used explicit **setup mode**, which permits menu and
result-panel navigation. It is not evidence of a game-playing agent taking
actions after terminal state: the ordinary trial mode first stopped without
input, and the one-tap setup invocation also recorded a terminal stop after
verification. The subsequent new-board attempt sent no input. The app remains
on the same completed board with its illustration dismissed.

This establishes one successful supervised visual target/tap/verification
cycle. It does not establish general targeting reliability, fresh-board play,
or a replacement for accessibility. The next useful experiment is stronger
status recognition on completed boards without a result overlay, followed by
diverse held-out control targets. Preserve the existing input gates.

Artifacts are under [`clef-vision-live/20261005`](artifacts/clef-vision-live/20261005/).
The successful run has a [report](artifacts/clef-vision-live/20261005/05-close-panel-refined-clef/report.json),
[before screenshot](artifacts/clef-vision-live/20261005/05-close-panel-refined-clef/before.png),
and [after screenshot](artifacts/clef-vision-live/20261005/05-close-panel-refined-clef/after.png).
The eight requests represent $0.00266613 at the published rates before the free
allowance, **not a charge**. The lifetime ledger now has 17 entries, $0.29
conservatively reserved and $4.71 reservable; these are local test-accounting
figures, not prepaid credit balance or paid spending. The two original failed
requests retain unknown usage. No future run was scheduled.

All **22 replay/budget/live-guard tests pass**, including no native input on
terminal/error/ambiguous/stale observations, dry-run behavior, and no second
tap after verification failure. No Swift or firmware changes were needed.

For a read-only live terminal probe (new output directory required):

```sh
.venv/bin/python tests/DecisionReplay/vision_live.py \
  --simulator 108417FD-4FA3-4315-9587-0F4A0469E561 \
  --output research/artifacts/clef-vision-live/next-terminal-probe
```

`--target` and `--goal` enable target localization; input remains off unless
`--execute` is supplied. `--grid` enables generic coordinate guides. Use
`--setup` only for explicit setup/navigation, never to bypass terminal
stopping during a game-playing trial. The same existing budget ledger is
required for every invocation.

## Successful retry — 2026-10-05

The user requested another attempt. At approximately 06:26 Pacific / 13:26
UTC, the same direct Workers AI request succeeded without any billing or
permission changes. Clef correctly identified the loss screen and upper-right
close button in **1.165 seconds**, with 1,126 input tokens. This confirms that
the smaller full-frame loss image can reach image inference. It does not
explain why the earlier post-reset request was rejected.

The conditional single-pass comparison then completed all six requests:

| Model | Screenshots with all answers correct | Individual questions correct | Median API time | Reported input tokens |
| --- | --- | --- | --- | --- |
| Clef | 3/3 | 9/9 | 1.330 s | 5,567 |
| Clef-flash | 3/3 | 9/9 | 0.796 s | 5,567 |

Both models recognized playing, lost, and won states, and the absence or
upper-right location of the close button. On the playing image they also
identified selected cell r5c6, clue 4 at r3c3, and covered cell r1c1. Frozen
questions and labels were unchanged; no AX/OCR evidence or phone input was
used. There were no HTTP errors or false completion claims in this sweep.
Requests were sequential and alternated model order across cases. Each used
a fresh connection because the existing harness was invoked for one request
at a time, allowing the sweep to stop on any request failure without retries.

Correct choices are not sufficient evidence for reliable visual control.
Selected-cell confidence was only 0.2932 for Clef and 0.1733 for Clef-flash;
Flash's correct loss-state answer had confidence 0.2165. No action thresholds
were changed. This is one pass over three images, not a live-control result
or a reliability estimate. Keep Jev as default; screenshot-only native
targeting and post-action verification remain unimplemented.

Seven successful requests were made in this turn (one probe plus six paired
cases). The unchanged shared ledger now contains nine entries including the
two earlier quota failures: **$0.15 conservatively reserved, $4.85 remaining**.
At the October 3 rates, reported usage from the seven successes corresponds
to **$0.00210735** before the free allowance; this is a usage estimate, not a
card charge. Both prior failures still have unknown usage and retain their
reservations. No credits or subscription were purchased or billing settings
changed, and no further run was scheduled.

Evidence: [loss probe](artifacts/clef-vision-budget/20261005-morning-loss-probe.json),
[paired comparison](artifacts/clef-vision-budget/20261005-small-vision-comparison.json),
and [individual request reports](artifacts/clef-vision-budget/20261005-vision-single-pass/).

## Scheduled follow-up — 2026-10-04

The one-time follow-up ran after the documented daily reset, on October 4
after 17:05 America/Los_Angeles (October 5 after 00:05 UTC). The existing
direct Workers AI endpoint rejected the single `jpeg-small` loss-image Clef
probe with **HTTP 429, code 4006**, in 0.506 seconds. It used the same
163,100-byte request and SHA-256 as the previous probe. No answers or usage
were returned. The reason quota remained unavailable after the documented
reset is unconfirmed; the image transport fix remains unvalidated.

The harness stopped after that one request. The conditional six-request
comparison did not run, and no retries, phone inputs, billing changes, token
permission changes, or replacement schedules were made. This completes the
single scheduled attempt, not the vision evaluation.

The original ledger entry is preserved. The shared ledger now contains two
2-cent reservations: **$0.04 conservatively reserved and $4.96 remaining**
under the unchanged $5 limit. Both requests lack usage, so actual billed
cost is unknown; the reservation is not a claim of paid spending. Evidence:
[scheduled probe result](artifacts/clef-vision-budget/20261004-reset-loss-probe.json).

## Status — 2026-10-03

Cloudflare credentials work. The paired semantic comparison completed all 90
requests. **Keep Jev as the default controller:** with the existing prompts,
Jev matched 27/30 expected decisions, Clef 15/30 and Clef-flash 9/30; both Clef
models were slower. This measures compatibility with the existing decision
contract, not the models' potential after prompt or controller changes.

Screenshot perception is promising but incomplete: both Clef models answered
all five questions about one active-board screenshot correctly on all three
repeats. Win/loss screenshots were rejected with HTTP 413 before answers were
returned. A JPEG transport experiment also encountered HTTP 429; diagnostics
confirmed the account's daily free allocation was exhausted. No further
inference was attempted after confirming that limit. These results do not
establish that accessibility can be removed.

The Swift CLI accepts `--provider cloudflare --model clef` or `clef-flash`.
The existing TypeSafe provider remains the default. Provider choice changes
the endpoint, model selector, key source, and response envelope only. The
semantic observer, bound action choices, native execution checks, planner
defaults and policy thresholds are unchanged. Cloudflare errors fail before
decoding a usable decision. Run headers identify the selected provider/model.

No firmware or kernel patch was added, so the binary patch comparison is
unchanged. No phone input was performed in this evaluation.

## Authorized $5 vision experiment — 2026-10-03

The user authorized $5 of prepaid AI credits, with a $5 experiment cap and no
subscription. The signed-in Chrome checkout subsequently showed a **$10
minimum top-up plus a $0.50 processing fee**. The proposed $5 prepaid purchase
is therefore unavailable. No payment was submitted by the agent, and no
subscription was enabled. The user then reported that Cloudflare rejects
their billing address, blocking card setup; stop the billing workflow. Do not
retry checkout, change the address, or treat the earlier question about a
larger purchase as approval. No account-level spending limit or automatic
top-up setting was configured or verified.

Continue with the existing free allowance when it resets, without enabling
paid billing. Cloudflare documents a daily reset at 00:00 UTC (17:00 Pacific
during daylight time). At 2026-10-04 03:13 UTC, the most recent probe was still
within the exhausted allowance's UTC day; no redundant inference retry was
added. After the user agreed to wait, a single follow-up was scheduled for
October 4 at 17:05 America/Los_Angeles in this task
(`resume-clef-vision-after-free-quota-reset`). It may attempt one small loss
probe and, only on success, one three-case repeat on each model; no phone
input or billing change is authorized by that follow-up. It must retain the
same ledger and stop on quota/authentication/transport/budget failure.
If prepaid billing is revisited, it also requires
gateway routing and Unified billing configuration. The current token's
gateway-list read returned HTTP 403/code 10000; its permissions were not
changed. The replay still uses the direct Workers AI endpoint.

Vision replays now always reserve against
`research/artifacts/clef-vision-budget/ledger.json`, shared across runs and
restarts. This is a local experiment limit, not a Cloudflare account spending
limit. Reuse this ledger; do not delete it or supply a fresh one to renew the
allowance. It uses the published 65,536-token maximum and October 3 rates to
reserve 2 cents for each Clef request or 1 cent for Clef-flash, rounding upward.
Reservations are persisted before network submission, protected by a file
lock, and retained after failures or unknown outcomes. The harness refuses
another request if its reservation would exceed $5. Reported input-token
cost estimates are recorded separately and never release reservations.

The new `--image-encoding jpeg-small` arm keeps the full frame, resizes its
long edge to 1280 pixels, and encodes JPEG quality 80. All three images were
visually reviewed after conversion. Frozen labels and questions are unchanged;
dimensions and image hashes are recorded. Request sizes are 66,176 bytes
(playing), 163,100 (lost), and 145,012 (won).

One [budgeted loss-image probe](artifacts/clef-vision-budget/20261003-small-loss-probe.json)
returned HTTP 429, code 4006. It no longer returned HTTP 413 on this attempt,
but the quota error prevents confirming image inference. The sweep stopped
immediately. There are **zero new successful inference calls**, **$0.02
conservatively reserved**, and **$4.98 available for further reservations**.
No usage was reported for the rejected request, so its actual billed cost is
unknown. No live phone input has been attempted.

Offline verification now passes 17 replay/budget tests. Coverage includes
reservation persistence, concurrent requests competing for the last cent,
stopping before network submission when the budget is full, preserving the
reservation after HTTP 429, and the reduced image payload sizes.

After billing access or the free allowance is available, start with the single
loss image below, then run one repeat of all three images on both models.
Only broaden to live targeting once terminal perception works. Reuse the
default budget ledger for all calls, including any future live harness.

```sh
python tests/DecisionReplay/compare_providers.py \
  --suite vision --models clef --runs 1 --case lost \
  --image-encoding jpeg-small \
  --output research/artifacts/clef-vision-budget/small-loss-next.json
```

The live milestone remains: identify a visible cell, map it to a native tap,
verify the resulting screenshot, and issue no further input after a win/loss
panel. Accessibility/OCR and hidden game state must not enter that controller's
observations. This controller is not implemented or validated yet.

Billing references: [prepaid credits and fees](https://developers.cloudflare.com/ai-gateway/features/unified-billing/),
[free allocation and reset time](https://developers.cloudflare.com/workers-ai/platform/pricing/).
The minimum purchase is an observation from this account's checkout, not a
published general pricing promise.

## Paired semantic results

Ten existing frozen cases, three repeats each; labels were authored before
this experiment in [`cases.json`](../tests/DecisionReplay/cases.json). Inputs
are the original committed request fixtures, with no compact transformation.

| Measurement | Jev | Clef | Clef-flash |
| --- | --- | --- | --- |
| Returned model | `jev-1.13.0` | `clef` | `clef-flash` |
| Correct selected decisions | 27 / 30 | 15 / 30 | 9 / 30 |
| HTTP / scoring errors | 0 / 30 | 0 / 30 | 0 / 30 |
| False completion claims, replay scorer | 0 / 30 | 0 / 30 | 0 / 30 |
| Contacts-save readiness correct | 3 / 3 | 3 / 3 | 3 / 3 |
| Median request latency | 239 ms | 2,645 ms | 1,082 ms |
| p95 request latency, nearest rank | 481 ms | 3,929 ms | 11,703 ms |
| Median reported input tokens | 16,654 | 12,675 | 12,675 |
| Total reported input tokens | 614,754 | 350,193 | 350,193 |

| Frozen case | Jev | Clef | Clef-flash |
| --- | --- | --- | --- |
| Contacts create | 3/3 | 3/3 | 0/3 |
| Contacts fill | 3/3 | 3/3 | 3/3 |
| Contacts save | 3/3 | 0/3 | 0/3 |
| Contacts complete | 3/3 | 3/3 | 3/3 |
| Calendar initial end | 3/3 | 0/3 | 0/3 |
| Calendar repair start | 3/3 | 0/3 | 0/3 |
| Calendar final end | 3/3 | 0/3 | 0/3 |
| Calendar complete | 0/3 | 3/3 | 3/3 |
| Safari Back | 3/3 | 3/3 | 0/3 |
| Safari second result | 3/3 | 0/3 | 0/3 |

Clef's picker decisions selected downward drags rather than the predeclared
native value-selection action. A drag might make progress over multiple steps;
this exact-decision regression does not prove a live task failure. Both Clef
models selected Finish on the unsaved Contacts form, but with low selected
probability and low done scores; neither counted as a false completion claim.
Both correctly recognized the completed Calendar case that Jev missed.

[Paired requests, responses and timings](artifacts/clef-remote/20261003-paired-decisions.json)
are in the gitignored research artifacts directory. Evidence hashes match
across all providers and repeats for each case. The earlier
[Jev-only baseline](artifacts/clef-remote/20261003-jev-baseline.json) also scored
27/30, with 282 ms median latency; use the paired run for comparisons.

The small selected regression set is not an estimate of overall task success.
Latency includes provider/network time and first-request connection setup;
it excludes phone observation, input, verification and planning. Connection
reuse does not explain the median gap: warm-request medians were 238 ms,
2,643 ms and 1,056 ms respectively. Clef-flash had two requests above 11 seconds.
Reported token accounting differs by provider; no billing-cost comparison was
made from these token counts.

## Run the semantic comparison

Cloudflare requires an account ID and a Workers AI API token. Its dashboard
offers a **Use REST API** flow; the custom token permissions are Workers AI
Read and Edit. Keep credentials outside the repository and trace files.
[Official setup](https://developers.cloudflare.com/workers-ai/get-started/rest-api/).

Set `TYPESAFE_API_KEY`, `CLOUDFLARE_ACCOUNT_ID`, and `CLOUDFLARE_API_TOKEN`
in the execution environment. `CLOUDFLARE_AUTH_TOKEN` is also accepted.

```sh
source .venv/bin/activate
python tests/DecisionReplay/compare_providers.py --validate-only
python tests/DecisionReplay/compare_providers.py \
  --models jev clef clef-flash --runs 3 \
  --output research/artifacts/clef-remote/paired-decisions.json
```

The default comparison sends 90 inference requests: ten cases × three repeats
× three models. The model selector is the sole payload difference. Expected
labels are not model input. The order rotates by case and trial; connections
are reused. Results are saved after each call. Errors stay in the denominator,
authentication and HTTP 429 rate/quota errors abort the sweep, existing output files are not
overwritten, and inference requests are never automatically retried. Request
and evidence hashes allow checking that the inputs matched across providers.

Scoring uses the existing action/target and completion labels. Required
done/blocked/risky answers must also be finite probabilities with the correct
type. Form readiness is reported separately. This scorer does not simulate
every controller gate, native freshness, retries or human confirmation; a
correct frozen selection is not proof that a live action will be performed.
The original compact-request experiment remains separate and unchanged.

## Screenshot-only probe

Three screenshots were frozen and visually reviewed before any Clef calls.
Their source recordings, extraction positions, hashes and expected answers
are in [`vision-cases.json`](../tests/DecisionReplay/vision-cases.json).
The original source pixels are retained; no labels or markers were drawn on
the images. The labels and filenames are not passed to the model.

| Case | Visible evidence | Questions |
| --- | --- | --- |
| Playing | 82% clear, active board | Game status; absent result-panel close button; selected cell r5c6; clue 4 at r3c3; covered r1c1 |
| Lost | Explosion result panel, red mines, 87% | Game status; close X at upper right of panel |
| Won | Minefield cleared result panel, 100% | Game status; close X at upper right of panel |

```sh
python tests/DecisionReplay/compare_providers.py \
  --suite vision --models clef clef-flash --validate-only
python tests/DecisionReplay/compare_providers.py \
  --suite vision --models clef clef-flash --runs 3 \
  --output research/artifacts/clef-remote/paired-vision.json
```

This sends 18 requests. Every request contains one embedded PNG, an invariant
instruction and bounded choices. It contains no accessibility tree, OCR,
history, hidden game state or outcome labels. A case counts as correct only
if every requested choice is valid and matches its frozen label; individual
vision checks are retained in the raw results. The completion metric here
means selecting `won` for the image, not the live controller's done gate.

These are basic perception probes in one app, not a game strategy benchmark,
UI grounding benchmark, or validation of coordinate-based input. Passing them
would justify broader tests with varied controls and precise tap targets;
it would not justify removing accessibility from the controller.

### Observed vision results

The [original PNG run](artifacts/clef-remote/20261003-paired-vision.json) made
nine attempts per model. Each model returned three correct active-board
responses (five correct visual answers each), with six HTTP 413 errors for
the two terminal screenshots. Active-board median latency was 1,777 ms for
Clef and 1,121 ms for Clef-flash. Each successful request reported 3,582 input
tokens. These are three repeats of one image, not fifteen independent scenes.

`--image-encoding jpeg` converts to RGB JPEG quality 90 at the original
1206×2622 resolution. It requires Pillow. It preserves dimensions, questions,
labels and original files; the manifest records the transport image's size
and hash separately. The compressed images were visually inspected. This is
lossy re-encoding, not identical image evidence to the PNG arm.

The [JPEG run](artifacts/clef-remote/20261003-paired-vision-jpeg.json) returned
no model answers: all six active-board attempts received HTTP 429, and all
twelve terminal-image attempts received HTTP 413. These are transport failures,
not wrong visual answers. This run preceded the harness's new stop-on-429 rule.

[Three diagnostic requests](artifacts/clef-remote/20261003-transport-diagnostics.json)
then distinguished the limits:

- A tiny text-only request and the 209,644-byte active-board JPEG request
  returned HTTP 429, Cloudflare code 4006, stating that the account's daily
  free allocation of 10,000 neurons was used up. Neither supplied Retry-After.
- The 725,304-byte loss JPEG request returned HTTP 413, code 5021, with an
  estimated input-plus-output token count of 181,326 against a 65,536 limit.
  An earlier loss PNG diagnostic gave the same code with an estimate of
  566,306 tokens for a 2,265,223-byte request.

These images were below the schema's documented 4 MiB per-image and 16-megapixel
limits, and the requests were below its 13 MiB body limit. The observed
token-estimation rejection is a separate obstacle; its server-side cause is
unverified. Merely switching to JPEG quality 90 did not resolve it.
[Image schema](https://developers.cloudflare.com/workers-ai/models/clef/schema-input.json).

Cloudflare documents a daily reset at 00:00 UTC and requires Workers Paid to
exceed the free allowance. No billing settings were changed.
[Workers AI pricing and limits](https://developers.cloudflare.com/workers-ai/platform/pricing/).

## Validation and next steps

Initial offline validation: 113 Jev Swift tests, 11 Python replay tests and 8 command
tests passed. `make build` produced the signed release binary. Swift transport
tests cover provider-specific configuration, matching model/endpoints,
credential isolation, request bodies, Cloudflare envelopes, HTTP failures
and CLI selection. Replay tests cover unchanged evidence, frozen image hashes,
label separation, scoring, error accounting, JPEG dimensions and saving a
partial result while stopping further calls on authentication/quota failure.
The Swift transport has offline coverage; the successful remote calls above
used the Python harness. No live Swift controller completion is claimed.

Environment note: the documented `make setup_venv` target is absent in this
checkout. Running `zsh scripts/setup_venv.sh` created `.venv` and installed the
Python requirements, then stopped because Homebrew's native Keystone library
is absent. These evaluations use the working venv; JPEG conversion also uses
Pillow. They do not require Keystone. No firmware tests were run.

Next: after allowance is available, test a smaller image encoding on one
terminal fixture before repeating a sweep. Then broaden screenshot perception
to varied controls and precise tap targets. Keep the original prompts/labels
and failed runs for comparison. A screenshot-only controller still needs
bounded visual targeting, input mapping, freshness and completion checks;
these are not implemented by changing the provider. Keep API speed, perception,
decision correctness and end-to-end task completion as separate measurements.

API references: [Clef](https://developers.cloudflare.com/workers-ai/models/clef/),
[Clef-flash](https://developers.cloudflare.com/workers-ai/models/clef-flash/),
[image/request schema](https://developers.cloudflare.com/workers-ai/models/clef/schema-input.json),
[answer schema](https://developers.cloudflare.com/workers-ai/models/clef/schema-output.json).
