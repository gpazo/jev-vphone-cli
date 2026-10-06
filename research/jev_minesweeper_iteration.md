# Jev Minesweeper iteration — 2026-09-25

The final implementation produced a verified fresh-board win in run `215713`, following a resumed-board win and a failed fresh repeat. This establishes successful play on the recorded board, not a general win rate. The target is the installed, unchanged Donpa Squad app (`fi.misaki.donpa`) on simulator `108417FD-4FA3-4315-9587-0F4A0469E561`.

The controller receives native accessibility observations and its own observed history. It receives no hidden board storage, game solver, screen-point coordinates, or scripted game moves. A stronger external planner may refer to observed row and column labels in a subgoal, but Jev resolves the subgoal through native actions. Task goals describe public game rules. Screenshots support setup and independent outcome review. They do not provide controller perception. Startup is operator-assisted because Donpa's custom new-game popup leaves underlying controls exposed. Gameplay is evaluated separately.

## Acceptance rule

A live run keeps request and response JSON, input attempts and acknowledgments, native AX audits, video, and controller, helper, source, and installed-app hashes. The source checkout revision does not prove that the installed binary came from that checkout.

A win requires all of the following evidence:

- A stable native result panel with the exact supported win syntax.
- `Cleared` at `100%` in the same native observation.
- Two or more stable samples with the same result label and native path.
- A complete audit and an independently reviewed terminal screenshot.
- No acknowledged input after the terminal result.

A model completion claim, a single result poll, and an opening cascade do not satisfy this rule.

## Live runs

All directories below are under `research/artifacts/jev-donpa/`.

| Run | Variant | Observed result |
| --- | --- | --- |
| 201703 | Original, resumed board | 100 actions in 58.626 s. Clearance stayed at 66%. |
| 202739 | Original with public rules in the goal | Resumed 66% reached 73%, then lost in 12.501 s. |
| 202922 | Original with no initial-focus instruction | Two no-effect digs. Stopped in 6.045 s. |
| 203036 | Original with rules and focus instruction | Fresh opening reached 51%. No further clearing after 100 actions in 40.572 s. |
| 203640 | Focused prompt | Resumed 51%, then lost in 3.092 s. |
| 203736 | Focused prompt | Fresh opening reached 66%, then lost and retried. The run produced 20 post-panel inputs and ended with an incomplete replacement board after 43.457 s. |
| 204304 | Focused prompt plus raw control memory | Resumed 55%, then lost in 5.179 s. No post-panel input. |
| 204418 | Focused prompt plus raw control memory | Fresh opening reached 71%, then stopped after loss in 4.834 s. |
| 205017 | Focused prompt, raw control memory, and typed prerequisite gate | Fresh opening reached 69%. The run made no further clearing and stopped on an invalid probability or choice answer after 23 actions in 12.686 s. |
| 205548 | Focused prompt, raw control memory, and validation | Live run resumed 69%, observed 20 cells, and made 221 acknowledged actions in 125.558 s. Clearance stayed at 69%. The run stopped on an invalid assessment answer. |
| 210006 | Persistent attempted-edge exploration | Resumed 69%. The audit saw 46 distinct cells but no additional clearance and no terminal result. |
| 210755 | Native observed-route exploration | Resumed 69%. The audit saw 15 distinct cells but no additional clearance and no terminal result. |
| 211656 | Focused prompt, raw control memory, validation, and route exploration | Resumed 69%. The audit saw 23 distinct cells with no additional clearance and no terminal result. |
| 212649 | Hybrid external planner with Jev native executor | Resumed 69%, reached 91% and observed 60 distinct cells after 32 planner subgoals. The 581.112 s run exhausted its planner budget without a terminal result. |
| 213736 | Hybrid external planner with Jev native executor | Resumed 91% and reached 100% after 132 steps in 663.256 s. The native result panel was stable for 37 samples. No acknowledged input followed the terminal result. |
| 214951 | Hybrid external planner with Jev native executor | Fresh board reached 87%, then first lost at 229.923 s. Eight acknowledged post-terminal inputs included Retry and replacement-board actions; the planner stopped at 242.240 s. No win candidate. |
| 215713 | Atomic external planner plus Jev, fresh board | 0% → opening 82% → 100%. 68 decisions and planner calls, 670.410 s. Stable win, no post-terminal input. |

The 210006, 210755, and 211656 runs are incomplete evaluations. They are not wins or losses because none produced a terminal result panel. The 212649 run is also incomplete. Its 91% clearance is progress, not a win, because it produced no result panel. The 213736 run is the first verified win, but it resumed an existing board. The 214951 run is a fresh-board loss followed by prohibited post-loss continuation, so it is neither a win nor evidence of fresh-board reliability.

## Frozen replay findings

The frozen replay artifacts are under `.codex/pstack-runs/minesweeper/`.

The focused prompt improved some ordinary DecisionReplay cases, including all three calendar-repair-start repetitions. It regressed the calendar-complete fixture by selecting a field instead of finishing in all three repetitions. The prompt is therefore scoped to the native named-action capability. The ordinary fixture payloads remain unchanged outside that capability.

Raw owner memory reduced repeated Dig choices in one 36-call game replay from 12/12 to 7/12. It did not establish useful play or a win. A four-way prerequisite classifier changed nine frozen choices toward movement, but the first live trial stalled in navigation. The classifier remains a model prediction, not a safety proof.

