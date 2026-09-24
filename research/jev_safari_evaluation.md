# Cross-app Jev evaluation — 2026-09-20

## Conclusion

Safari is a useful second test: search → first organic result → Back → second
organic result. It exercises text, autocomplete, ranked links, covered controls,
document transitions and ordered completion. The controller contains no Safari
navigation plan or Google result parser. The Google-specific verifier lives in
`tests/SafariSearch/record.py`, outside Jev's inputs.

The first implementation slice from [the reference review](jev_reference_design.md)
is implemented, but **the live task is not reliably passing**. One Wikipedia
sequence physically completed in 17.440 s; Jev reported failure at 19.698 s.
Repeats failed in different ways. This is not evidence of a general 1–2 s
controller, nor an old/new success-rate comparison: code and live browser state
changed between exploratory runs.

## Physically completed sequence, incorrect completion judgment

Artifact: `artifacts/jev-safari/20260920-164850/`.
Video: `jev-safari-timed.mp4`, original speed with a timestamp panel and an
explicit false-failure label. Setup was 2.422 s, excluded from goal time.

| Independently observed milestone | Seconds from goal |
|---|---:|
| Google results for `wikipedia` | 4.052 |
| First result: Wikipedia, wikipedia.org | 10.682 |
| Back to the original Google results | 13.122 |
| Second result: Wikipedia, the free encyclopedia, en.wikipedia.org | 17.440 |
| Controller stops without reporting goal met | 19.698 |

The raw native AX trees show result order, each destination's document title,
host and body. The second page is also visible in the recording. These are
separate from Jev's completion claim. Browser History.db lagged and had not yet
recorded every visit at audit time; it is supplementary evidence only.

This run predates the final history wording, picker cycle guard and bounded
readiness backoff. Its video demonstrates that run, not a passing final build.
Early artifacts did not record binary hashes; newer recorder runs do.

## Exploratory Safari runs

All artifact IDs below are under `artifacts/jev-safari/`. Fixture startup is
excluded; no app-specific outcome facts were sent to the controller. No OCR.
The audit uses another native reader concurrently, so it can add device load.

| Artifact | Query | Agent seconds | Result / failure |
|---|---|---:|---|
| 20260920-163350 | swift programming language | 13.445 | First result opened; toolbar AXPress rejected. Early database-only oracle could not verify live state. |
| 20260920-163648 | swift programming language | 13.870 | Search suggestions covered the selected link; stale target refused. |
| 20260920-164054 | swift programming language | 2.778 | Risk gate declined ordinary address-bar navigation. |
| 20260920-164231 | swift programming language | 18.715 | Old document content during navigation, repeated input/scrolling. |
| 20260920-164502 | swift programming language | 21.498 | Scrolled past intended ranks; opened wrong results. |
| 20260920-164705 | swift programming language | 12.386 | Opened first result, stopped before the full sequence. |
| 20260920-164850 | wikipedia | 19.698 | Sequence verified at 17.440 s; controller reported failure. |
| 20260920-165113 | wikipedia | 28.243 | Autocomplete opened Wikipedia directly; no Google ranking observed. Repeated Back/search. |
| 20260920-165738 | swift programming language | 13.378 | First result and return verified; extra Back left search, then input read failed. |
| 20260920-170239 | swift programming language | 32.144 | Final build: first result and return verified; reopened first result repeatedly instead of second. Correctly reported failure. |

An additional about:blank fixture attempt failed before dispatching a goal.
The harness now initializes with example.com. Explorations before the table
also exposed nested duplicate links and scroll overshoot. This table is not a
controlled ablation or a success-rate estimate for one fixed implementation.

## What changed, and what remains uncertain

- `JevActionSpace` offers operation-specific bindings, including field/literal
  and wheel/value pairs. Only the action and consumed target head are validated
  and used. Choice count is bounded; unsupported option enumeration remains open.
- Native context preserves parent labels/URLs for ambiguous links. Parent link
  wrappers with leaf links are omitted. Live hit tests reject covered targets.
  App/document and target semantics are rechecked before input. These reads are
  not atomic; stable node handles and modal identity are still missing.
