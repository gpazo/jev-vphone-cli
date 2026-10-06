@testable import vphone_cli
import Foundation
import Testing

@MainActor
struct PlannerTests {
    final class Base: JevDecider {
        let name = "fixture"
        var states: [JevState] = []
        var texts: [[String]] = []
        var decision = JevStepDecision(action: .tap, confidence: 0.9, done: 0.3, blocked: 0.1, risky: 0.2,
            targetConfidence: 0.8, targetId: "owner:action1", inputTokens: 17)
        func decide(observation: JevObservation, state: JevState, apps: [(bundleId: String, name: String)],
                    textCandidates: [String]) async -> JevStepDecision {
            states.append(state); texts.append(textCandidates)
            var result = decision
            if state.plannerContext != nil, result.originalGoalStatus == nil {
                result.originalGoalStatus = "continue"; result.originalGoalStatusProbability = 1
            }
            return result
        }
    }
    let observation = ControlMemoryTests().observation("Current item")
    func state() -> JevState {
        return JevState(goal: "Inspect the selected item", device: JevDevice(kind: "test", screen: "test", constraints: []),
            foregroundApp: observation.foregroundApp, observationSource: "accessibility", elements: observation.elements.map(\.described),
            history: [.init(action: "Earlier acknowledged action", changedScreen: true)], verifiedFacts: ["Fixture fact"],
            documentTitle: "Fixture document", observedProgress: JevProgress().snapshot,
            nearbyElements: observation.elements.map(\.described), inputRejection: "Earlier rejection")
    }
    func reply(_ status: String = "continue", _ subgoal: String = "Inspect next item", to input: Data) -> Data {
        let request = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
        let offered = request["offered_actions"] as? [[String: Any]] ?? []
        let action = offered.first { $0["target_key"] as? String == "owner:action1" } ?? offered.first ?? [:]
        let step: [String: Any] = ["operation": action["operation"] ?? "tap", "target_key": action["target_key"] ?? NSNull(),
            "expected_value": action["owner_value"] ?? NSNull(), "after_value": NSNull(), "inspection": true, "subgoal": subgoal]
        return try! JSONSerialization.data(withJSONObject: ["status": status, "subgoal": subgoal, "reason": "Tentative inference",
            "observation_id": request["observation_id"] ?? "unknown", "steps": status == "continue" ? [step] : []])
    }
    func decide(_ wrapper: JevPlannerDecider) async -> JevStepDecision {
        await wrapper.decide(observation: observation, state: state(), apps: [], textCandidates: ["Authorized literal"])
    }

