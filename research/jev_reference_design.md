# General phone control: reference design review

Reviewed 2026-09-20 against clean sibling checkouts:
`jev-ultrafast` at `452c1ad`, `jev-drone` at `cbeb53c`.
This source review informed the implementation below. Neither reference's
benchmarks was rerun. Device evidence is in [the Safari evaluation](jev_safari_evaluation.md).

## Product constraint

Control arbitrary apps efficiently through their exposed accessibility state.
Alarms are one evaluation case. No app-specific navigation plans, field values,
completion rules or storage assumptions belong in the general controller.
Jev consumes text and makes typed judgments; code owns observation, supported
actions, coordinates, execution and validation. No OCR fallback.

## What the browser project actually does

[`model.py`](../../jev-ultrafast/jev_ultrafast/model.py) builds operation-specific
target tables from observed actions. One request asks for an operation and
speculative targets. Only the chosen operation's target is consumed and fully
validated. A SELECT target identifies both the element and its observed option;
it is not the combination of independently predicted element and value.
This is more precise than replacing everything with one enormous flat choice.

[`snapshot.js`](../../jev-ultrafast/jev_ultrafast/snapshot.js) reads state
atomically, retains actual node references, and supplies roles, values, supported
operations, enabled/selected state and local context. Its dropdown candidates
exclude currently selected and disabled options.

[`browser.py`](../../jev-ultrafast/jev_ultrafast/browser.py) checks semantic
freshness and current geometry/occlusion. Click/select checks are scoped to the
target and relevant context; text and completion checks use broader state.
Post-input readiness is bounded and control-specific, rather than one delay for
every action. Those browser timing constants are not validated iOS constants.

[`agent.py`](../../jev-ultrafast/jev_ultrafast/agent.py) consumes a decision
before execution and records successful execution before observing the result.
An uncertain mutation is not replayed. Text generation is a separate, optional
model, invoked only for TYPE_TEXT; Jev itself never generates text. Reuse of a
pending generated value requires identical goal, field, page and history input.

## What transfers from the drone

[`tactics.py`](../../jev-drone/tactics.py) separates slower judgment from
continuous mechanics, fingerprints scenes, bounds requests, and tracks decision
age. [`run.py`](../../jev-drone/run.py) retains control-side vetoes and bounded
commitment to a maneuver. The state includes the observations and capabilities
needed to distinguish valid maneuvers.

For a phone, continue only the mechanics of an already selected bounded action,
such as reaching an observed control value. Ask again when it completes,
becomes invalid or requires a new choice. Do not translate continuous flight
setpoints into repeated taps, reuse consumed mutation decisions on unchanged
screens, or pipeline dependent actions speculatively. A UI decision must still
match the current goal, observation, relevant context and execution history.

## Gaps identified before migration (historical)

1. `JevQuestions` shares `tap_target` across taps, drags and picker selection.
   It offers drags whenever any tappable element exists. `picker_value` is
   predicted independently from its wheel. This allows unsupported combinations.
2. `JevDecider` validates the action distribution but copies the selected target
   and picker-value choices without equivalent distribution validation.
3. `JevElement` retains role/label/value/point, but not operation capabilities,
   parent/modal context or persistent native identity. The native normalization
   also drops attributes the decoder could otherwise use, such as enabled state.
   The noon traces include list content behind the editor. A flat text table
   can therefore obscure which controls belong to the active interaction.
4. Simulator picker mechanics parse numeric prefixes and AM/PM. This is a
   limited adapter, not a general selection implementation for arbitrary apps.
   Native option enumeration, ranges and node handles must be investigated;
   do not invent options or assume every wheel supports numeric stepping.
5. Text is currently limited to extracted goal literals and printable ASCII.
   The browser's explicit text-helper boundary is relevant when a task requires
   composing or transforming text. Adding it is a separate capability change.
6. The CLI automatically injects demo-alarm storage facts into Jev. Those facts
   help this demo but are privileged app-specific knowledge. Previous timings
   and outcomes include that assistance and must remain labeled accordingly.

## Proposed migration order

1. Introduce a code-owned action table with operation-specific target bindings.
   Where selecting a value is supported, bind control and valid option/value in
   one candidate. Validate the operation and only its consumed target answer.
   Keep one batched request per decision and existing execution policy gates.
2. Enrich the semantic observation with supported operations and interaction
   context. Resolve native identities if the bridge supports them; otherwise
   preserve explicit freshness limitations. Do not infer hittability from a
   label and a point alone.
3. Give the executor explicit outcomes: rejected before input, executed,
   unchanged after observation, or uncertain. Journal attempted input before
   dispatch and acknowledged execution before the next read. An uncertain
   outcome requires observation, not automatic replay.
4. Keep app-specific saved-state readers in the evaluation harness. General
   completion uses observed UI evidence. Report the agent's completion claim
   separately from the harness verdict, including false success and false failure.
5. Measure protocol calls and readiness separately; consolidate repeated reads
   where the same target/context guard can be preserved. Explore guest change
   notifications only after establishing bridge support.

## Evaluation before believing the design

Use several apps and held-out tasks covering navigation, search/autocomplete,
text replacement, toggles, lists, scrolling, selection and saving. Include
duplicate labels, modals, controls replaced while deciding, nonnumeric options,
loading and interrupted input. Alarm noon/midnight cases remain regressions,
not special branches in policy.

Compare old/new versions with the same tasks and clearly identify whether
privileged facts are available. Record success rate, false completion, failure
reason, model calls, device calls, median and tail latency. Separate session
startup from goal time, and external audit from agent verification. No fixed
1–2 second promise for arbitrary tasks whose navigation and loading vary.

## Implemented slice — 2026-09-20

- `JevActionSpace` binds each operation to compatible controls, including complete
  field/literal and picker/value candidates. No-op selections are omitted.
  Each target head is capped at 250 choices; this bounds the API request but can
  omit controls on dense screens. Arbitrary native option enumeration remains open.
- The decoder validates the action and consumed target distribution/confidence;
  malformed unused heads cannot affect execution. It still uses one request.
- Native observations keep parent context, leaf web links and document titles.
  Live hit tests remove covered targets; target revalidation checks app/document
  scope and semantic identity. These are not atomic native node handles.
- Text replacement uses the observed editable target and checks its resulting
  value. This does not prove autocomplete/search submission semantics.
- Attempt logging precedes input. Uncertain input stops; confirmed pre-input
  rejection has bounded retries. Picker adjustments stop if a value repeats.
- Automatic alarm/preference fact injection was removed from the CLI. Separate
  recorders retain saved-state and Safari sequence audits without feeding Jev.
- History includes field values/context and observed document changes. Safari
  retries do not establish that this fixes completion or ordering: it remains
  experimental, with failures recorded alongside the physically completed run.

Next: atomic observation/readiness and native target identity, then robust
progress/completion evidence. Measure on multiple apps before tuning latency
or extending selection/text generation. Do not add a noon rule or a Safari plan.
