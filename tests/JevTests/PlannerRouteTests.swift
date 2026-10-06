@testable import vphone_cli
import CoreGraphics
import Foundation
import Testing

@MainActor
struct PlannerRouteTests {
    func observation(_ value: String, id: String = "owner", tick: String = "1") -> JevObservation {
        let owner = JevElement(id: id, role: "statictext", label: "Selection", value: value, point: .zero, context: "Canvas")
        return JevObservation(foregroundApp: "Viewer", elements: [owner]
            + JevSimulatorObserver.customElements(for: owner, names: ["Advance", "Activate"])
            + [JevElement(id: "clock", role: "statictext", label: "Elapsed \(tick)", value: tick, point: .zero)],
            bounds: CGRect(x: 0, y: 0, width: 400, height: 800), source: .accessibility, documentTitle: "Document")
    }
    func state(_ raw: JevObservation, known: [String] = ["A", "B", "C"]) -> JevState {
        var progress = JevProgress(rememberControls: true)
        for value in known { progress.observe(observation(value)) }
        progress.observe(raw)
        return JevState(goal: "Inspect the requested items; stop if a completion panel appears.",
            device: .init(kind: "test", screen: "test", constraints: []), foregroundApp: raw.foregroundApp,
            observationSource: "accessibility", elements: raw.elements.map(\.described), history: [], verifiedFacts: nil,
            documentTitle: raw.documentTitle, observedProgress: progress.snapshot)
    }
    func reply(_ input: Data, values: [String] = ["A", "B"], after: [String?] = ["B", nil]) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: PlannerTests().reply(to: input)) as? [String: Any])
        let first = try #require((object["steps"] as? [[String: Any]])?.first)
        object["steps"] = values.enumerated().map { index, value in
            var step = first
            step["expected_value"] = value; step["after_value"] = after[index].map { $0 as Any } ?? NSNull()
            step["inspection"] = true; step["subgoal"] = "Inspect step \(index + 1)"
            return step
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
    func decide(_ decider: JevPlannerDecider, _ raw: JevObservation) async -> JevStepDecision {
        await decider.decide(observation: raw, state: state(raw), apps: [], textCandidates: [])
    }
    func wrapper(_ base: PlannerTests.Base, count: Int = 6) -> JevPlannerDecider {
        var policy = VPhoneJevAgent.Policy.default; policy.plannerSubgoalSteps = count
        return JevPlannerDecider(base: base, executable: "/unused", policy: policy)
    }

    @Test func routeRequiresAcknowledgmentAndRebindsFreshIDsForEveryJevDecision() async throws {
        let base = PlannerTests.Base()
        let planned = wrapper(base)
        var calls = 0
        planned.requestOverride = { input in calls += 1; return calls == 1 ? try reply(input) : PlannerTests().reply(to: input) }
        let first = await decide(planned, observation("A"))
        #expect(first.failure == nil && first.executionToken != nil && first.observationGuard != nil)
        planned.executionDidResolve(.acknowledged(first.executionToken))
        base.decision = .init(action: .tap, confidence: 1, done: 0, blocked: 0, risky: 0, targetId: "renumbered:action1")
        let second = await decide(planned, observation("B", id: "renumbered", tick: "2"))
        #expect(second.failure == nil && second.targetId == "renumbered:action1")
        #expect(calls == 1 && base.states.count == 2)
        #expect(base.states[1].goal.hasPrefix("Inspect step 2"))
        #expect(base.states[1].plannerContext?.proposedAction?.targetKey == "renumbered:action1")
        planned.executionDidResolve(.acknowledged(second.executionToken))
        _ = await decide(planned, observation("Unpredicted last outcome", tick: "3"))
        #expect(calls == 2)
    }

    @Test(arguments: ["proposed", "rejected", "interstitial", "wrong_token", "unexpected_value", "new_element", "ambiguous", "incomplete"])
    func routeInvalidationReplansWithoutReusingTheNextStep(kind: String) async throws {
        let base = PlannerTests.Base()
        let planned = wrapper(base)
        var calls = 0
        planned.requestOverride = { input in calls += 1; return calls == 1 ? try reply(input) : PlannerTests().reply(to: input) }
        let first = await decide(planned, observation("A"))
        switch kind {
        case "proposed": break
        case "rejected": planned.executionDidResolve(.rejected(first.executionToken, "native target stale"))
        case "interstitial": planned.executionDidResolve(.acknowledged(nil))
        case "wrong_token": planned.executionDidResolve(.acknowledged(UUID()))
        default: planned.executionDidResolve(.acknowledged(first.executionToken))
        }
        var next = observation(kind == "unexpected_value" ? "Unexpected" : "B")
        if kind == "new_element" { next.elements.append(.init(id: "panel", role: "image", label: "Result", value: nil, point: .zero)) }
        if kind == "ambiguous" { next.elements.append(next.elements[0]) }
        if kind == "incomplete" { next.completenessIssue = "missing subtree" }
        _ = await decide(planned, next)
        #expect(calls == 2)
    }

    @Test(arguments: ["mutation", "chain", "unknown_after", "missing_after", "ordinary", "too_many"])
    func rejectsInvalidBatchesBeforeJev(kind: String) async throws {
        let base = PlannerTests.Base()
        let planned = wrapper(base)
        planned.requestOverride = { input in
            var object = try #require(JSONSerialization.jsonObject(with: try reply(input)) as? [String: Any])
            var steps = try #require(object["steps"] as? [[String: Any]])
            switch kind {
            case "mutation": steps[1]["inspection"] = false
            case "chain": steps[1]["expected_value"] = "C"
            case "unknown_after": steps[0]["after_value"] = "Never observed"
            case "missing_after": steps[0]["after_value"] = NSNull()
            case "ordinary": steps[1]["operation"] = "scroll_up"; steps[1]["target_key"] = NSNull()
            case "too_many": steps = Array(repeating: steps[0], count: 7)
            default: break
            }
            object["steps"] = steps
            return try JSONSerialization.data(withJSONObject: object)
        }
        #expect(await decide(planned, observation("A")).failure != nil)
        #expect(base.states.isEmpty)
    }

    @Test func secondExpectedValueMustEqualFirstOutcomeEvenWhenBothAreKnownAndOffered() async throws {
        let base = PlannerTests.Base()
        let planned = wrapper(base)
        planned.requestOverride = { input in
            try reply(input, values: ["A", "C"], after: ["B", nil])
        }
        let result = await decide(planned, observation("A"))
        #expect(result.failure?.contains("route outcomes do not chain exactly") == true)
        #expect(base.states.isEmpty)
    }

    @Test func structuralGuardAllowsPassiveTicksButRejectsNewControlsAndOwnerChanges() throws {
        let raw = observation("A")
        let guardEvidence = JevPlannerObservationGuard(observation: raw, target: raw.elements[1], owner: raw.elements[0])
        #expect(guardEvidence.rejection(in: observation("A", tick: "999")) == nil)
        #expect(guardEvidence.rejection(in: observation("B")) != nil)
        var changed = observation("A", tick: "999")
        changed.elements.append(.init(id: "result", role: "image", label: "Result", value: nil, point: .zero))
        #expect(guardEvidence.rejection(in: changed) != nil)
        changed = raw; changed.elements.removeLast()
        #expect(guardEvidence.rejection(in: changed) != nil)
        changed = raw; changed.completenessIssue = "missing subtree"
        #expect(guardEvidence.rejection(in: changed) != nil)
    }

    @Test func knownOutcomesMustBelongToTheExactOwnerScope() throws {
        let raw = observation("A")
        let space = JevActionSpace(observation: raw, apps: [], textCandidates: [], pickerValues: [])
        let bindings = JevPlannerDecider.bindings(observation: raw, space: space)
        let steps = [
            JevPlannerDecider.Step(operation: "tap", targetKey: "owner:action1", expectedValue: "A", afterValue: "B", inspection: true, subgoal: "First"),
            JevPlannerDecider.Step(operation: "tap", targetKey: "owner:action1", expectedValue: "B", afterValue: nil, inspection: true, subgoal: "Second"),
        ]
        var evidence = state(raw, known: ["A"])
        evidence.observedProgress?.controlMemory = .init(owners: [
            .init(scope: .init(app: "Other app", document: raw.documentTitle, owner: "Selection", context: "Canvas > Selection"),
                previouslyObservedValues: ["B"]),
        ])
        #expect(throws: (any Error).self) {
            _ = try JevPlannerDecider.checkedRoute(steps, bindings: bindings, observation: raw, state: evidence)
        }
    }

    @Test func batchCLIIsBoundedAndRequiresPlannerAboveOne() throws {
        #expect(try VPhoneJevCommand.parse(["inspect"]).plannerMaxActions == 1)
        #expect(try VPhoneJevCommand.parse(["inspect", "--planner", "/fixture", "--planner-max-actions", "6"]).plannerMaxActions == 6)
        for args in [["--planner-max-actions", "2"], ["--planner", "/fixture", "--planner-max-actions", "0"],
                     ["--planner", "/fixture", "--planner-max-actions", "7"]] {
            #expect(throws: (any Error).self) { _ = try VPhoneJevCommand.parse(["inspect"] + args) }
        }
    }
}
