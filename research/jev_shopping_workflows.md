# Generic shopping workflow improvements

## Scope

The lululemon Simulator demo exposed failures in compound-goal navigation. The controller found pants but backed out of the product page twice, then needed separate size and bag instructions. This work retains the original goal while the existing guarded planner supplies local subgoals, waits for native transitions to settle, records a current completion audit, and exposes the existing warm session to callers.

The controller has no retailer-specific navigation rules. The app binary is unchanged. Completion remains a model judgment under code-owned thresholds. An evidence record makes that judgment auditable; it does not formally prove a free-form goal.

## Baseline evidence

The supplied app is `com.lululemon.shopapp-dev` version 9.40.0, an arm64 Simulator build with minimum iOS 18.0, tested on iOS 26.5. Its visible environment is staging. The earlier demo added one Graphite Grey Align pant, size 4, without checkout.

Evidence is retained locally in `.local-apps/lululemon/pants-demo/`. The broad task used ten decisions before declining an uncertain scroll. It revisited the product page three times. A narrower follow-up also stopped on scroll confidence 0.42. The subsequent size-only goal used one tap, and the bag goal scrolled, tapped Add to bag once, and opened the bag. This is an assisted baseline, not an unassisted success.

Frozen native states show outgoing product-list labels alongside incoming product-detail labels immediately after navigation. Nearby read-only elements already included size options and Add to bag below the viewport. Those observations motivate settling and automatic subgoals. They do not justify changing confidence gates.

The live raw AX tree exposes AutomationType, Children, ElementBaseType, ElementType, Frame, Identifier, Label, and Value. Selected and busy fields were not observed. The implementation must not invent those facts or infer selection from an acknowledged tap.

## Design decision

Pstack grounding and four independent design candidates are retained in `.codex/pstack-runs/shopping-improvements/`. The independent cross-review chose the smallest design that reuses the existing guarded planner and session. A new workflow language, shopping effect categories, planner-authored truth predicates, and a second runtime manager were rejected.

The Model the Domain principle shaped a typed per-goal completion audit and session messages. The Prove It Works principle requires a live bag inspection and a reproducible session test in addition to the build and unit tests. The simulator, builds, and integration remain under one owner; implementation and independent reviews are separate.

## Validation status

Validation completed on 2026-10-07. The baseline executable and planner helper are retained in the local run directory. The staging cart was cleared using Jev before evaluation.

The first run stopped after opening search: one native hit-test read took 1.7 seconds, leaving insufficient time to meet the 150 ms quiet interval within the 2.5-second observation budget. It performed no cart mutation. The controller now permits two bounded passive retries at the same decision step. Persistent transitions still stop before judgment or input. Tests cover retry counts zero through two and a slow initial read with a one-step budget.

The second run accepted the entire original shopping request once, with no manual subgoals. It selected an available size, tapped Add to bag exactly once, opened the bag, and finished in **181.901 seconds**, over 16 decision steps and 11 native actions. Setup took **2.297 seconds**, separately. A second read-only bag-verification goal completed in the same process in **8.303 seconds**, one decision, and no native input. Both requests produced completion audits. The final source subsequently corrected passive retry step accounting; no passive timeout occurred in this successful run.

Independent native AX and screenshot inspection confirmed:

- Bag: 1 item; Quantity: 1.
- lululemon Align High-Rise Pant 28 inches.
- Heathered Core Medium Grey, size 10, $98.
- The preferred size 6 was explicitly unavailable; Medium was not offered.

There was no checkout, purchase, or sign-in. The final cart remains visible. Local artifacts are `.codex/pstack-runs/shopping-improvements/live/` (`events.jsonl`, `diagnostics.log`, planner traces, `cart-ax.json`, `cart.png`). The failed attempt is preserved in `live-attempt1/`.

Verification: 141 focused Swift tests in 20 suites passed, 11 command/session integration tests passed, seven planner-helper tests passed, and `make build` plus strict code-signature verification passed. Coverage includes unstable/empty observations, changed parent state, stale completion facts, passive retry bounds, fresh per-goal session state, duplicate request IDs, and bundled-helper shadowing from an arbitrary working directory. The live Simulator used the debug binary; the signed release binary was built and signature-checked, not used for this run.

This establishes one unassisted shopping success, not a speed or reliability distribution. The planner adds a model call per decision. Three pending inputs were deferred after the observed screen changed, and final completion was rejudged after a screen change. A size-verification scroll round trip also remains: the bounded historical journal retains controls but omits passive labels such as “Size, 10.” A future generic optimization can retain bounded verbatim passive changes as historical evidence, without using old labels as current completion proof. No retailer-specific rule or confidence reduction was added.

The PATH Codex CLI was killed with signal 9 before reporting its version. The existing `JEV_CODEX_BINARY` override points live planner tests at `/Applications/ChatGPT.app/Contents/Resources/codex`, which runs successfully. No host security settings changed.

## Run a compound goal

Build the Simulator client with `make patcher_build`. Use `--decompose` to select the bundled tool-free planner. It accepts the whole goal once and proposes one currently offered action at a time. `--planner PATH` remains available for an explicit planner executable; the two options are mutually exclusive.

```sh
.build/debug/vphone-cli jev --simulator booted --decompose \
  'Find pants, choose an available size, add exactly one pair, and show the bag. Do not checkout or purchase.'
```

For the current host, set `JEV_CODEX_BINARY=/Applications/ChatGPT.app/Contents/Resources/codex` before using the bundled planner. This selects a working installed CLI. The usual Codex authentication is still required.

## Reuse a session

```sh
.build/debug/vphone-cli jev --simulator booted --decompose --session --session-json
```

Send one JSON object per line with a unique `id` and a `goal`. Read the `ready` event before sending the first request. Diagnostics go to stderr; stdout contains JSON events. A terminal `result` includes the outcome, elapsed time, and a `completionAudit` on success. A repeated ID is rejected rather than running the goal twice. Task progress and plans are fresh for each goal, while device and model resources are reused. IDs are scoped to the current process, not a durable deduplication database.

```json
{"id":"browse-1","goal":"Open the shopping categories without signing in."}
{"id":"pants-1","goal":"Find pants, choose an available size, add exactly one pair, and show the bag. Do not checkout or purchase."}
```

The existing plain `--session` still accepts one text goal per line. Unattended execution uses the existing `--yes` option; all hard confidence and target-freshness gates remain active. A long-lived session can still fail if its underlying native helper or device disconnects. A stopped result is not success and must not trigger a blind retry of a potentially completed mutation.

Planning introduces another model call. Connection reuse avoids repeated device setup, but it does not remove per-action planner time. End-to-end speed must be measured separately from unassisted task completion.
