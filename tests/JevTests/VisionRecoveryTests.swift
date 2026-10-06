@testable import vphone_cli
import CoreGraphics
import Foundation
import Testing

@MainActor
struct VisionRecoveryTests {
    static func choice(_ selected: String, options: [String], confidence: Double = 0.8, probability: Double = 0.8) -> JevAnswer {
        let probabilities = Dictionary(uniqueKeysWithValues: options.map {
            ($0, $0 == selected ? probability : (1 - probability) / Double(options.count - 1))
        })
        return JevAnswer(type: "choice", noul: nil, choice: selected, score: nil,
            probabilities: probabilities, confidence: confidence)
    }

    static func weakFinish() -> JevStepDecision {
        JevStepDecision(action: .finish, confidence: 0.1368, done: 0.1644,
            blocked: 0.0178, risky: 0.3452, actionProbability: 0.368,
            originalGoalStatus: "continue", originalGoalStatusProbability: 0.9513,
            visionJudgment: JevVisionJudgment(answer: choice("alreadySatisfied",
                options: JevVisionJudgment.Diagnosis.allCases.map(\.rawValue), confidence: 0.1368)), inputTokens: 17)
    }

    func proposedState(_ observation: JevObservation) -> JevState {
        var state = PlannerRouteTests().state(observation)
        state.plannerContext = .init(originalGoal: state.goal, proposedReasoning: "Unverified proposal",
            proposedAction: .init(operation: "tap", targetKey: observation.elements[1].id, description: "Advance"))
        return state
    }

    func reply(_ input: Data, action: String, status: String = "continue") throws -> Data {
        let request = try #require(JSONSerialization.jsonObject(with: input) as? [String: Any])
        let offered = try #require(request["offered_actions"] as? [[String: Any]])
        let selected = offered.first { $0["target_key"] as? String == action }
        let step: [String: Any] = ["operation": "tap", "target_key": action,
            "expected_value": selected?["owner_value"] ?? "A", "after_value": NSNull(),
            "inspection": true, "subgoal": "Inspect the current selection"]
        return try JSONSerialization.data(withJSONObject: ["status": status, "subgoal": "Inspect selection",
            "reason": "Reconsider the local proposal", "observation_id": request["observation_id"]!,
            "steps": status == "continue" ? [step] : []])
    }

    final class Screens: JevObservationProvider {
        var reads = 0
        var failAt: Int?
        var interstitialAt: Int?
        func observe() async throws -> JevObservation {
            reads += 1
            if reads == failAt { throw JevStaleTargetError(reason: "Observation unavailable") }
            var observation = PlannerRouteTests().observation("A", tick: String(reads))
            if reads == interstitialAt {
                observation.elements.append(.init(id: "later", role: "button", label: "Not Now", value: nil, point: .zero))
            }
            return observation
        }
    }

