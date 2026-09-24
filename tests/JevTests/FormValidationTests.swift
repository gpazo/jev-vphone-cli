@testable import vphone_cli
import CoreGraphics
import Testing

@MainActor
struct FormValidationTests {
    final class Screens: JevObservationProvider {
        var reads = 0
        var changeOnValidation = false
        var incompleteReads: Set<Int> = []
        func observe() async throws -> JevObservation {
            reads += 1
            var observation = JevObservation(foregroundApp: "Form", elements: [
                JevElement(id: "save", role: "button", label: "Save", value: nil, point: CGPoint(x: 30, y: 40)),
                JevElement(id: "edit", role: "button", label: "Edit field", value: nil, point: CGPoint(x: 30, y: 80)),
                JevElement(id: "field", role: "textfield", label: "Value",
                    value: changeOnValidation && reads > 1 ? "changed" : "original", point: CGPoint(x: 30, y: 120)),
            ], bounds: CGRect(x: 0, y: 0, width: 400, height: 800), source: .accessibility)
            if incompleteReads.contains(reads) { observation.completenessIssue = "Missing remote fields" }
            return observation
        }
    }
    final class Decisions: JevDecider {
        let name = "test"
        var readiness = "mismatch"
        var probability = 0.9
        var done = 0.0
        var states: [JevState] = []
        var repair = false
        func decide(observation: JevObservation, state: JevState,
                    apps: [(bundleId: String, name: String)], textCandidates: [String]) async -> JevStepDecision {
            states.append(state)
            let correcting = repair && states.count > 1
            return JevStepDecision(action: .tap, confidence: 1, done: done, blocked: 0, risky: 0,
                targetId: correcting ? "edit" : "save", tapReadiness: correcting ? "not_applicable" : readiness,
                readinessProbability: probability)
        }
    }
    final class Inputs: JevSemanticActuator {
        var taps: [CGPoint] = []
        func press(_ element: JevElement) async throws { taps.append(element.point) }
        func adjust(_ element: JevElement, up: Bool) async throws { Issue.record("Unexpected adjust") }
        func select(_ value: String, on element: JevElement) async throws { Issue.record("Unexpected select") }
        func fill(_ text: String, on element: JevElement) async throws { Issue.record("Unexpected fill") }
        func tap(at point: CGPoint) async throws { taps.append(point) }
        func scroll(reveal: JevScrollDirection) async throws { Issue.record("Unexpected scroll") }
        func drag(at point: CGPoint, up: Bool) async throws { Issue.record("Unexpected drag") }
        func type(_ text: String) async throws { Issue.record("Unexpected type") }
        func pressHome() async throws { Issue.record("Unexpected home") }
        func launch(bundleId: String) async throws { Issue.record("Unexpected launch") }
    }

    @Test(arguments: ["mismatch", "insufficient_evidence", "ready"])
    func rejectsWrongMissingAndUncertainForms(readiness: String) async throws {
        let decider = Decisions(); decider.readiness = readiness
        decider.done = 0.95 // A contradictory done head must not bypass this gate.
        if readiness == "ready" { decider.probability = 0.5 }
        let inputs = Inputs()
        var policy = VPhoneJevAgent.Policy.default; policy.maxSteps = 1
        let agent = VPhoneJevAgent(goal: "Save the requested value", decider: decider,
            provider: Screens(), actuator: inputs, policy: policy)
        #expect(try await !agent.run().succeeded)
        #expect(inputs.taps.isEmpty)
    }

    @Test func changedFormValueInvalidatesReadySaveEvenWhenSaveButtonIsUnchanged() async throws {
        let screens = Screens(); screens.changeOnValidation = true
        let decider = Decisions(); decider.readiness = "ready"
        let inputs = Inputs()
        var policy = VPhoneJevAgent.Policy.default; policy.maxSteps = 1
        let agent = VPhoneJevAgent(goal: "Save the requested value", decider: decider,
            provider: screens, actuator: inputs, policy: policy)
        #expect(try await !agent.run().succeeded)
        #expect(screens.reads == 2)
        #expect(inputs.taps.isEmpty)
    }

    @Test(arguments: [0, 1, 2])
    func readySaveRequiresCompleteUnchangedEvidence(incompleteRead: Int) async throws {
        let screens = Screens(); screens.incompleteReads = [incompleteRead]
        let decider = Decisions(); decider.readiness = "ready"
        let inputs = Inputs()
        var policy = VPhoneJevAgent.Policy.default; policy.maxSteps = 1
        let agent = VPhoneJevAgent(goal: "Save the requested value", decider: decider,
            provider: screens, actuator: inputs, policy: policy)
        #expect(try await !agent.run().succeeded) // No post-save success evidence yet.
        #expect(inputs.taps.count == (incompleteRead == 0 ? 1 : 0))
    }

    @Test func rejectionFeedsRepairWithoutInventingAnExecutedAction() async throws {
        let decider = Decisions(); decider.repair = true
        let inputs = Inputs()
        var policy = VPhoneJevAgent.Policy.default
        policy.maxSteps = 2; policy.settleTimeoutMilliseconds = 0; policy.settleMilliseconds = 0
        let agent = VPhoneJevAgent(goal: "Save the requested value", decider: decider,
            provider: Screens(), actuator: inputs, policy: policy)
        #expect(try await !agent.run().succeeded)
        #expect(decider.states.count == 2)
        #expect(decider.states[1].inputRejection?.contains("mismatch") == true)
        #expect(decider.states[1].history.isEmpty)
        #expect(inputs.taps == [CGPoint(x: 30, y: 80)])
    }
}
