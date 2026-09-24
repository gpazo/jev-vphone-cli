# Verified input and browser follow-up — 2026-09-22

The controller now verifies text replacement on the same native element it
wrote, preserves the platform's Back-button meaning, and avoids fetching large
documents twice. Jev still makes one batched judgment per step. No app-specific
plan, generated coordinates, OCR, new state-memory layer, or completion shortcut
was added.

## Recorded outcomes

- [Contacts, final build](artifacts/jev-contacts/20260922-164637/jev-contacts-timed.mp4):
  starting on an existing contact, Back → scroll → Add → three fields → Done.
  A new Iris Cole record was independently observed at **6.027 s**; completion
  was reported at **7.636 s**. All 17 existing records retained their
  first/last/company values. Nine Jev calls had a **232 ms median**. The extra
  scroll remains visible in the recording; this was not an optimal action count.
- [Safari, final build](artifacts/jev-safari/20260922-164531/jev-safari-timed.mp4):
  search Google for `sqlite documentation`, open SQLite Documentation, Back,
  open the second organic result (Python's sqlite3 documentation), stop.
  Independent milestones: **2.408 / 5.808 / 6.864 / 11.702 s**. The controller
  reported completion at **23.222 s**. No input started after the second page
  loaded; the final page, sequence, and model completion all passed. Ten Jev
  calls had a **254 ms median**. The preceding run also passed, at 26.090 s.

Both videos are continuous, original speed, with a two-second final hold.
The annotators fill sparse simulator frames before trimming to goal time, so
a seek cannot discard the initial held frame. Final output timestamps start at
zero; frame alignment is quantized to 1/30 second. Ready
session startup and initial app launch are excluded; navigation and verification
after the goal are included. The independent evaluators do not feed Jev.
The Safari result-order oracle's existing limitation remains: it freezes the
first available ranking while Google may still be loading.

## Matched Contacts comparison

Four alternating runs started from the Contacts list, each taking Add → three
field replacements → Done. Names varied; the task structure and evaluator did
not. There were no concurrent builds or video renders. Both versions used the
same iOS 26.5 device and guest helper; the baseline controller used the previous
text-entry path. Exact executable hashes and measurements are in
[comparison.json](artifacts/jev-fast-observation/comparison.json).

| Controller / artifact suffix | Saved | Completion |
|---|---:|---:|
| Previous / `163636` | 5.263 s | 7.465 s |
| Revised / `164005` | 4.408 s | 6.545 s |
| Previous / `164054` | 4.649 s | 7.096 s |
| Revised / `164118` | 4.460 s | 6.641 s |

All four independently created new records and preserved existing records.
Verified field replacement, including prevalidation, fell from **481.6 to
240.1 ms median** over six fills per version. Completion medians were **7.281
versus 6.593 s** (~9% lower), and save medians **4.956 versus 4.434 s** (~11%
lower). This small sample supports a measured input improvement, not a claim of
twice-as-fast whole tasks or universal app reliability. The subsequent node-budget
change affects documents above 5,000 nodes; these Contacts trials preceded it.

## Changes and evidence

1. **Write and read back the same field.** After full fresh candidate validation,
   the guest hit-tests again, asserts label/placeholder and the prior value,
   verifies a native editable role, resolves the native value attribute at
   runtime, writes once, and reads that same native element's value. Keyboard
   reflow cannot move the verification onto another field. Missing confirmation
   stops the controller; writes are never replayed. This removes the redundant
   post-write whole-screen read. The next model observation is still fresh.
2. **Smaller observation work.** Hit tests fetch only the four attributes used
   to check identity; normalized dictionaries go directly into the decoder
   instead of being serialized to JSON and parsed again.
3. **Preserve native Back meaning.** `UIAccessibilityBackButtonElement` supplies
   `Back navigation` context while retaining its actual destination label.
   An ordinary button with the same label gets no such context. On a frozen
   failing detail screen, the original projection scrolled in 3/3 replays;
   the added native context selected Back in 3/3. See
   [back-context-replay.json](artifacts/jev-fast-observation/back-context-replay.json).
4. **Describe complete text entry explicitly.** The operation now says that a
   preparatory focus tap is unnecessary. On the frozen form, original wording
   chose tap once and direct typing twice; revised wording chose direct typing
   in all three trials. This is a limited replay result. Two subsequent list
   trials used exactly five inputs. See
   [focus-replay.json](artifacts/jev-fast-observation/focus-replay.json).
5. **One bounded large-page fetch.** The prior 5,000-node request returned a
   truncated serialization, then repeated the whole native snapshot with a
   20,000-node budget. The controller now requests its existing 20,000-node
   upper budget immediately. Truncated trees and payloads above 16 MB remain
   rejected. On the loaded Python page, the discarded first read cost **2.657 s**;
   complete reads cost **1.955 / 1.947 s**. Both used two native round trips.
   [Raw read measurements](artifacts/jev-fast-observation/large-page-reads.json).
   The [pinned idb implementation](https://github.com/facebook/idb/blob/v1.6.1/SimulatorFrameworkBridge/AccessibilityRuntime.m)
   obtains the native snapshot before applying the wire node budget.

## Experiments and failures retained

- The initially booted device was iOS 18.5. Startup failed once; the subsequent
  Add input timed out without saving. The tests then switched to the existing
  iOS 26.5 device. Those failures are not latency baselines.
- Initial iOS 26.5 baseline `162456` saved at 7.646 s and reported at 12.587 s;
  cold conditions made this unsuitable for attributing the later gain to code.
- Baseline `162555` and an intermediate build `162843` selected an unnecessary
  scroll on a detail page and stopped. The Back-context change followed these.
- A per-node-read preference for native screens was tried, then removed. It
  still returned transitional views and added an unproven mode heuristic.
  Intermediate `163045` passed at 11.723 s (including two unusually slow Jev
  calls); `163145` passed at 7.549 s. They are not the final implementation.
- Intermediate `163720` added three unnecessary focus taps and a scroll,
  finishing at 9.598 s. This prompted the complete-text-action wording change.
- A local HTML form test exposed inputs reported as generic accessibility
  elements (automation type 0). That coverage gap remains; it was not bypassed
  by treating arbitrary web text as editable.

## Validation and remaining limits

`tests/NativeText/check.py` verifies Safari's native address editor through an
independent AX connection. Unicode and ASCII replacements passed; wrong-label,
stale-value, and non-editable-control writes were rejected without changing the
field. [Five live checks](artifacts/jev-native-text/20260922-163603/result.json).
The first Unicode write took 1.948 s and the warm second write 74 ms: this test
establishes correctness, not a universal 74 ms input latency.

40 focused Swift tests and 15 Contacts/Safari/Donpa evaluator tests passed.
Debug and signed release builds, strict code-signature verification, Python
compilation, and whitespace checks were run. No firmware patches were changed.

The 1–2 s whole-task target remains unmet. Safari's large-page snapshots and
per-control hit tests dominate verification after navigation; Contacts still
rejudges completion when a sheet's accessibility tree changes during dismissal.
The independent browser audit also performs expensive native reads. No new
gameplay result is claimed.
