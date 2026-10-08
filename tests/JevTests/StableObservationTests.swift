@testable import vphone_cli
import CoreGraphics
import Foundation
import Testing

@MainActor
struct StableObservationTests {
    final class Phone: JevObservationProvider, JevSemanticActuator {
        var reads = 0
        var phaseReads = 0
        var phase = "Initial"
        var transientReads = 2
        var changesForever = false
        var inputs = 0
        var empty = false
        var delayFirstRead = false
        var lastTransitionAt = ProcessInfo.processInfo.systemUptime

        func observe() async throws -> JevObservation {
            reads += 1
            if reads == 1, delayFirstRead { try await Task.sleep(nanoseconds: 2_600_000_000) }
            phaseReads += 1
            let transient = phaseReads <= transientReads
            if phaseReads == transientReads + 1 { lastTransitionAt = ProcessInfo.processInfo.systemUptime }
            let label = changesForever ? "Changing \(reads)" : transient ? "Outgoing and incoming \(phaseReads)" : phase
            var observation = JevObservation(foregroundApp: "Viewer", elements: empty ? [] : [
                JevElement(id: "action", role: "button", label: "Continue", value: nil, point: .zero),
                JevElement(id: "content-\(reads)", role: "statictext", label: label, value: nil, point: .zero),
            ], bounds: CGRect(x: 0, y: 0, width: 400, height: 800), source: .accessibility,
                validatesTargetsAtExecution: true,
                nearbyElements: [.init(id: "hidden", role: "statictext", label: "Nearby result", value: "99", visibility: "below; not actionable")],
                layoutSignature: label)
            observation.documentTitle = "Document"
            return observation
        }
        func transition(_ name: String) { phase = name; phaseReads = 0 }
        func act() { inputs += 1; transition("Result") }
        func press(_ element: JevElement) async throws { act() }
        func scroll(reveal: JevScrollDirection) async throws { act() }
        func launch(bundleId: String) async throws { act() }
        func tap(at point: CGPoint) async throws { Issue.record("Unexpected coordinate tap") }
        func drag(at point: CGPoint, up: Bool) async throws { Issue.record("Unexpected drag") }
        func type(_ text: String) async throws { Issue.record("Unexpected type") }
        func pressHome() async throws { Issue.record("Unexpected home") }
        func adjust(_ element: JevElement, up: Bool) async throws { Issue.record("Unexpected adjust") }
        func select(_ value: String, on element: JevElement) async throws { Issue.record("Unexpected select") }
        func fill(_ text: String, on element: JevElement) async throws { Issue.record("Unexpected fill") }
    }

    final class Decisions: JevDecider {
        let name = "stable screen fixture"
        let phone: Phone
        var firstAction: JevAction = .finish
        var changeDuringDecision = false
        var observations: [JevObservation] = []
        var quietDurations: [Double] = []
        init(_ phone: Phone) { self.phone = phone }
        func decide(observation: JevObservation, state: JevState,
                    apps: [(bundleId: String, name: String)], textCandidates: [String]) async -> JevStepDecision {
            observations.append(observation)
            quietDurations.append(ProcessInfo.processInfo.systemUptime - phone.lastTransitionAt)
            if changeDuringDecision, observations.count == 1 { phone.transition("Changed parent") }
            let action = observations.count == 1 ? firstAction : .finish
            return .init(action: action, confidence: 1, done: action == .finish ? 1 : 0,
                blocked: 0, risky: 0, actionProbability: 1, targetId: "action", appId: "example.viewer")
        }
    }

    func policy() -> VPhoneJevAgent.Policy {
        var policy = VPhoneJevAgent.Policy.default
        policy.maxSteps = 3
        policy.settleMilliseconds = 0
        policy.settlePollMilliseconds = 3
        policy.settleQuietMilliseconds = 20
        policy.settleTimeoutMilliseconds = 2500
        return policy
    }