An offline AX-only constraint check found that the selected Row 3, Column 7 cell in the 205548 trace was forced to be a mine by the recorded public clues. The check used no game storage. Its conclusion was never supplied to Jev, the live controller, or the external planner. Production Flag assessment, clarified memory wording, explicit deduction rules, compact typed effect and prerequisite heads, and relevance filtering all still rejected Flag in replay. The failure is in selecting and applying relevant clue evidence, not in missing access to a hidden board.

The stronger planner benchmark used the same raw frozen state and returned `e14:action1` (`Flag`) with a short logical reason. Its JSON output passed schema validation, and its audit recorded no tool calls. This demonstrates that an external planner can use the exposed evidence in this case. It does not show that Jev alone can win, and it does not replace the live acceptance rule.

## Architecture decision

The next live comparison uses an opt-in external planner and executor path. The 212649 run is the first completed hybrid measurement. Jev continues to provide native observations and typed decisions. The planner proposes a subgoal with `{status, subgoal, reason}` from the same observation. Jev decides the native action sequence for that subgoal. The planner never supplies screen coordinates or external coordinate inputs. The planner is disabled by default, and ordinary Jev behavior remains available for comparison.

The planner protocol is bounded and auditable. It accepts JSON on standard input and returns a structured subgoal proposal or a blocked or complete status. The 212649 run ended after exhausting its 32-proposal allowance at 581.112 s. The limit was raised to 128 for subsequent runs. The 213736 and 214951 historical runs used the 128-proposal, 12-native-step bounds. The atomic handoff now replans after each decision, with a 512-proposal cap; run 215713 verified a fresh-board win. The provider now includes one observable target in its instructions, replans locally when it cannot continue, and cleans up helper processes and trailing newlines. It has no simulator access, no game storage, and no tool calls. The recorder records the planner executable hash, any explicitly supplied Codex binary hash, and the optional planner model name. It does not record arbitrary environment variables or credentials.

## Fresh-board fatal transition

Run `214951` reached 87% and then exposed `Row 3, column 7: open, 2` before the fatal transition. The planner's last proposal was to open `row 5, column 8`, with a reason based on observed clues. The corresponding Jev request retained that subgoal but showed the current Board selection as `Row 3, column 8: hidden`; its named actions included `Move down` and `Dig or chord`. Jev selected `e14:action2` (`Dig or chord`), without first completing the movement needed to reach the planner's target. The timeline then records `Row 3, column 8: mine` at 229.512 s and the terminal loss at 229.923 s. This is a plan-to-native-target handoff failure: the planner's textual target was `R5C8`, while the executed dig was `R3C8`.

After the loss, the timeline returned to `Ready` at 231.307 s; the acknowledged `Retry` and subsequent replacement-board actions are included in the eight post-terminal inputs. The final planner stop correctly described the original loss, but only after the prohibited continuation had already occurred. The current experiment replans after every Jev decision and asks for one currently offered action in the provider prompt. It permits at most one native action per proposal, but does not structurally bind the proposal to an action ID.

## Verified resumed-board win

Run `research/artifacts/jev-donpa/20260925-213736/` reached `Cleared 100%` and exposed the native result label `New record! Minefield cleared in 58:09.5 Pace 0.00/s. Unlocked: Hive.` The evaluator recorded the first terminal observation at 655.938 s, 37 stable samples, a complete audit with no errors, and zero acknowledged actions after the terminal result. The terminal screenshot is `research/artifacts/jev-donpa/20260925-213736/terminal.png`; root reviewed it against the native result evidence. The run started from the existing 91% board after 212649, so it does not establish fresh-board reliability.

## Verified fresh-board win on the final implementation

Run [`215713`](artifacts/jev-donpa/20260925-215713/result.json) began at 0%. The operator only tapped Retry to prepare a new board; the controller selected the first cell and performed every gameplay input. The opening cleared 82%; subsequent play reached 100% without a loss or reset. This run used the cleaned implementation with `--focused-requests`, `--remember-controls`, and the optional Codex planner, replanning after each Jev decision.

The native win panel first appeared at 650.804 s and remained stable for 96 samples. The controller stopped at 670.410 s after 68 decisions and 68 planner calls. The audit completed without errors, and there were zero acknowledged inputs after the terminal result. Root reviewed the [terminal screenshot](artifacts/jev-donpa/20260925-215713/terminal.png). The [recording](artifacts/jev-donpa/20260925-215713/raw.mov) and exact requests, responses, native audits, and executable provenance are retained beside it. Live play used the debug Simulator build; the signed release build and its signature were also verified.

This is a hybrid planner-plus-Jev result. Pure Jev did not win in the recorded experiments. The game and its source were unchanged, and the planner received only the original goal, native accessibility observations, and controller history. No hidden board state, OCR, app-specific solver, or scripted game sequence was introduced. The earlier failed fresh repeat remains in the table and analysis above.

## Final checks and limitations

All 90 Swift tests, 7 Python planner-provider tests, and 14 evaluator tests pass. `make build` and strict code-signature verification pass. The unused classifier, routing, and malformed-answer retry experiments were removed after archiving their evidence. Independent review confirmed that cleanup preserved the successful path’s memory and action-gating behavior.

The final atomic path has one successful fresh-board trial. Its 11-minute runtime does not establish a general speed or reliability rate. Planner proposals remain textual; code enforces at most one native action per proposal but does not bind the proposed action text to an action ID. Raw owner memory has count bounds, not byte bounds, and has no generic new-surface identity detector: use a new top-level goal after resetting an app surface. All new options are off by default.
