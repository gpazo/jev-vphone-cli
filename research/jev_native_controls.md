# Native control improvements — 2026-09-22

The general simulator controller now handles blank native form fields, validates
only candidates for a selected control before input, and scrolls through iOS
accessibility page actions. Apple's unmodified Contacts is the new end-to-end
evaluation. No contact names, field names, app navigation, website ranking rules,
or outcome oracles were added to the controller.

## Verified new app

Final recording: [Owen Park](artifacts/jev-contacts/20260922-093945/jev-contacts-timed.mp4).
Starting on another contact's detail page, Jev chose Contacts → Add → fill first
name → fill last name → fill company → Done. The independent audit saw a new
record at **7.181 s**, and the controller reported completion at **9.374 s**.
Existing records' first/last/company values were preserved. Seven Jev calls had
a **206 ms median** and totaled 1.773 s. Input/checks totaled 3.649 s, and
observation/settling 3.691 s. Startup was 1.542 s, excluded from the goal timer.
The video is continuous, original speed, with a two-second final hold.

The preceding Nora Ellis run also created a new record from an existing detail
page: saved at 7.053 s, report at 10.265 s. These demonstrate general form control,
not a proven whole-task latency improvement between those two samples. The
final keyboard filtering reduced redundant choices but did not make the actual
save earlier in that pair.

Earlier results are retained:

| Artifact | Result |
|---|---|
| `jev-contacts/20260922-092601` | Failed: blank Last name/Company fields were omitted; nothing saved |
| `jev-contacts/20260922-093016` | Mira Stone created from list; saved 4.967 s, report 9.623 s |
| `jev-contacts/20260922-093302` | Failed: edited record 7 into Alex River instead of creating another record |
| `jev-contacts/20260922-093644` | Nora Ellis created as record 8; prior records preserved |
| `jev-contacts/20260922-093945` | Owen Park created as record 9; prior records preserved |

The first recorder checked only IDs already matching the requested name. That
incorrectly certified the Alex rename as creation. Its original result is
preserved as `result-before-new-id-fix.json`; the corrected result rejects it.
The recorder now snapshots **all** existing IDs and checks preservation, with
regressions for rename, new record, wrong values, and collateral modification.
Mira's original creation remains evidence of its historical state; the failed
Alex run subsequently renamed that same demo record.

## General changes

- **Native page scrolling.** Runtime-resolved AXP scroll-up/down-by-page actions
  use the existing persistent guest translator. A fresh hit supplies the anchor;
  when the centre lies between controls, a reachable content control supplies it.
  Keyboard controls are excluded from that fallback. The guest asserts the
  anchor again. Failed or unacknowledged input is never replayed as a HID gesture.
  Explicit drag operations retain the existing physical gesture path.
- **Selected-target validation.** The current full native tree still supplies
  app, document, context, value and moved coordinates, but only matching candidates
  need hit tests before pressing one control or verifying a fill. Every candidate
  remains checked in full observations sent to Jev. App/document/value changes and
  ambiguous identities are rejected; moved unique controls use fresh coordinates.
- **Native placeholders.** Blank fields can have a placeholder and no label.
  The adapter now reads the native placeholder attribute, preserves it as field
  identity, and asserts it inside the guest when filling or pressing. Search
  fields and text areas also retain their native editable roles. Values are not
  guessed to be placeholders.
- **Redundant keyboard choices.** When an editable native field offers complete
  literal replacement, individual character keys are omitted. Submit/editing keys
  remain; custom keypads without an editable AX field retain their keys. This
  reduces hit tests and choices without teaching a task-specific sequence.
- **Large native trees.** A truncated default 5,000-node describe gets one
  read-only retry at 20,000 nodes. Partial trees are never accepted. The host's
  existing payload limit remains; mutations are never retried by this mechanism.
- **Create versus edit.** One generic instruction distinguishes creating a new
  item from modifying an existing one. On the frozen bad Contacts decision,
  original instructions chose Edit in 3/3 trials; the added instruction chose
  Contacts (Back) in 3/3. Two subsequent live tasks created new records correctly.
  Replay artifact: `artifacts/jev-native-scroll/create-rule-replay.json`. Replay
  appended the instruction to all questions; production puts it in the shared
  operation/target rules. The live trials validate that placement.

## Scrolling measurement

The initial controlled comparison is in
`artifacts/jev-native-scroll/20260922-092417/result.json`. Six native and six old
HID trials were interleaved on a fixed local web page; all changed the layout and
settled. Native acknowledgment median: **14.8 ms**, old HID: **2.326 s**.
Time to changed, stable accessibility layout: **0.164 s versus 4.092 s** (about
25×). Four native Settings trials also passed, median **0.311 s** including
layout observation. A stale label was rejected without moving the layout.

This compares scroll intent, not identical travel: native input requests one
page; the old drag moves 40% of screen height and includes inertia. The first
pair traveled 714 versus 532 points. Stable native frames do not prove all visual
animation has ended. No model calls occur in this mechanics benchmark. Early
harness failures (using `booted` as an AXe UDID and an unsupported Settings deep
link) were corrected; those attempts are not measurements of successful input.

The final helper build repeated this benchmark in
`artifacts/jev-native-scroll/20260922-094339/result.json`: all 16 motions and the
stale-anchor rejection passed. Median time to changed, stable layout was
**0.181 s native versus 4.303 s HID** (about **24×**); command acknowledgment was
19.2 ms versus 2.210 s. Native Settings median was 0.300 s. No builds or video
renders ran during either measured comparison.

## Browser limitations retained

The Safari workflow still does not reliably meet the original goal, and no new
end-to-end browser speedup is claimed. All trials remain under `jev-safari/`:

- `20260922-091304`: existing controller baseline failed after 79.211 s.
- `20260922-091502`: native-scroll version visited the destinations but continued
  navigating, then stopped without success at 42.688 s.
- `20260922-091818`: reached the evaluated final destination but reported failure
  at 40.222 s. Search order also varied during loading; the evaluator's initial
  ranking capture remains a limitation.
- `20260922-092008`: SQLite documentation navigation hit the reader's node cap.
- `20260922-093436`: larger-tree version visited SQLite then Python documentation,
  but the audit subsequently lost the document body at the endpoint; its final
  state check rejects the run despite the model's completion claim at 33.546 s.

The independent browser audit accepts a substantial ellipsized search-heading
prefix only with matching host and loaded body. It continues to require the
final page, order, and no later input. It was not weakened to pass these runs.

## Validation

39 focused Swift tests passed, including moved/changed/ambiguous selected targets,
blank fields across native editable roles, placeholder mismatches and keyboard
capability filtering. Eight Safari, four Donpa and three Contacts oracle tests
passed. Debug and signed release builds succeeded; strict signature verification
passed. The displayed video was rendered and visually checked against the saved
record and native final state. No firmware patches or full BundleOps suite.
