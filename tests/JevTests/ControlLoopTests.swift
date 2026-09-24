@testable import vphone_cli
import CoreGraphics
import Testing

@MainActor
struct ControlLoopTests {
    final class Phone: JevObservationProvider, JevSemanticActuator {
        var value = "30"
        var inputs: [String] = []
        var exposeProgress = false
        func observe() async throws -> JevObservation {
            var wheel = JevElement(id: "wheel", role: "picker", label: "Amount", value: value, point: .zero)
            wheel.pickerOptions = ["15", "30", "45", "60"]
            var elements = [wheel]
            if exposeProgress {
                elements.append(JevElement(id: "count", role: "statictext", label: "Count", value: String(inputs.count), point: .zero))
            }
            return JevObservation(foregroundApp: "Any app", elements: elements,
                bounds: CGRect(x: 0, y: 0, width: 400, height: 800), source: .accessibility,
                validatesTargetsAtExecution: true, supportsPickerSelection: true)
        }
        func select(_ value: String, on element: JevElement) async throws { self.value = value; inputs.append(value) }
        func press(_ element: JevElement) async throws { Issue.record("Unexpected press") }
        func fill(_ text: String, on element: JevElement) async throws { Issue.record("Unexpected fill") }
        func adjust(_ element: JevElement, up: Bool) async throws { Issue.record("Unexpected adjust") }
        func tap(at point: CGPoint) async throws { Issue.record("Unexpected tap") }
        func scroll(reveal: JevScrollDirection) async throws { Issue.record("Unexpected scroll") }
        func drag(at point: CGPoint, up: Bool) async throws { Issue.record("Unexpected drag") }
        func type(_ text: String) async throws { Issue.record("Unexpected type") }
        func pressHome() async throws { Issue.record("Unexpected home") }
        func launch(bundleId: String) async throws { Issue.record("Unexpected launch") }
    }
    final class Decisions: JevDecider {
        let name = "scripted decision regression"
        var values: [String]? = nil
        var calls = 0
        var risk = 0.01
        var operationConfidence = 0.99
        var targetConfidence = 0.99
        func decide(observation: JevObservation, state: JevState,
                    apps: [(bundleId: String, name: String)], textCandidates: [String]) async -> JevStepDecision {
            calls += 1
            if let values, calls > values.count {
                return JevStepDecision(action: .finish, confidence: 1, done: 1, blocked: 0, risky: 0, actionProbability: 1)
            }
            return JevStepDecision(action: .setPickerValue, confidence: operationConfidence, done: 0, blocked: 0,
                risky: risk, actionProbability: 1, targetConfidence: targetConfidence, targetProbability: 0.55,
                targetId: "wheel", pickerValue: values?[calls - 1] ?? (observation.elements[0].value == "30" ? "15" : "30"))
        }
    }
    func agent(_ phone: Phone, _ decisions: Decisions, steps: Int = 25, cycles: Bool = true) -> VPhoneJevAgent {
        var policy = VPhoneJevAgent.Policy.default
        policy.maxSteps = steps; policy.settleTimeoutMilliseconds = 0; policy.settleMilliseconds = 0
        if !cycles { policy.maxCycleLength = 0 }
        return VPhoneJevAgent(goal: "Set the requested amount: 15, 30, 45, 60", decider: decisions,
                             provider: phone, actuator: phone, policy: policy)
    }

    @Test func stopsReversalsBeforeAThirdCycleAndDoesNotClaimSuccess() async throws {
        let phone = Phone(), decisions = Decisions()
        let outcome = try await agent(phone, decisions).run()
        guard case let .stopped(reason, steps) = outcome else { Issue.record("Expected a bounded stop"); return }
        #expect(reason.contains("2-action cycle"))
        #expect(steps == 5)
        #expect(decisions.calls == 5)
        #expect(phone.inputs == ["15", "30", "15", "30"])
        // Identical observation/decision/input fixtures; disable only the new guard.
        let baselinePhone = Phone(), baselineDecisions = Decisions()
        let baseline = try await agent(baselinePhone, baselineDecisions, cycles: false).run()
        guard case .exhausted(steps: 25) = baseline else { Issue.record("Expected the old budget stop"); return }
        #expect(baselinePhone.inputs.count == 25)
        #expect(baselineDecisions.calls == 25)
    }

    @Test(arguments: [["15", "30", "45"], ["15", "30", "15", "30", "45"], ["45", "60"]])
    func backtrackingDifferentExitsAndMonotonicChangesRemainAvailable(values: [String]) async throws {
        let phone = Phone(), decisions = Decisions(); decisions.values = values
        #expect(try await agent(phone, decisions).run().succeeded)
        #expect(phone.inputs == values)
    }

    @Test func visibleProgressPreventsFalseLoopDetection() async throws {
        let phone = Phone(), decisions = Decisions(); phone.exposeProgress = true
        let outcome = try await agent(phone, decisions, steps: 7).run()
        #expect(!outcome.succeeded)
        #expect(phone.inputs.count == 7)
    }

    @Test(arguments: [true, false])
    func eitherUncertainSelectedHeadStopsConsequentialInput(target: Bool) async throws {
        let phone = Phone(), decisions = Decisions(); decisions.risk = 0.2
        if target { decisions.targetConfidence = 0.2 } else { decisions.operationConfidence = 0.2 }
        let outcome = try await agent(phone, decisions, steps: 1).run()
        guard case let .stopped(reason, _) = outcome else { Issue.record("Expected confidence stop"); return }
        #expect(reason.contains("confidence 0.20"))
        #expect(phone.inputs.isEmpty)
    }

    @Test func uncertainBenignChoiceStillExecutesAndLogsBothHeads() async throws {
        let phone = Phone(), decisions = Decisions(); decisions.targetConfidence = 0.2
        let controller = agent(phone, decisions, steps: 1)
        var reports: [VPhoneJevAgent.Step] = []; controller.onStep = { reports.append($0) }
        _ = try await controller.run()
        #expect(phone.inputs == ["15"])
        #expect(reports.last?.actionConfidence == 0.99)
        #expect(reports.last?.targetConfidence == 0.2)
        #expect(reports.last?.targetProbability == 0.55)
    }

    @Test func targetUncertaintyUsesExistingConfirmationGate() async throws {
        let phone = Phone(), decisions = Decisions(); decisions.risk = 0.2; decisions.targetConfidence = 0.7
        let controller = agent(phone, decisions, steps: 1)
        var confirmations: [String] = []
        controller.confirm = { confirmations.append($0); return false }
        #expect(try await !controller.run().succeeded)
        #expect(confirmations.count == 1)
        #expect(confirmations.first?.contains("confidence 0.70") == true)
        #expect(phone.inputs.isEmpty)
    }
}
