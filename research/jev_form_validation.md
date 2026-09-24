# Jev form validation — 2026-09-22

## Outcome

There is now an **opt-in `--validate-forms` experiment**, not a claim that Jev can
reliably certify arbitrary forms. It binds a typed readiness judgment to the
selected tap and checks the complete form again before a permitted commit.
No app schema, Save-label dictionary, generated text, coordinates from Jev,
OCR, or application-storage facts enter this controller.

The verified live Contacts run created **Iris Vale / Jev form validation** as a
new record (ID 26), preserved all 25 pre-existing contacts, observed the save at
**5.966 s**, and reported completion at **9.125 s**. Its nine Jev decisions had
a **249.2 ms median**, 2.282 s total. Startup (1.366 s) is separate. The scoped
native-reference optimization was disabled. This is one successful run, not a
speed improvement or reliability estimate.

- [Original-speed video](artifacts/jev-contacts/20260922-205133/raw.mov)
- [Independent result](artifacts/jev-contacts/20260922-205133/result.json)
- [Recorded comparisons](artifacts/jev-form-validation/summary.json)

The first attempted Save in that run was deferred by whole-form freshness.
The next decision gave the same Save a readiness probability of 0.96 and saved
the correct record. Completion required two additional rejudgments as the
observed detail screen changed. Video duration is 9.215 s; its final frame was
inspected and shows the correct name and company. No footage was accelerated.

## What changed

The normal action/target instructions now explicitly compare the current
stage's requested values before saving, reveal unavailable correction controls,
and reopen the identified item before editing it. Each target head receives
these rules independently because parallel questions cannot see each other's
answers. This is a selection improvement, **not a hard guarantee against an
incorrect save**.

The Simulator retains up to 48 total nearby/covered controls as explicitly
non-actionable, read-only context. Previously a hit-test rejection erased the
native text entirely, hiding an event clipped behind the Calendar header.
Covered controls never enter the action vocabulary. Their values/context now
participate in freshness signatures. The bounded observed-action journal also
retains field context, so an observed time keeps its row association.

With `--validate-forms`:

1. Ask speculative `ready / mismatch / insufficient_evidence / not_applicable`
   questions for up to 24 tap candidates in the normal request. Each question
   names its complete candidate independently. A selected candidate outside
   that batch incurs one follow-up request; dense-page latency is not yet measured.
2. Consume only the selected tap's answer. Require a valid distribution and a
   `ready` or `not_applicable` majority (>0.5, owned by `Policy.formReadiness`).
   A contradictory high `done` score cannot override a rejected selected tap.
3. Feed a refusal back as `inputRejection`, without recording a successful
   action or waiting for a transition that never happened. Existing stuck and
   step limits bound repeated refusal.
4. For a `ready` commit, require complete unchanged **whole-form** evidence,
   including other fields, then retain the native execution-time target checks.
   Final task completion still has its independent fresh-observation check.

The model still decides whether the candidate is a commit. An erroneous
`not_applicable` classification can bypass the whole-form branch. Readiness is
another model judgment, not independent proof. The experiment therefore stays
off by default. It has no app-specific success oracle inside the controller.

## Frozen-state experiments

Requests and responses live under `artifacts/jev-form-validation/`. Each probe
used three repeats, interleaved in seeded random order. These are exploratory
probes, with additional variants chosen after seeing results; they are not a
held-out benchmark. Python HTTP wall time includes connection overhead and is
not the same as a warm controller model call.

| Probe | Observation |
|---|---|
| Original Calendar failure, original instructions | 3/3 chose Done with Ends 10:30 instead of requested 10:15 |
| Append broad validation instructions | 3/3 still chose Done |
| Focused repair/reveal instructions | 2/3 avoided Done; 1/3 still chose it |
| Typed readiness on the original failure | 3/3 returned mismatch; none could pass the proposed gate |
| Corrected Calendar counterfactual, full old history | 3/3 returned insufficient evidence; incorrect refusal despite the corrected observed Ends context |
| Actual live correct Calendar form | 3/3 ready, probabilities 0.59–0.71 |
| Calendar with end evidence and history removed | Original and focused selection still chose Done 3/3; readiness returned insufficient evidence 3/3 |
| Contacts, actual fully observed correct form | Readiness ready 3/3, probabilities 0.95–0.96 |
| Same Contacts form, requested company changed | Readiness mismatch 3/3, probabilities 0.96–0.99; ordinary selection also chose to edit |
| Earlier Contacts form with fields no longer observed after typing | Readiness incorrectly treated the attempted last edit as sufficient evidence: ready 3/3; this is a known unsupported approval |
| Calendar reopen mistake with nearby named event | Original selected an unrelated 2 PM slot 3/3; identity/reveal instruction selected scroll up 3/3 |

