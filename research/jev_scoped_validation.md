# Scoped validation and Calendar — 2026-09-22

The native-reference prototype roughly halved verified text-entry time in two
paired Contacts trials, but improved total completion by only about 6%. Settings
was slower in the subsequent comparison. **The prototype remains off by
default**, enabled only with `JEV_SCOPED_VALIDATION=1`. Calendar is now an
independently audited evaluation; both baseline and prototype failed its first
create-and-reschedule task. No cross-app speedup or Calendar success is claimed.

## What was built

The opt-in simulator path captures actual native element references serially
during observation. It retains each target's ancestry, native semantic values
and a bounded context description for that observation. Parent reads shared by
controls are reused within that capture only. There is no parallel AX traversal.

When Jev selects an eligible control, validation reads the current foreground
application root, then the selected native reference and its ancestors. It
compares identities and semantics, resolves the live frame and checks a
display-wide hit at its centre. The mutation helper checks the reference again
and consumes it before input. A new capture invalidates the entire old set.

The model still receives a full fresh semantic observation. Completion retains
its full fresh read. Web documents, missing remote content, duplicate semantic
identities and mismatched capture context use the existing full validation path.
The application-root read deliberately requests depth zero; its expected
truncation is accepted only by that explicitly partial read, never by an ordinary
observation. No OCR, app-specific controller sequence, speculative action queue
or Calendar database facts were added to the agent.

This is about 165 lines of native experimental helper plus Swift integration.
Its remaining proof obligations include moving and recycled controls,
cross-process overlays, identity reuse and broader modal/context equivalence.
The existing full-validation moving-target tests do not certify those cases for
this new private-API implementation. Keeping the experiment optional is
intentional, not a claim that it is ready for arbitrary apps.

## Measured outcomes

Alternating runs used the same ready Contacts list, Add → three fields → Done,
the same recorder and independent SQLite checks. Names and company literals
varied. All four created a new ID and preserved existing records. No builds or
video rendering ran during the task measurements.

| Path / artifact | Independently saved | Completion |
|---|---:|---:|
| Baseline / `194145`, Evan Brook | 4.379 s | 6.763 s |
| Prototype / `194958`, Maya Stone | 4.489 s | 6.693 s |
| Baseline / `195046`, Nolan Reed | 4.934 s | 7.558 s |
| Prototype / `195122`, Tessa Vale | 4.253 s | 6.780 s |

Median verified field-entry cost (six fields each): **266.85 → 125.85 ms**.
Median saved time: **4.656 → 4.371 s**. Median completion: **7.161 → 6.737 s**.
The second prototype needed an additional completion judgment; both versions
still spent substantial time observing sheet dismissal. Two runs per version
are a small sample, not latency percentiles or proof of general improvement.

[Machine-readable paired measurements](artifacts/jev-native-validation/comparison-20260922/contacts.json).
[Original-speed prototype Contacts video](artifacts/jev-contacts/20260922-195122/jev-contacts-timed.mp4).

Settings, from the already-open Display & Text Size pane:

| Path / artifact | Both on | Both off |
|---|---:|---:|
| Initial prototype / `194819` | 6.039 s | 2.387 s |
| Baseline / `195503` | 1.861 s | 2.481 s |
| Final prototype / `195615` | 2.737 s | 3.858 s |

Every final switch value and both saved accessibility preferences agreed; all
settings were restored. The initial prototype had a 2.260 s native tree read and
1.549 s hit/capture phase. The final prototype's off run included a 1.383 s Jev
call, and its on/off runs spent about 1.4 s settling after the second action.
These stalls cannot all be attributed to the prototype, but **the recorded
Settings results do not justify promoting it**.

The earlier read-only feasibility probe measured a settled Contacts tree at
106.6 ms median, all selected native ancestry captures at 31.9 ms, and one
validation at 2.7 ms. Settings measured 33.8 ms full read versus 3.1 ms selected
validation. These exclude production foreground checks and broader context
reads; do not describe them as full controller costs or whole-task speedups.

## New Calendar evaluation

The single goal creates an event on September 23, 2026 from 9:30–10:15 AM, saves
it, reopens it and reschedules it to 2:00–2:45 PM. An independent read-only SQLite
audit requires both saves in order with the same new ID, exactly one new event,
the correct final time, and preservation of the pre-existing audited core fields.
It rejects an event created directly at the final time, duplicate creation and
editing an old event. The controller never sees these storage facts.

| Path / artifact | Outcome |
|---|---|
| Prototype / `195152` | Saved ID 131 at 9:30–10:30 AM; search reported indexing in progress; stopped after an unacknowledged scroll at 14.565 s |
| Baseline / `195311` | Saved ID 132 at 9:30–10:30 AM; repeated search/navigation, then started another unsaved draft; exhausted 35 steps at 31.389 s |

Both preserved the pre-existing audited event fields. Both failed the required
initial duration and the reschedule. Neither claimed completion. The failed
saved events remain as evidence; only the baseline's subsequent unsaved duplicate
draft was discarded. The changed titles and nondeterministic paths prevent a
speed comparison between these failed runs.

[Calendar video, explicitly marked failed](artifacts/jev-calendar/20260922-195152/jev-calendar-timed.mp4).
[Calendar recorder and oracle](../tests/Calendar/README.md).

The oracle's first implementation incorrectly assumed an EventKit-style
`entity_type=0`; the actual local database uses **2**. This was corrected against
the saved event's native displayed time and stored record before the baseline
run. The prototype's expected-duration milestone remains absent with the
corrected type because it really saved 10:30 AM rather than 10:15 AM. The UTC
timestamps independently match 9:30–10:30 AM in America/Los_Angeles.

## Validation and limitations

- 44 focused Swift tests and 20 Python tests passed. New parameterized checks
  reject changed app/value/context/label, duplicates and incomplete/web evidence
  when assigning native references.
- Six live Settings checks passed: unchanged acceptance, malformed reference,
  old generation, changed value, guarded input and rejection of reference reuse.
  An independent native reader verified the actual value and restoration.
- A live Calendar test retained the Title field, opened the discard dialog and
  verified rejection while covered; it was also rejected after editor dismissal.
  Evidence is retained in `artifacts/jev-native-validation/comparison-20260922/`.
- A Contacts baseline startup initially failed because its detail screen exceeded
  the native reader's tree budget. That failed setup (`194013`) is not a timing
  baseline. A bounded fixture read identified Back; the measured runs started
  from the verified list. The controller budget was not weakened.
- Debug/release builds and strict release signature verification passed. No
  firmware patches or BundleOps disk-image tests were run.

Paired prototype controller SHA-256:
`6fb734bc6a7087625b6041ef3fe36343c0c981c67856d43b8b52c1412785772a`.
Final controller after extracting the tested eligibility predicate:
`2bde198378f7fec445aa1607798af6f303f684cc0a0fe09e5ad966bdb33f08fb`.
Final guest helper:
`50bd57bfc03aedfc58ec1864b8fbe5ad02a67d330befe30ca0da54f3fe06f68e`.

Next work: reduce reference-capture overhead and establish live moving/recycled
target equivalence before promotion. Separately, ablate general form-consistency
and intermediate-goal judgment on the frozen Calendar failure. Calendar's
indexing message also needs a correct navigation/recovery decision; faster input
does not solve that. Preserve failed trials rather than adding a Calendar route
or accepting the wrong duration.
