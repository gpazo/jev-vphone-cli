# Jev-driven phone control

Give the phone a goal in plain language; Jev decides what to do next, one bounded
step at a time.

```sh
export TYPESAFE_API_KEY=...            # from https://console.typesafe.ai/
make boot                              # in one terminal
make jev PROMPT="turn on airplane mode"
```

No VM handy? The agent runs against a fake phone:

```sh
make jev_fake PROMPT="turn on airplane mode"
make jev_fake PROMPT="delete all my photos" SCREEN=photos    # watch the gate fire
```

## What Jev is, and what it is not

Jev is a **System One** model: it returns typed judgments and calibrated
probabilities, not text. It does not write, plan, or explain. Ask it a question
with a defined answer space and it tells you which answer, and how sure it is.

That shapes the whole design:

- **Jev never generates text.** For `type_text`, code extracts candidate spans
  from your goal and Jev *selects* one.
- **Jev never produces coordinates.** It picks an element by id; code looks up
  where that element is.
- **Jev never decides whether to act.** It reports `risky`, `blocked` and
  confidence; the thresholds that turn those into behaviour live in code.

The model supplies judgment. Code owns the workflow.

## The loop

```
observe ──→ one batched Jev request ──→ code decides ──→ act ──→ settle ──→ observe
   │                                          │
   │                                          └── stop: done / blocked / stuck /
   │                                                    low confidence / budget
   └── accessibility tree, else OCR
```

Each step sends **one** request containing every question at once. They are
answered in parallel and cannot see each other, so speculative questions cost
tokens but not latency.

## The questions

| id | type | asked | consumed |
|---|---|---|---|
| `action` | Choice | always | always |
| `target` | Choice over on-screen element ids | when elements exist | if `action == tap` |
| `app` | Choice over installed bundle ids | when apps are known | if `action == open_app` |
| `text_span` | Choice over spans code pulled from the goal | when candidates exist | if `action == type_text` |
| `done` | Noul | always | always |
| `blocked` | Noul | always | always |
| `risky` | Noul | always | always |

`target`, `app` and `text_span` are **speculative** — asked before anyone knows
which action wins, and discarded when the branch isn't taken. Each states its own
premise ("Suppose the agent taps something this step…") because the questions
cannot see each other's answers.

The action vocabulary is named by intent rather than gesture — `scroll_down`, not
`swipe_up` — because the model reasons about what should happen, and which
gesture achieves it is code's business.

## The gates

All in `VPhoneJevAgent.Policy`, all evaluated in code:

```
done.noul    >= 0.80             → stop, success
blocked.noul >= 0.60             → stop, hand back to the human
risky.noul   >= 0.50 && !--yes   → confirm before acting
action.confidence <  0.50        → stop rather than guess
action.confidence <  0.85        → confirm
screen unchanged 3 steps         → stop, stuck
steps > 25                       → stop, budget
```

Two guards are pure code, never asked of the model: **stuck detection** (the
model sees one screen at a time and cannot notice a loop) and the **step budget**.

Note `blocked` is checked before `risky`, so a screen that is both reports as
blocked.

**These numbers are starting points.** TypeSafe's own guidance is that thresholds
must be evaluated against real data and real consequences. Watch runs with
`--verbose` and move them.

A note on reading the probabilities: Choice and Score carry `confidence`
(a statistic over the probability distribution's shape); **Nouls do not** — the
probability *is* the answer. A Noul near 0.5 means genuinely uncertain, not
"medium intensity".

## Observation

Jev takes text only, so the screen must be textified first. Two providers fill
the same `JevObservation`:

- **Accessibility tree** (guest, preferred) — roles, labels, values, frames;
  sees icon-only controls and toggle state. See
  [`research/jev_accessibility_spike.md`](../research/jev_accessibility_spike.md).
- **Vision OCR** (host, fallback) — rendered text only; cannot see an icon-only
  button or tell whether a switch is on.

Every response reports which one ran, and swapping between them changes no agent
code.

## Verification (partly built)

Model judgment should decide *what to do*; observed facts should decide *what
happened*. `JevState.verifiedFacts` is the channel for the second half — facts
code has checked, kept separate from what the screen appears to say, and
referenced by the `done` question only when present.

**Nothing populates it yet.** Today `done` is judged from the observation alone.
The intended source is the guest itself: "did airplane mode actually turn on" is
a `settingsGet(domain:key:)` reading, not a screenshot interpretation. Wiring it
needs a goal→setting mapping that does not generalise, so it is left as a seam
on `VPhoneJevAgent` rather than guessed at.

## Cost

A step is roughly 1,200–1,500 input tokens, including all speculative questions.
At $42 per billion input tokens that is about **$0.00005 per step** — a
three-step task costs well under a hundredth of a cent. Output tokens are free.
Cost is not a reason to trim questions; latency might be.

## Files

| File | Role |
|---|---|
| `VPhoneJevClient.swift` | HTTP client for `POST /v1/systemone`; question and answer types |
| `VPhoneJevObserver.swift` | `JevObservation` + accessibility and OCR providers |
| `VPhoneJevQuestions.swift` | Question construction, action vocabulary, text-span extraction |
| `VPhoneJevAgent.swift` | The loop and every threshold |
| `VPhoneJevSocket.swift` | Out-of-process observer/actuator over `vphone.sock` |
| `VPhoneJevCLI.swift` | `vphone-cli jev` |
| `tests/jev_fake_phone.py` | Fake phone for tuning without booting a VM |

## Tuning

The fake phone exists so question wording and thresholds can be iterated in
seconds instead of VM boots. It models a few screens, real toggle state, and taps
that actually change things.

```sh
make jev_fake PROMPT="turn on airplane mode"     # happy path
make jev_fake PROMPT="turn off wifi" SCREEN=settings
make jev_fake PROMPT="delete all my photos" SCREEN=photos
```

When a run goes wrong, `--verbose` shows the state and every probability. Separate
the causes before changing anything: missing evidence in the observation, a
question that was ambiguous, a threshold set wrong, or a code bug. They need
different fixes, and only the last two are in this repo's control.
