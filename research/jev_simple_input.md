# Simpler native input and measured Settings demo — 2026-09-21

The state-memory experiment remains removed. This follow-up changes observation
and execution, with no game solver, app navigation plan, new policy mode, or
OCR. Jev continues to select live bound choices from accessibility text.

## Changes and direct evidence

Ordinary and named presses now use the existing guest translator service.
Previously, ordinary native controls took the reader's separate
`AXUIElementPerformAction` path, with a separate retry loop. The Donpa “Not now”
dialog failed there with -25200; a subsequent fresh observation and translator
press succeeded, and an independent reader confirmed the dialog disappeared.
This probe happened outside the recorded gameplay. No uncertain input is
replayed automatically. The shared service still checks the live target.

The observer preserves native keyboard context and static row text from
unlabelled cells. For example, identical Edit controls in Alice/Bob rows remain
distinguishable, and a keyboard go key is described in Keyboard context. It
neither invents a control label nor teaches Jev what a particular app's button
does. A focused regression test covers those identity differences.

The live Safari follow-up selected go and submitted the literal query, whereas
the prior run chose suggestion completion repeatedly. This does **not** establish
causality: all six frozen replay calls selected go, with and without the new
context (three per variant). Saved requests and responses are under
`artifacts/jev-simple-input/20260921/`. This is an observation-fidelity change,
not a demonstrated improvement in model accuracy.

## Settings: independently verified, recorded at original speed

Task: turn Bold Text and Increase Contrast on, then a separate goal turns both
off. The same generic executable operates Apple's Settings app. The recorder
reads native switch values and saved accessibility preferences after each goal;
those readings are never supplied to Jev.

| Run | Starting point | Goal-to-report time | Independent result |
|---|---|---:|---|
| `20260921-180556/on` | Settings root | 5.652 s | Failed: input acknowledgment timeout; navigation physically occurred |
| `20260921-180654/on` | Accessibility page | 10.475 s | Both on; correct completion claim |
| `20260921-180654/off` | Display & Text Size | 3.622 s | Both off; correct completion claim |
| `20260921-180748/on` | Display & Text Size | 2.816 s | Both on; correct completion claim |
| `20260921-180748/off` | Display & Text Size | 2.714 s | Both off; correct completion claim |

The last pair is the delivered video:
[on/off demo](artifacts/jev-settings/20260921-180748/jev-settings-timed.mp4).
Two separate runs are joined, each at original speed, with a 1.5 s final hold.
Timers restart per goal. Session startup, previous navigation, and post-run
external preference auditing are excluded from goal-to-report times.
The pane was already open. These are not home-screen task times or a guaranteed
latency, and there was no matched old/new controller latency trial.

Both native switches read 1 after on and 0 after off. Independent saved
preferences agree: EnhancedTextLegibilityEnabled and DarkenSystemColors changed
0→1→0. PointerIncreasedContrastEnabled also followed the system's contrast
setting. The original settings were restored by the off goal.

The earlier off run issued its second acknowledged toggle at 1.035 s but
reported completion at 3.622 s. Profiling attributes 1.633 s to hit tests on the
next observation and another 0.514 s to the final fresh observation. The three
Jev requests totaled 0.845 s. This identifies observed device-read delays;
it does not justify removing freshness checks or promising a 1–2 s total.

The recording scripts, goal text, setup times, exact request/response traces,
raw video, before/after native trees, preferences, and executable hash are kept
under `artifacts/jev-settings/`. No build ran during timed device trials.

## Failures retained

- Donpa `20260921-175843`: stopped in 0.432 s on the old reader write failure.
- Donpa `20260921-180016`: 44.339 s, budget exhausted, no win/loss, repeated
  ineffective digs. Two opening reveals followed a reset; neither was subsequent
  clearing. The evaluator previously reported their difference (11 points) as
  progress. It now segments on observed decreases and correctly reports **zero**.
  The original result is retained as `result-before-metric-fix.json`. Unobserved
  resets cannot be inferred reliably by this evaluator.
- Safari `20260921-180116`: 7.977 s, wrong suggestion action and native hit-read
  failure; no completed search sequence.
- Safari `20260921-180339`: 34.714 s, searched, opened swift.org, and returned.
  It then selected Wikipedia although Apple Developer was second in the
  independent ranking. No completion claim; the auditor also encountered an
  incomplete tree. This remains a failed full sequence.

## Validation

34 focused Swift tests, four Donpa evaluator tests, and six Safari evaluator
tests passed. Debug and signed release builds completed; release signature
verification passed. Both video phases were visually checked against their
native switch outcomes. The full leaking BundleOps suite was not run.