Further binary/context-wording/history-ablation probes did not resolve the
Calendar false-refusal problem. Asking all eight candidate readiness heads
batched on the original bad screen still rejected Save; median HTTP wall time
was 406 ms versus 378 ms for the original three replays. This small sample
does not establish marginal overhead. Removing prior-execution counts from a
later picker failure did not produce correct repairs; that change was not adopted.

Counterfactual fixture manifests identify changed fields. In particular, the
Contacts mismatch probe changes the requested company in the goal while leaving
the original target vocabulary intact; it tests rejection, not the ability to
enter the substituted company. The Calendar unknown probe removes end evidence
and history; it is not a live outcome.

## Live Calendar and failed attempts

The new selection instructions independently saved the correct initial
**9:30–10:15 AM** event three times:

| Artifact | Initial save | Later result |
|---|---:|---|
| `jev-calendar/20260922-203226` | ID 133 at 12.174 s | Failed to reopen; stopped at 24.178 s |
| `jev-calendar/20260922-203516` | ID 134 at 14.001 s | Selected unrelated 2 PM slot; stopped at 23.351 s |
| `jev-calendar/20260922-204111` | ID 135 at 13.236 s | Reopened the same event and entered its editor; then set the wrong minute and stalled at 35.116 s |

These were selection-only runs, before the opt-in readiness gate was added.
They preserve all prior audited event fields but **do not pass the full
create-and-reschedule task**. Another run (`203806`) stopped on an incoherent
picker answer before saving; the malformed-response guard was retained.
Unsaved test drafts/edits were discarded between evaluations. Saved failed
records remain available for inspection.

The final **guarded** run, [`210131`](artifacts/jev-calendar/20260922-210131/result.json),
started on the verified day view and saved the correct initial duration as ID 136
at **12.369 s**. Its first Save was deferred by whole-form freshness, and the next
one was allowed. It then selected an unrelated time slot and failed during
scrolling at **15.639 s**. All prior audited events were preserved; the complete
reschedule test still failed. No success was claimed. The controller SHA-256 was
`bec8235a762bc824631c5c45c742f4c4a07c92a42f76e354c080adf75a35a63a`.

Contacts also had a setup failure from the existing 20,000-node reader limit,
a run stopped by the existing uncertain-action confirmation gate (`204923`),
and a run starting on the draft-discard popup (`205038`). No such refusal was
bypassed or counted as success. Several Calendar validation attempts started
on the earlier detail/popup instead of the required day view and stopped at
the same existing confirmation gate (`205330`, `205450`, `205923`). A Calendar
restart briefly returned a native accessibility timeout. These failures remain
in the artifacts; they are not clean paired latency trials. Some exploratory
runs overlapped local compilation, so no causal whole-task speed comparison is made.

The Calendar oracle now reports `exactly_one_new_event` independently from
whether rescheduling passed. Earlier result JSONs had that field incorrectly
false on a single correct initial creation with no reschedule. The acceptance
condition still requires both saved stages on the same new ID and preservation
of pre-existing audited fields; it was not weakened.

## Verification and remaining work

Focused tests cover wrong/missing/uncertain readiness, contradictory completion,
repair feedback without fictitious execution, changed other-field values,
incomplete reads, successful stable-save permission, covered-target exclusion,
and freshness of read-only context. Calendar/Contacts storage evaluators remain
separate from the controller. No firmware patches were changed.

Final verification: **50 Swift tests and 20 Python tests passed**. `make build`
completed and the release binary passed strict code-signature verification.
The final debug binary was used for the last guarded Calendar trial. The Contacts
video predates only the additional protection against a contradictory `done`
answer bypassing rejection; that case is covered by the final tests. No live
speedup is inferred from those tests. The repository's pre-existing uncommitted
work was preserved; this work was not committed or published.

Before making the experiment the default, measure false acceptance/refusal on
held-out forms, prove that recovery finishes the task, and measure dense-page
batch fallback overhead. Calendar's current-stage picker selection and the
global uncertain-action gate remain obstacles. The 1–2 second whole-task target
is still unmet.
