# Native picker options and inline context — 2026-09-23

## Outcome

The Calendar create → save → reopen → reschedule → save task completed for the
first time in these recorded evaluations. The independent SQLite audit observed
the **same new event ID 137** at both required intervals, and preserved every
pre-existing audited event. Jev received only accessibility state and its goal.

| Milestone | Seconds after goal submission |
|---|---:|
| Saved 9:30–10:15 AM | 9.539 |
| Saved the same event at 2:00–2:45 PM | 32.227 |
| Correctly reported completion | 34.305 |

[Result](artifacts/jev-calendar/20260923-074736/result.json) ·
[Original recording](artifacts/jev-calendar/20260923-074736/raw.mov).
The video's final frame was inspected and displays the correct final interval.
The unedited simulator clip is 33.010 seconds; its capture timeline does not
exactly match wall time. The table uses monotonic controller/audit measurements,
not video duration. Startup (1.083 seconds) is excluded.

This is **one full pass, not repeatable reliability or a speedup claim**. The
immediate repeat failed before saving, mixing the initial and later intervals.
The readiness gate rejected an incorrect commit; later the controller reached
the discard dialog and stopped at the existing human-decision gate. It did not
claim success or change any saved event. Its own unsaved draft was discarded
after recording. Both attempts had form validation enabled and scoped validation
disabled. No refusal thresholds were relaxed.

## General changes

1. Read `XC_kAXXCAttributeDatePickerPossibleValues` from the native snapshot.
   On this device the hour wheel reports 1–12, minutes report five-minute
   increments, and the period wheel reports AM/PM. These are **observed options**,
   not hardcoded ranges or a Calendar schema. The bridge sometimes serializes
   arrays as OpenStep property lists; parse the complete collection, bound it,
   and reject malformed/duplicate/oversized collections without accepting a prefix.
2. Filter literal goal/value bindings against those options. The failed frozen
   request had 17 picker choices, including the year on the hour wheel; only
   seven were supported. Options participate in target freshness and are checked
   again while adjusting. Controls without this metadata retain the existing
   limited numeric/AM-PM adapter. Arbitrary textual option selection is unfinished.
3. Do not offer a tap at a wheel's already-selected centre. Bounded selection
   and native increment/decrement remain available. Wheels still receive native
   hit checks before being exposed to the controller.
4. Preserve immediate native sibling-row text for an otherwise unnamed editor:
   `After row: Starts, …` or `After row: Ends, …`. This describes actual tree
   adjacency, **not asserted field ownership**. It never crosses an intervening
   node, overrides a named editor, or creates an action target. There are no
   app names, navigation sequences, time constants, or special goal rules here.

No OCR, generated values, new model instructions, additional judgment heads,
firmware patches, or app-storage observations were added to the controller.
The existing `--validate-forms` experiment remains off by default: a model
readiness judgment is not independent proof.

## All live Calendar trials this turn

| Artifact | Change | Result |
|---|---|---|
| `20260923-074545` | Native options + removal of wheel-centre tap | Failed after 35 decisions / 47.252 s; alternated minutes; no save |
| `20260923-074736` | Also retain adjacent row text | Full pass, 29 decisions / 34.305 s; wrong minute repaired before final save |
| `20260923-075017` | Same final source, new title | Failed after 33 decisions / 41.880 s; no save or false completion |

The initial attempt's readiness head also incorrectly approved a 9:15 start
once; the separate freshness check deferred that tap. Do not interpret the
absence of an incorrect saved record as proof of an accurate readiness model.

The signed release executable exited without output during setup in a separate
attempt (`20260923-074955`); no goal was submitted or video started. All live
controller results above used the debug Simulator build. The release build and
strict signature verification passed; that is not a verified release launch.

## Probes and latency

Artifacts and exact requests live under `artifacts/jev-picker-options/`.
Three frozen-request replays with live native option metadata removed the old
wheel tap, but did **not** choose the correct repair. Three more with adjacent
row context also did not consistently select the repair. This is exploratory
evidence, not a held-out benchmark or proof of a causal success-rate gain.

Direct text replacement on the compact native time label was tried only in an
unsaved fixture: the native readback did not change, and the input helper
correctly refused to call it successful. No direct-time-entry shortcut was added.

In the full pass, 29 Jev calls consumed 12.470 s (median 440.1 ms), input and
verification 13.750 s, and observation/settling 7.533 s. The record includes
unnecessary corrections; the 1–2 second whole-task target remains unmet.
The next measurable optimization is the repeated full-tree read within a single
bounded picker adjustment, but replacing it requires equivalent native target,
coverage, and value checks. That optimization is **not implemented here**.

Eight interleaved read-only Calendar day-view samples per mode measured median
snapshot reads of 58.9 ms without the extra native attribute and 57.1 ms with it.
This does not establish a speedup; it detected no added cost on that one screen.

## Cross-app check

[Contacts](artifacts/jev-contacts/20260923-075430/result.json) created **Nora Reed /
Jev native review**, new ID 27, preserving all 26 previous contacts. The save was
observed at 7.086 s and completion at 10.276 s, with form validation enabled.
This is a regression pass, not a latency improvement. Its initial existing
detail screen again exceeded the native reader's 20,000-node budget. Fixture
setup used a partial read only to locate and freshly press the native Back
button, then the timed controller started from a complete Contacts-list read.
The controller's completeness guard was not weakened. The final recorder read
and independent storage audit both succeeded without errors.

## Verification

53 focused Swift tests and 20 Python evaluator/command tests passed. Tests cover
invalid native collections, impossible values, no-op selections, option-sensitive
freshness, neighbour context boundaries, and the existing form/freshness gates.
`make build` and strict code-signature verification passed. No full leaking
BundleOpsTests suite was run. Existing unrelated uncommitted work was preserved.

Debug SHA-256: `843b62bc3f3b45e8e4b40bc9c7a68c87881fff5d917266386df449d7decbf4d4`.
Release SHA-256: `566d71c08095b7410c8b5353bafb9ec3b1c1af54ba3fb72f2f2de7e2a7e33663`.