- Toolbar controls use the native physical-press translator because their
  AXPress rejected valid taps. Other supported controls retain native AXPress.
  Uncertain input is not automatically replayed through another input method.
- Text replacement binds an observed field and verifies the resulting value.
  Autocomplete can still interpret Go as opening a suggestion. The observations
  need to expose enough intent to distinguish search submission from navigation.
- A page address can change while the old document body is still visible. The
  verifier rejects this as a completed visit. The controller carries document
  titles and observed changes in history, but readiness remains unreliable.
- The completion question now considers observed historical outcomes as well
  as the current screen. Attempts alone are explicitly insufficient. This is a
  general multi-step fix, not a measured solution to the Safari false failure.
- All-unreachable observations trigger fresh traversal and bounded backoff
  (50/100/200/400 ms, only after a failed observation). Three earlier 30 ms
  retries failed after sheet dismissal. This is transition handling, not a
  fixed pause after every action. A persistent failure still stops.
- Numeric/AM-PM picker selection is still a limited adapter. Binding a value
  to a wheel does not establish that the wheel supports every numeric literal.
  A repeat of an observed value now stops the bounded adjustment early rather
  than continuing to the 64-action cap. History includes the original value
  and context so same-label wheels are distinguishable.

## Alarm regressions without privileged completion facts

The CLI no longer injects demo-alarm preferences. The unchanged demo app's
saved UUIDs are read only by the independent recording harness. Earlier fast
alarm measurements used those facts inside the controller and are not directly
comparable. No Apple Clock app or notification scheduling is demonstrated.

| Artifact under jev-alarm | Goal | Seconds | Independent outcome | Controller outcome |
|---|---|---:|---|---|
| 20260920-165521 | 12 PM | 2.756 | New 12:00 record, existing records preserved | Observation lost controls after Save |
| 20260920-165542 | 6 AM | 2.375 | New 06:00 record, existing records preserved | Same observation failure |
| 20260920-165707 | 12 PM | 7.838 | No new record | Wrong wheel/value sequence; stopped at adjustment cap |
| 20260920-165936 | 6 PM | 5.045 | New 18:00 record, existing records preserved | Observation lost controls after Save |

The 6 PM run resumed an editor left by the preceding failure; a focused test
build also ran concurrently. Its timing is not a clean latency comparison.
These failures motivated the final bounded readiness backoff and cycle guard.
Saved outcomes and controller claims must continue to be reported separately.

After the final backoff/history changes, all three saved times were correct and
existing records were preserved. The observation failure did not recur in these
three runs; only the 6 AM run also received a correct completion claim:

| Final artifact | Goal | Seconds | Controller outcome |
|---|---|---:|---|
| 20260920-170140 | 6 AM | 3.522 | Correct success, independently verified |
| 20260920-170147 | 12 PM | 3.070 | False failure; new 12:00 record verified |
| 20260920-170206 | 6 PM | 3.306 | False failure; new 18:00 record verified |

Setup was 1.893 s for the first session and 2.020 s for the second. Independent
post-run audits took 0.540, 0.636 and 0.476 s respectively, reported separately.
No concurrent build ran during these final three trials. This small sample
supports the specific transition fix, not a general reliability claim.

## Next evidence to collect

Focused verification: 20 Swift Jev tests, 8 Python command tests and 4 offline
Safari-oracle tests passed. These check binding/validation, native decoding,
covered targets and the ordered independent verdict; they do not establish
live Safari reliability. The full BundleOps suite was not rerun because of its
documented temporary-disk leak.
`make build` also completed, and the release binary's code signature verified.

Prioritize coherent observations through navigation/sheet transitions and
general ordered progress/completion evidence. Do not add website tap scripts,
alarm-specific policy branches or hidden app-storage assistance. Then compare
fixed versions on repeat runs with the same starting state, recording model,
readiness, native input and audit times separately. A small local web fixture
with stable ranks, delayed navigation, duplicate labels and overlays would
complement live Google by making these failures reproducible across builds.