    @Test(arguments: ["tap", "open_app", "scroll_down"])
    func initialAndPostInputTreesMustRemainQuiet(action: String) async throws {
        let phone = Phone(), decider = Decisions(phone)
        decider.firstAction = try #require(JevAction(rawValue: action))
        let agent = VPhoneJevAgent(goal: "Show the result", decider: decider,
            provider: phone, actuator: phone, policy: policy())
        #expect(try await agent.run().succeeded)
        #expect(phone.inputs == 1)
        #expect(decider.observations.map { $0.elements[1].label } == ["Initial", "Result"])
        #expect(decider.quietDurations.allSatisfy { $0 >= 0.020 })
        let evidence = try #require(agent.completionAudit)
        #expect(evidence.originalGoal == "Show the result")
        #expect(evidence.documentTitle == "Document")
        #expect(evidence.visibleElements.map(\.label) == ["Continue", "Result"])
        #expect(evidence.visibleElements[1].id == "content-\(phone.reads)")
        #expect(evidence.judgment.doneThreshold == 0.8)
        #expect(evidence.judgment.finishAcceptedThreshold == 0.5)
    }

    @Test(arguments: [0, 1, 2])
    func perpetualTransitionStopsBeforeAnyJudgmentOrInput(retries: Int) async throws {
        let phone = Phone(), decider = Decisions(phone)
        phone.changesForever = true
        var policy = policy()
        policy.maxSteps = 1
        policy.settleTimeoutMilliseconds = 30
        policy.maxSettleRetries = retries
        let agent = VPhoneJevAgent(goal: "Show result", decider: decider, provider: phone, actuator: phone, policy: policy)
        var observationSteps: [Int] = []
        agent.onTiming = { step, stage, _ in
            if stage == "observe and settle" { observationSteps.append(step) }
        }
        let outcome = try await agent.run()
        guard case let .stopped(reason, steps) = outcome else { Issue.record("Expected settle failure"); return }
        #expect(reason.contains("did not settle"))
        #expect(steps == 0)
        #expect(observationSteps == Array(repeating: 1, count: retries + 1))
        #expect(decider.observations.isEmpty)
        #expect(phone.inputs == 0)
        #expect(agent.completionAudit == nil)
    }

    @Test func slowInitialReadCanRecoverWithoutInputOrJudgingTheTimedOutObservation() async throws {
        let phone = Phone(), decider = Decisions(phone)
        phone.delayFirstRead = true
        phone.transientReads = 0
        var policy = policy()
        policy.maxSteps = 1
        let agent = VPhoneJevAgent(goal: "Inspect final view", decider: decider,
            provider: phone, actuator: phone, policy: policy)
        let outcome = try await agent.run()
        guard case let .achieved(steps) = outcome else { Issue.record("Expected recovery within the first step"); return }
        #expect(steps == 1)
        #expect(decider.observations.count == 1)
        #expect(phone.inputs == 0)
        #expect(agent.completionAudit?.visibleElements.last?.label == "Initial")
    }

    @Test func survivingTargetCannotActOnAChangedParentScreen() async throws {
        let phone = Phone(), decider = Decisions(phone)
        decider.firstAction = .tap
        decider.changeDuringDecision = true
        let agent = VPhoneJevAgent(goal: "Inspect final view", decider: decider,
            provider: phone, actuator: phone, policy: policy())
        #expect(try await agent.run().succeeded)
        #expect(phone.inputs == 0)
        #expect(decider.observations.map { $0.elements[1].label } == ["Initial", "Changed parent"])
        #expect(agent.completionAudit?.visibleElements.last?.label == "Changed parent")
    }

    @Test func completionChangesAreSettledAndRejudged() async throws {
        let phone = Phone(), decider = Decisions(phone)
        decider.changeDuringDecision = true
        let agent = VPhoneJevAgent(goal: "Inspect final view", decider: decider,
            provider: phone, actuator: phone, policy: policy())
        #expect(try await agent.run().succeeded)
        #expect(decider.observations.map { $0.elements[1].label } == ["Initial", "Changed parent"])
        #expect(decider.quietDurations.allSatisfy { $0 >= 0.020 })
        #expect(agent.completionAudit?.visibleElements.last?.label == "Changed parent")
        #expect(phone.inputs == 0)
    }

    @Test func emptyVisibleTreeCannotCertifyNearbyEvidence() async throws {
        let phone = Phone(), decider = Decisions(phone)
        phone.empty = true
        let agent = VPhoneJevAgent(goal: "Inspect result", decider: decider, provider: phone, actuator: phone)
        #expect(try await !agent.run().succeeded)
        #expect(agent.completionAudit == nil)
        #expect(phone.inputs == 0)
    }
}