    @Test(arguments: [false, true])
    func weakLocalFinishYieldsWithoutInputThenPlansFromFreshEvidence(interstitial: Bool) async throws {
        let screens = Screens(), primary = PlannerTests.Base(), vision = PlannerTests.Base()
        if interstitial { screens.interstitialAt = 4 }
        vision.decision = Self.weakFinish()
        let fallback = JevVisionFallbackDecider(primary: primary, vision: vision, observer: screens)
        let planner = JevPlannerDecider(base: fallback, executable: "/unused")
        var requests: [[String: Any]] = []
        planner.requestOverride = { input in
            requests.append(try #require(JSONSerialization.jsonObject(with: input) as? [String: Any]))
            return try reply(input, action: "owner:action1", status: requests.count == 1 ? "continue" : "blocked")
        }
        let inputs = FormValidationTests.Inputs()
        var policy = VPhoneJevAgent.Policy.default
        policy.maxSteps = 4; policy.settleMilliseconds = 0
        let agent = VPhoneJevAgent(goal: "Inspect the current selection", decider: planner,
            provider: screens, actuator: inputs, policy: policy, mode: .unattended)
        var steps: [VPhoneJevAgent.Step] = []
        agent.onStep = { steps.append($0) }
        let outcome = try await agent.run()
        guard case let .stopped(reason, count) = outcome else { Issue.record("Expected bounded stop"); return }
        #expect(reason == "Planner blocked: Reconsider the local proposal" && count == 2)
        #expect(inputs.taps.isEmpty && screens.reads == 4 && requests.count == 2)
        #expect(steps.count == 1 && steps[0].executed == false && steps[0].actionConfidence == 0)
        #expect(steps[0].detail == "replanning after unresolved vision; no input executed")
        let nextState = try #require(requests[1]["state"] as? [String: Any])
        if interstitial {
            #expect(nextState["unverifiedVisionFeedback"] == nil)
        } else {
            let feedback = try #require(nextState["unverifiedVisionFeedback"] as? [String: Any])
            let judgment = try #require(feedback["judgment"] as? [String: Any])
            #expect(judgment["diagnosis"] as? String == "alreadySatisfied")
            #expect(judgment["confidence"] as? Double == 0.1368)
            #expect(feedback["sourceObservationID"] as? String == requests[0]["observation_id"] as? String)
        }
        #expect((nextState["history"] as? [Any])?.isEmpty == true && nextState["verifiedFacts"] == nil)
        #expect(requests[1]["previous_subgoal"] == nil)
        let elements = try #require(nextState["elements"] as? [[String: Any]])
        #expect(elements.first { $0["id"] as? String == "clock" }?["value"] as? String == "4")
        #expect(elements.contains { $0["label"] as? String == "Not Now" } == interstitial)
        #expect(agent.totalInputTokens == 34)
    }

    @Test func returningToEarlierEvidenceRestoresItsMatchingFeedbackAndExclusion() async throws {
        let base = PlannerTests.Base()
        base.decision = Self.weakFinish(); base.decision.recovery = .unresolvedVision
        let planner = JevPlannerDecider(base: base, executable: "/unused")
        var requests: [[String: Any]] = []
        planner.requestOverride = { input in
            requests.append(try #require(JSONSerialization.jsonObject(with: input) as? [String: Any]))
            return try reply(input, action: "owner:action1")
        }
        let fixture = PlannerRouteTests()
        #expect(await fixture.decide(planner, fixture.observation("A")).recovery == .reobserve)
        base.decision.visionJudgment = JevVisionJudgment(answer: Self.choice("unknown",
            options: JevVisionJudgment.Diagnosis.allCases.map(\.rawValue)))
        #expect(await fixture.decide(planner, fixture.observation("B")).recovery == .reobserve)
        let stopped = await fixture.decide(planner, fixture.observation("A", tick: "99"))
        #expect(stopped.failure?.contains("unoffered or excluded proposal") == true)
        let state = try #require(requests[2]["state"] as? [String: Any])
        let feedback = try #require(state["unverifiedVisionFeedback"] as? [String: Any])
        let judgment = try #require(feedback["judgment"] as? [String: Any])
        #expect(judgment["diagnosis"] as? String == "alreadySatisfied")
        #expect(feedback["sourceObservationID"] as? String == requests[0]["observation_id"] as? String)
        let proposal = try #require(feedback["rejectedProposal"] as? [String: Any])
        #expect(proposal["targetKey"] as? String == "owner:action1")
        #expect(base.states.count == 2)
    }

    @Test func freshAlternativeRequiresJevAndExecutesExactlyOnceWithAcknowledgment() async throws {
        final class Recorded: JevDecider {
            let name = "recorded planner"
            let inner: JevPlannerDecider
            var decisions: [JevStepDecision] = []
            var events: [JevExecutionEvent] = []
            init(_ inner: JevPlannerDecider) { self.inner = inner }
            func decide(observation: JevObservation, state: JevState, apps: [(bundleId: String, name: String)],
                        textCandidates: [String]) async -> JevStepDecision {
                let decision = await inner.decide(observation: observation, state: state, apps: apps, textCandidates: textCandidates)
                decisions.append(decision)
                return decision
            }
            func executionDidResolve(_ event: JevExecutionEvent) {
                events.append(event); inner.executionDidResolve(event)
            }
        }
        final class Inputs: JevSemanticActuator {
            var pressed: [String] = []
            func press(_ element: JevElement) async throws { pressed.append(element.id) }
            func adjust(_ element: JevElement, up: Bool) async throws { Issue.record("Unexpected adjust") }
            func select(_ value: String, on element: JevElement) async throws { Issue.record("Unexpected select") }
            func fill(_ text: String, on element: JevElement) async throws { Issue.record("Unexpected fill") }
            func tap(at point: CGPoint) async throws { Issue.record("Unexpected coordinate tap") }
            func scroll(reveal: JevScrollDirection) async throws { Issue.record("Unexpected scroll") }
            func drag(at point: CGPoint, up: Bool) async throws { Issue.record("Unexpected drag") }
            func type(_ text: String) async throws { Issue.record("Unexpected type") }
            func pressHome() async throws { Issue.record("Unexpected home") }
            func launch(bundleId: String) async throws { Issue.record("Unexpected launch") }
        }
        let screens = Screens(), primary = PlannerTests.Base(), vision = PlannerTests.Base(), inputs = Inputs()
        vision.decision = Self.weakFinish()
        let fallback = JevVisionFallbackDecider(primary: primary, vision: vision, observer: screens)
        let planner = JevPlannerDecider(base: fallback, executable: "/unused")
        var requests = 0
        planner.requestOverride = { input in
            requests += 1
            #expect(inputs.pressed.isEmpty)
            if requests == 2 {
                let request = try #require(JSONSerialization.jsonObject(with: input) as? [String: Any])
                let offered = try #require(request["offered_actions"] as? [[String: Any]])
                #expect(!offered.contains { $0["target_key"] as? String == "owner:action1" })
                primary.decision.targetId = "owner:action2"
                primary.decision.targetConfidence = 1
            }
            return try reply(input, action: requests == 1 ? "owner:action1" : "owner:action2")
        }
        let recorded = Recorded(planner)
        var policy = VPhoneJevAgent.Policy.default
        policy.maxSteps = 2; policy.settleMilliseconds = 0
        let agent = VPhoneJevAgent(goal: "Inspect the current selection", decider: recorded,
            provider: screens, actuator: inputs, policy: policy, mode: .unattended)
        var steps: [VPhoneJevAgent.Step] = []
        agent.onStep = { steps.append($0) }
        let result = try await agent.run()
        guard case .exhausted(steps: 2) = result else { Issue.record("Expected two bounded steps"); return }
        #expect(inputs.pressed == ["owner:action2"])
        #expect(requests == 2 && primary.states.count == 2 && fallback.requests == 1 && vision.states.count == 1)
        #expect(primary.states[1].plannerContext?.proposedAction?.targetKey == "owner:action2")
        #expect(primary.states[1].history.isEmpty && screens.reads == 5)
        #expect(steps.map(\.executed) == [false, true])
        #expect(recorded.decisions[0].recovery == .reobserve && recorded.decisions[0].executionToken == nil)
        let token = try #require(recorded.decisions[1].executionToken)
        #expect(recorded.decisions[1].recovery == nil && recorded.decisions[1].observationGuard != nil)
        #expect(recorded.events.count == 1)
        guard case let .acknowledged(acknowledgedToken) = recorded.events[0] else {
            Issue.record("Expected native execution acknowledgment"); return
        }
        #expect(acknowledgedToken == token)
    }

    @Test(arguments: ["missing", "wrong_type", "nan", "range"])
    func malformedPrimarySafetyCannotEscalateToVision(kind: String) async throws {
        let observation = PlannerRouteTests().observation("A")
        let space = JevActionSpace(observation: observation, apps: [], textCandidates: [], pickerValues: [])
        var primary = JevModelDecider(client: try VPhoneJevClient(apiKey: "offline-fixture"))
        primary.requestOverride = { _, _ in
            var answers: [String: JevAnswer] = [
                JevQuestions.action: Self.choice("tap", options: space.operations.map(\.rawValue), confidence: 0.3),
                JevQuestions.tapTarget: Self.choice("owner:action1", options: Array(space.targets[.tap]!.keys)),
                JevQuestions.originalGoalStatus: Self.choice("continue", options: ["continue", "complete", "stop"]),
            ]
            for head in [JevQuestions.done, JevQuestions.blocked, JevQuestions.risky] {
                answers[head] = JevAnswer(type: "noul", noul: 0.1, choice: nil, score: nil, probabilities: nil, confidence: nil)
            }
            switch kind {
            case "missing": answers[JevQuestions.risky] = nil
            case "wrong_type": answers[JevQuestions.risky] = Self.choice("safe", options: ["safe", "risky"])
            default: answers[JevQuestions.risky] = JevAnswer(type: "noul", noul: kind == "nan" ? .nan : 1.1,
                choice: nil, score: nil, probabilities: nil, confidence: nil)
            }
            return JevResponse(model: "offline", answers: answers, usage: nil)
        }
        let vision = PlannerTests.Base()
        let fallback = JevVisionFallbackDecider(primary: primary, vision: vision,
            observer: VisionFallbackTests.Observer([observation]))
        let result = await fallback.decide(observation: observation, state: proposedState(observation), apps: [], textCandidates: [])
        #expect(result.failure == "Missing or invalid risky judgment")
        #expect(fallback.requests == 0 && vision.states.isEmpty)
    }

    @Test func exclusionsSurviveRenumberingTicksAndABAReturnButChangedOwnerAllowsReconsideration() async throws {
        let base = PlannerTests.Base()
        base.decision = Self.weakFinish(); base.decision.recovery = .unresolvedVision
        let planner = JevPlannerDecider(base: base, executable: "/unused")
        var requests: [[String: Any]] = []
        let actions = ["owner:action1", "renumbered:action2", "returned:action1", "returned:action1"]
        planner.requestOverride = { input in
            requests.append(try #require(JSONSerialization.jsonObject(with: input) as? [String: Any]))
            return try reply(input, action: actions[requests.count - 1])
        }
        let fixture = PlannerRouteTests()
        #expect(await fixture.decide(planner, fixture.observation("A")).recovery == .reobserve)
        let changedIDs = fixture.observation("A", id: "renumbered", tick: "999")
        #expect(await fixture.decide(planner, changedIDs).recovery == .reobserve)
        let offered = try #require(requests[1]["offered_actions"] as? [[String: Any]])
        #expect(!offered.contains { $0["target_key"] as? String == "renumbered:action1" })
        #expect(base.states[1].unverifiedVisionFeedback?.judgment.diagnosis == .alreadySatisfied)
        #expect(base.states[1].history.isEmpty && base.states[1].verifiedFacts == nil)
        let action = "returned:action1"
        let rejected = await fixture.decide(planner, fixture.observation("A", id: "returned", tick: "1000"))
        #expect(rejected.failure?.contains("unoffered or excluded proposal") == true)
        #expect(base.states.count == 2)
        base.decision = .init(action: .tap, confidence: 1, done: 0, blocked: 0, risky: 0, targetId: action)
        let fresh = await fixture.decide(planner, fixture.observation("B", id: "returned", tick: "1001"))
        #expect(fresh.targetId == action && fresh.executionToken != nil && fresh.failure == nil)
        #expect(base.states[2].unverifiedVisionFeedback == nil)
    }

    @Test func thirdRecoveryExhaustsBeforeAnotherPlannerOrModelCycleEvenAfterAcknowledgment() async throws {
        let base = PlannerTests.Base()
        base.decision = Self.weakFinish(); base.decision.recovery = .unresolvedVision
        let planner = JevPlannerDecider(base: base, executable: "/unused")
        var requests = 0
        planner.requestOverride = { input in requests += 1; return try reply(input, action: "owner:action1") }
        let fixture = PlannerRouteTests()
        for value in ["A", "B", "C"] {
            let recovered = await fixture.decide(planner, fixture.observation(value))
            #expect(recovered.recovery == .reobserve && recovered.executionToken == nil)
            planner.executionDidResolve(.acknowledged(nil))
        }
        let stopped = await fixture.decide(planner, fixture.observation("D"))
        #expect(stopped.failure == "Vision recovery limit reached")
        #expect(requests == 3 && base.states.count == 3)
    }

    @Test(arguments: ["stop", "complete", "minority", "risky", "blocked", "malformed", "api", "stale", "plannerless"])
    func failedOrUnsafeVisionCannotRecover(kind: String) async {
        let initial = PlannerTests.Base(), vision = PlannerTests.Base()
        vision.decision = Self.weakFinish()
        let observation = PlannerRouteTests().observation("A")
        var state = proposedState(observation)
        var observations = [observation, observation]
        switch kind {
        case "stop", "complete": vision.decision.originalGoalStatus = kind
        case "minority": vision.decision.originalGoalStatusProbability = 0.49
        case "risky": vision.decision.risky = 0.6
        case "blocked": vision.decision.blocked = 0.6
        case "malformed": vision.decision.visionJudgment = nil
        case "api": vision.decision = .failed("HTTP 429")
        case "stale": observations[1] = PlannerRouteTests().observation("B")
        case "plannerless": state.plannerContext = nil
        default: break
        }
        let fallback = JevVisionFallbackDecider(primary: initial, vision: vision,
            observer: VisionFallbackTests.Observer(observations))
        let result = await fallback.decide(observation: observation, state: state, apps: [], textCandidates: [])
        #expect(result.recovery == nil && fallback.requests == 1)
        if ["minority", "malformed", "api", "stale", "plannerless"].contains(kind) { #expect(result.failure != nil) }
        if kind == "api" { #expect(result.failure == "HTTP 429") }
        if kind == "stale" { #expect(result.failure == "Observation changed during Clef vision: named-action owner changed or became ambiguous") }
        if kind == "stop" || kind == "complete" { #expect(result.originalGoalStatus == kind) }
        if kind == "risky" { #expect(result.risky == 0.6) }
        if kind == "blocked" { #expect(result.blocked == 0.6) }
    }

    @Test func proposalFreshnessIsCheckedWhenBothClassifiersSelectedAnotherTarget() async {
        var old = PlannerRouteTests().observation("A")
        old.elements.append(.init(id: "other", role: "button", label: "Other", value: "same", point: .zero))
        var changed = PlannerRouteTests().observation("B")
        changed.elements.append(old.elements.last!)
        let primary = PlannerTests.Base(), vision = PlannerTests.Base()
        primary.decision.targetId = "other"
        vision.decision = Self.weakFinish()
        let fallback = JevVisionFallbackDecider(primary: primary, vision: vision,
            observer: VisionFallbackTests.Observer([old, changed]))
        let result = await fallback.decide(observation: old, state: proposedState(old), apps: [], textCandidates: [])
        #expect(result.failure == "Observation changed during Clef vision: named-action owner changed or became ambiguous")
        #expect(result.recovery == nil)
    }

    @Test(arguments: ["plain", "compact", "focused", "no_proposal", "bad_diagnostic", "bad_safety", "weak_diagnostic"])
    func diagnosticIsConditionalAndValidatedInTheSameRequest(mode: String) async throws {
        let observation = PlannerRouteTests().observation("A")
        var state = proposedState(observation)
        if mode == "no_proposal" { state.plannerContext = nil }
        let client = try VPhoneJevClient(apiKey: "offline-fixture")
        var decider = JevModelDecider(client: client, compactRequests: mode == "compact",
            focusedRequests: mode == "focused", includeVisionDiagnostic: true)
        var captured: [String: JevQuestion] = [:]
        decider.requestOverride = { _, questions in
            captured = questions
            let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(questions)) as? [String: [String: Any]])
            var answers: [String: JevAnswer] = [:]
            for (head, question) in encoded {
                if question["type"] as? String == "choice" {
                    let choices = try #require(question["criteria"] as? [String: Any])
                    let selected = head == JevQuestions.action ? "finish"
                        : head == JevQuestions.originalGoalStatus ? "continue"
                        : head == JevQuestions.visionDiagnosis ? "alreadySatisfied" : choices.keys.sorted()[0]
                    answers[head] = Self.choice(selected, options: Array(choices.keys))
                } else {
                    answers[head] = JevAnswer(type: "noul", noul: 0.1, choice: nil, score: nil, probabilities: nil, confidence: nil)
                }
            }
            if mode == "bad_diagnostic" { answers[JevQuestions.visionDiagnosis] = Self.choice("invented", options: ["invented", "unknown"]) }
            if mode == "bad_safety" { answers[JevQuestions.risky] = nil }
            if mode == "weak_diagnostic" {
                answers[JevQuestions.visionDiagnosis] = Self.choice("stillNeeded",
                    options: JevVisionJudgment.Diagnosis.allCases.map(\.rawValue), confidence: 0.1105, probability: 0.4357)
            }
            return JevResponse(model: "offline", answers: answers, usage: nil)
        }
        let result = await decider.decide(observation: observation, state: state, apps: [], textCandidates: [])
        if mode == "bad_diagnostic" { #expect(result.failure == "Missing or invalid Clef visual diagnosis") }
        else if mode == "bad_safety" { #expect(result.failure == "Missing or invalid risky judgment") }
        else if mode == "no_proposal" {
            #expect(result.action == .finish && result.failure == nil && result.visionJudgment == nil)
            #expect(captured[JevQuestions.visionDiagnosis] == nil)
        } else if mode == "weak_diagnostic" {
            #expect(result.visionJudgment?.diagnosis == .stillNeeded && result.failure == nil)
            #expect(result.visionJudgment?.confidence == 0.1105 && result.visionJudgment?.probability == 0.4357)
        } else {
            #expect(result.visionJudgment?.diagnosis == .alreadySatisfied && result.failure == nil)
            #expect(result.visionJudgment?.confidence == 0.8 && result.visionJudgment?.probability == 0.8)
            #expect(captured[JevQuestions.action] != nil && captured[JevQuestions.visionDiagnosis] != nil)
        }
    }

    @Test(arguments: [false, true])
    func agentStopsUnconsumedRecoveryAndHandlesFailureBeforeYield(withFailure: Bool) async throws {
        let base = PlannerTests.Base()
        base.decision = Self.weakFinish()
        base.decision.recovery = withFailure ? .reobserve : .unresolvedVision
        if withFailure { base.decision.failure = "Request failed" }
        let screens = Screens(), inputs = FormValidationTests.Inputs()
        let result = try await VPhoneJevAgent(goal: "Inspect selection", decider: base,
            provider: screens, actuator: inputs, mode: .unattended).run()
        guard case let .stopped(reason, steps) = result else { Issue.record("Expected fail-closed stop"); return }
        #expect(reason == (withFailure ? "Request failed" : "Vision recovery needs a planner"))
        #expect(steps == 1 && screens.reads == 1 && inputs.taps.isEmpty)
    }
}
