@testable import vphone_cli
import CoreGraphics
import Testing

@MainActor
struct TargetFreshnessTests {
    @Test(arguments: ["same", "value", "app", "context", "label", "document", "incomplete", "duplicate"])
    func nativeReferenceRequiresEquivalentCapture(mode: String) {
        let target = JevElement(id: "e1", role: "switch", label: "Enabled", value: "off", point: .zero)
        var screen = JevObservation(foregroundApp: "App", elements: mode == "duplicate" ? [target, target] : [target],
            bounds: CGRect(x: 0, y: 0, width: 400, height: 800), source: .accessibility)
        if mode == "document" { screen.documentTitle = "Page" }
        if mode == "incomplete" { screen.completenessIssue = "Missing remote content" }
        let receipt: [String: Any] = ["token": "one-use", "app": mode == "app" ? "Other" : "App",
            "context": mode == "context" ? "Other row" : "", "tree": [
                "XC_kAXXCAttributeLabel": mode == "label" ? "Other" : "Enabled",
                "XC_kAXXCAttributeValue": mode == "value" ? "1" : "0",
                "XC_kAXXCAttributeAutomationType": 40]]
        #expect(JevSimulatorObserver.scopedToken(for: target, receipt: receipt, observation: screen)
            == (mode == "same" ? "one-use" : nil))
    }

    @Test(arguments: ["moved", "value", "app", "document", "ambiguous"])
    func selectedTargetUsesNarrowReadButKeepsIdentityGuards(mode: String) async throws {
        final class Screens: JevObservationProvider {
            let mode: String
            var validationReads = 0
            init(_ mode: String) { self.mode = mode }
            func screen(_ elements: [JevElement], app: String = "App", document: String = "Page") -> JevObservation {
                JevObservation(foregroundApp: app, elements: elements,
                    bounds: CGRect(x: 0, y: 0, width: 400, height: 800), source: .accessibility,
                    documentTitle: document, validatesTargetsAtExecution: true)
            }
            func observe() async throws -> JevObservation {
                screen([JevElement(id: "e1", role: "switch", label: "Enabled", value: "off", point: .zero)])
            }
            func observeForValidation(of target: JevElement) async throws -> JevObservation {
                validationReads += 1
                let current = JevElement(id: "e2", role: "switch", label: "Enabled",
                    value: mode == "value" ? "on" : "off", point: CGPoint(x: 40, y: 80))
                return screen(mode == "ambiguous" ? [current, current] : [current],
                    app: mode == "app" ? "Other" : "App", document: mode == "document" ? "Other" : "Page")
            }
        }
        struct Chooser: JevDecider {
            let name = "test"
            func decide(observation: JevObservation, state: JevState,
                        apps: [(bundleId: String, name: String)], textCandidates: [String]) async -> JevStepDecision {
                JevStepDecision(action: .tap, confidence: 1, done: 0, blocked: 0, risky: 0, actionProbability: 1, targetId: "e1")
            }
        }
        final class Input: JevActuator {
            var points: [CGPoint] = []
            func tap(at point: CGPoint) async throws { points.append(point) }
            func scroll(reveal: JevScrollDirection) async throws { Issue.record("Unexpected scroll") }
            func drag(at point: CGPoint, up: Bool) async throws { Issue.record("Unexpected drag") }
            func type(_ text: String) async throws { Issue.record("Unexpected typing") }
            func pressHome() async throws { Issue.record("Unexpected home") }
            func launch(bundleId: String) async throws { Issue.record("Unexpected launch") }
        }
        var policy = VPhoneJevAgent.Policy.default
        policy.maxSteps = 1; policy.settleMilliseconds = 0
        let screens = Screens(mode), input = Input()
        _ = try await VPhoneJevAgent(goal: "Enable it", decider: Chooser(), provider: screens,
            actuator: input, policy: policy).run()
        #expect(screens.validationReads == 1)
        #expect(input.points == (mode == "moved" ? [CGPoint(x: 40, y: 80)] : []))
    }
}