    @Test func subgoalKeepsRawEvidenceOriginalConstraintsAndLiteralCandidates() async throws {
        let base = Base()
        let decider = JevPlannerDecider(base: base, executable: "/unused")
        var input: [String: Any] = [:]
        decider.requestOverride = { data in
            input = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]); return reply(to: data)
        }
        let result = await decide(decider)
        #expect(result.done == 0)
        #expect(result.risky == 0.2 && result.blocked == 0.1)
        #expect(result.executionConfidence == 0.8)
        #expect(result.inputTokens == 17)
        #expect(base.states[0].goal.hasPrefix("Inspect next item"))
        #expect(base.states[0].plannerContext?.originalGoal == state().goal)
        #expect(base.states[0].plannerContext?.proposedReasoning == "Tentative inference")
        #expect(base.states[0].elements.count == state().elements.count)
        #expect(base.states[0].history[0].action == state().history[0].action)
        #expect(base.states[0].verifiedFacts == state().verifiedFacts)
        #expect(base.states[0].documentTitle == state().documentTitle)
        #expect(base.states[0].inputRejection == state().inputRejection)
        #expect(base.states[0].observedProgress != nil && base.states[0].nearbyElements != nil)
        #expect(base.texts == [["Authorized literal"]])
        #expect(input["goal"] as? String == state().goal)
        #expect((input["state"] as? [String: Any])?["goal"] as? String == state().goal)
        #expect(input["max_native_actions"] as? Int == 1)
        #expect(input["previous_subgoal"] == nil)
        #expect(decider.name.contains("external planner"))
    }

    @Test(arguments: [false, true])
    func localCompletionCannotFinishOriginalTask(unselectedFinish: Bool) async throws {
        let base = Base()
        let decider = JevPlannerDecider(base: base, executable: "/unused")
        var requests: [[String: Any]] = []
        decider.requestOverride = { data in
            requests.append(try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]))
            return reply(requests.count == 1 ? "continue" : "complete", to: data)
        }
        base.decision = JevStepDecision(action: unselectedFinish ? .tap : .finish, confidence: 0.97,
            done: 0.99, blocked: 0.12, risky: 0.13, inputTokens: 23)
        let local = await decide(decider)
        #expect(local.action == .wait && local.done == 0)
        #expect(local.blocked == 0.12 && local.risky == 0.13 && local.inputTokens == 23)
        base.decision = JevStepDecision(action: .finish, confidence: 0.98, done: 0.99, blocked: 0, risky: 0, inputTokens: 29)
        let overall = await decide(decider)
        #expect(overall.action == .finish && overall.done == 0.99 && overall.inputTokens == 29)
        #expect(base.states.last?.goal == state().goal)
        #expect(base.states.last?.plannerContext == nil)
        #expect(requests[1]["previous_subgoal"] as? String == "Inspect next item")
        #expect(decider.name.contains("fixture"))
    }

    @Test func plannerCLIIsOptInAndRejectsConflictingModes() throws {
        #expect(try VPhoneJevCommand.parse(["inspect"]).planner == nil)
        let enabled = try VPhoneJevCommand.parse(["inspect", "--planner", "/fixture/planner", "--focused-requests", "--remember-controls"])
        #expect(enabled.planner == "/fixture/planner")
        for conflict in [["--baseline"], ["--explore-controls"], ["--validate-actions"]] {
            #expect(throws: (any Error).self) {
                _ = try VPhoneJevCommand.parse(["inspect", "--planner", "/fixture/planner"] + conflict)
            }
        }
    }

    @Test(arguments: [false, true])
    func rejectedOverallConfirmationWaitsThenReplans(lowDoneFinish: Bool) async {
        let base = Base()
        let decider = JevPlannerDecider(base: base, executable: "/unused")
        var calls = 0
        decider.requestOverride = { data in calls += 1; return reply(calls == 1 ? "complete" : "continue", to: data) }
        base.decision = JevStepDecision(action: lowDoneFinish ? .finish : .tap, confidence: 0.99,
            done: 0.2, blocked: 0.1, risky: 0.2, inputTokens: 19)
        let confirmation = await decide(decider)
        #expect(confirmation.action == .wait && confirmation.done == 0)
        #expect(confirmation.blocked == 0.1 && confirmation.risky == 0.2 && confirmation.inputTokens == 19)
        #expect(base.states[0].goal == state().goal)
        base.decision = JevStepDecision(action: .tap, confidence: 0.99, done: 0, blocked: 0, risky: 0, targetId: "owner:action1", inputTokens: 13)
        let planned = await decide(decider)
        #expect(calls == 2 && planned.action == .tap)
        #expect(base.states[1].goal.hasPrefix("Inspect next item"))
    }

    @Test func localUnableReplansWithoutEndingOriginalTask() async {
        let base = Base()
        let decider = JevPlannerDecider(base: base, executable: "/unused")
        var calls = 0
        decider.requestOverride = { data in calls += 1; return reply("continue", calls == 1 ? "Inspect next item" : "Inspect another item", to: data) }
        base.decision = JevStepDecision(action: .stopUnable, confidence: 0.99, done: 0,
            blocked: 0.1, risky: 0.2, inputTokens: 31)
        let unable = await decide(decider)
        #expect(unable.action == .wait && unable.done == 0 && unable.failure == nil)
        #expect(unable.blocked == 0.1 && unable.risky == 0.2 && unable.inputTokens == 31)
        base.decision = JevStepDecision(action: .tap, confidence: 0.99, done: 0, blocked: 0, risky: 0, targetId: "owner:action1")
        let replanned = await decide(decider)
        #expect(calls == 2 && replanned.action == .tap)
        #expect(base.states[1].goal.hasPrefix("Inspect another item"))
        #expect(VPhoneJevAgent.Policy.default.maxPlannerPlans == 512)
    }

    @Test func defaultReplansAfterEveryDecisionAndPreservesBlockedGuard() async throws {
        let base = Base()
        let decider = JevPlannerDecider(base: base, executable: "/unused")
        var inputs: [Data] = []
        decider.requestOverride = { input in inputs.append(input); return reply(to: input) }
        #expect(VPhoneJevAgent.Policy.default.plannerSubgoalSteps == 1)
        _ = await decide(decider)
        let updated = ControlMemoryTests().observation("Next observed item")
        let nextState = JevState(goal: state().goal, device: state().device, foregroundApp: updated.foregroundApp,
            observationSource: "accessibility", elements: updated.elements.map(\.described),
            history: state().history, verifiedFacts: state().verifiedFacts)
        _ = await decider.decide(observation: updated, state: nextState, apps: [], textCandidates: [])
        #expect(inputs.count == 2 && inputs[0] != inputs[1])
        let secondRequest = try #require(JSONSerialization.jsonObject(with: inputs[1]) as? [String: Any])
        let elements = try #require((secondRequest["state"] as? [String: Any])?["elements"] as? [[String: Any]])
        #expect(elements.first?["value"] as? String == "Next observed item")
        base.decision = JevStepDecision(action: .stopUnable, confidence: 0.99, done: 0,
            blocked: 0.99, risky: 0.98, inputTokens: 11)
        let unable = await decide(decider)
        #expect(inputs.count == 3 && unable.action == .wait)
        #expect(unable.blocked >= VPhoneJevAgent.Policy.default.blocked)
        #expect(unable.risky == 0.98 && unable.inputTokens == 11)
    }

    @Test func boundedSubgoalsReplanAndPlanBudgetStops() async {
        var policy = VPhoneJevAgent.Policy.default
        policy.maxPlannerPlans = 2
        let base = Base()
        let decider = JevPlannerDecider(base: base, executable: "/unused", policy: policy)
        var calls = 0
        decider.requestOverride = { data in calls += 1; return reply(to: data) }
        for _ in 0..<2 { #expect(await decide(decider).failure == nil) }
        #expect(calls == 2)
        #expect(await decide(decider).failure?.contains("budget") == true)
        #expect(calls == 2)
        #expect(base.states.count == 2)
    }

    @Test func blockedOrMalformedPlansNeverCallBase() async throws {
        for invalid in ["blocked", "status", "blank", "oversize", "extra", "missing", "observation", "steps", "step_extra", "step_missing", "target", "value", "finish", "terminal_steps", "bytes"] {
            let base = Base()
            let decider = JevPlannerDecider(base: base, executable: "/unused")
            decider.requestOverride = { input in
                if invalid == "bytes" { return Data(repeating: 32, count: 4097) }
                var object = try #require(JSONSerialization.jsonObject(with: reply(to: input)) as? [String: Any])
                var steps = try #require(object["steps"] as? [[String: Any]])
                switch invalid {
                case "blocked": object["status"] = "blocked"; object["steps"] = []
                case "status": object["status"] = "unknown"
                case "blank": object["subgoal"] = " "
                case "oversize": object["subgoal"] = String(repeating: "x", count: 2049)
                case "extra": object["extra"] = true
                case "missing": object.removeValue(forKey: "reason")
                case "observation": object["observation_id"] = "previous observation"
                case "steps": object["steps"] = steps + steps
                case "terminal_steps": object["status"] = "complete"
                default:
                    switch invalid {
                    case "step_extra": steps[0]["extra"] = true
                    case "step_missing": steps[0].removeValue(forKey: "after_value")
                    case "target": steps[0]["target_key"] = "not offered"
                    case "value": steps[0]["expected_value"] = "different owner value"
                    case "finish": steps[0]["operation"] = "finish"; steps[0]["target_key"] = NSNull()
                    default: break
                    }
                    object["steps"] = steps
                }
                return try JSONSerialization.data(withJSONObject: object)
            }
            #expect(await decide(decider).failure != nil)
            #expect(base.states.isEmpty)
        }
    }

    @Test func defaultStateOmitsPlannerContext() throws {
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state())) as? [String: Any])
        #expect(object["plannerContext"] == nil)
    }

    @Test func subprocessHasBoundedOutputAndTimeoutAndRetainsNonzeroStatus() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fixture")
        func run(_ script: String, timeout: Double = 1, limit: Int = 64) throws -> JevPlannerProcess.Result {
            try Data(("#!/bin/sh\n" + script).utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            return try JevPlannerProcess.run(executable: executable.path, input: Data("raw state".utf8),
                timeout: timeout, limit: limit, terminationGrace: 0.02)
        }
        let echoed = try run("cat\nprintf diagnostic >&2\nexit 7\n")
        #expect(echoed.output == Data("raw state".utf8))
        #expect(echoed.diagnostic == Data("diagnostic".utf8))
        #expect(echoed.status == 7 && echoed.failure == nil)
        let oversized = try run("printf 123456789\n", limit: 4)
        #expect(oversized.output.count == 4 && oversized.failure != nil)
        let timed = try run("exec sleep 1\n", timeout: 0.03)
        #expect(timed.failure?.contains("timed out") == true)
    }
}
