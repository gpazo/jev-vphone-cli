@testable import vphone_cli
import CoreGraphics
import Foundation
import Testing

@MainActor
struct PlannerExecutionTests {
    final class Screens: JevObservationProvider {
        var reads = 0
        let change: Bool
        init(change: Bool) { self.change = change }
        func observe() async throws -> JevObservation {
            reads += 1
            return JevObservation(foregroundApp: change && reads > 1 ? "Other" : "Editor", elements: [],
                bounds: CGRect(x: 0, y: 0, width: 400, height: 800), source: .accessibility)
        }
    }
    final class Chooser: JevDecider {
        let name = "guarded fixture"
        let token = UUID()
        var events: [JevExecutionEvent] = []
        func executionDidResolve(_ event: JevExecutionEvent) { events.append(event) }
        func decide(observation: JevObservation, state: JevState, apps: [(bundleId: String, name: String)],
                    textCandidates: [String]) async -> JevStepDecision {
            JevStepDecision(action: .pressHome, confidence: 1, done: 0, blocked: 0, risky: 0,
                executionToken: token, observationGuard: .init(observation: observation, target: nil, owner: nil))
        }
    }
    final class Inputs: JevActuator {
        var homes = 0
        var fail = false
        func pressHome() async throws {
            if fail { throw JevStaleTargetError(reason: "fixture stale") }
            homes += 1
        }
        func tap(at point: CGPoint) async throws { Issue.record("Unexpected tap") }
        func scroll(reveal: JevScrollDirection) async throws { Issue.record("Unexpected scroll") }
        func drag(at point: CGPoint, up: Bool) async throws { Issue.record("Unexpected drag") }
        func type(_ text: String) async throws { Issue.record("Unexpected type") }
        func launch(bundleId: String) async throws { Issue.record("Unexpected launch") }
    }

    @Test(arguments: ["acknowledged", "stale_observation", "stale_input", "dry_run"])
    func acknowledgmentOccursOnlyAfterConfirmedExecution(mode: String) async throws {
        let screens = Screens(change: mode == "stale_observation"), input = Inputs(), decider = Chooser()
        input.fail = mode == "stale_input"
        var policy = VPhoneJevAgent.Policy.default
        policy.maxSteps = 1; policy.settleMilliseconds = 0
        _ = try await VPhoneJevAgent(goal: "Leave the editor", decider: decider, provider: screens,
            actuator: input, policy: policy, mode: mode == "dry_run" ? .dryRun : .unattended).run()
        #expect(input.homes == (mode == "acknowledged" ? 1 : 0))
        #expect(screens.reads == (mode == "dry_run" ? 1 : 2))
        #expect(decider.events.count == 1)
        switch decider.events.first {
        case let .acknowledged(token): #expect(mode == "acknowledged" && token == decider.token)
        case let .rejected(token, _): #expect(mode != "acknowledged" && token == decider.token)
        default: Issue.record("Missing execution event")
        }
    }

    @Test func nonTapControlRebindsToFreshElementBeforeInput() async throws {
        final class Fields: JevObservationProvider {
            var reads = 0
            func observe() async throws -> JevObservation {
                reads += 1
                return JevObservation(foregroundApp: "Editor", elements: [
                    JevElement(id: reads == 1 ? "old" : "fresh", role: "textfield", label: "Title", value: "Original",
                        point: CGPoint(x: Double(reads) * 10, y: 20))
                ], bounds: CGRect(x: 0, y: 0, width: 400, height: 800), source: .accessibility)
            }
        }
        struct Fill: JevDecider {
            let name = "fill fixture"
            func decide(observation: JevObservation, state: JevState, apps: [(bundleId: String, name: String)],
                        textCandidates: [String]) async -> JevStepDecision {
                .init(action: .typeText, confidence: 1, done: 0, blocked: 0, risky: 0, targetId: "old", textId: "t1",
                    executionToken: UUID(), observationGuard: .init(observation: observation, target: observation.elements[0], owner: nil))
            }
        }
        final class Input: JevSemanticActuator {
            var filledID: String?
            func fill(_ text: String, on element: JevElement) async throws { filledID = element.id; #expect(text == "New title") }
            func press(_ element: JevElement) async throws { Issue.record("Unexpected press") }
            func adjust(_ element: JevElement, up: Bool) async throws { Issue.record("Unexpected adjust") }
            func select(_ value: String, on element: JevElement) async throws { Issue.record("Unexpected select") }
            func tap(at point: CGPoint) async throws { Issue.record("Unexpected tap") }
            func scroll(reveal: JevScrollDirection) async throws { Issue.record("Unexpected scroll") }
            func drag(at point: CGPoint, up: Bool) async throws { Issue.record("Unexpected drag") }
            func type(_ text: String) async throws { Issue.record("Unexpected type") }
            func pressHome() async throws { Issue.record("Unexpected home") }
            func launch(bundleId: String) async throws { Issue.record("Unexpected launch") }
        }
        let fields = Fields(), input = Input()
        var policy = VPhoneJevAgent.Policy.default; policy.maxSteps = 1
        _ = try await VPhoneJevAgent(goal: "Enter \"New title\"", decider: Fill(), provider: fields,
            actuator: input, policy: policy, mode: .unattended).run()
        #expect(fields.reads == 2 && input.filledID == "fresh")
    }

    @Test(arguments: [false, true])
    func plannerInputSettlesTransientLayoutWhileOrdinaryNativeInputKeepsFastPath(plannerBound: Bool) async throws {
        final class Layouts: JevObservationProvider {
            var reads = 0
            func observe() async throws -> JevObservation {
                reads += 1
                let initial = reads <= 2, stable = reads >= 4
                var elements = [JevElement(id: "advance", role: "button", label: "Advance",
                    value: initial ? "Before" : "After", point: .zero)]
                if stable { elements.append(.init(id: "toolbar", role: "statictext", label: "Toolbar", value: nil, point: .zero)) }
                return JevObservation(foregroundApp: "Viewer", elements: elements,
                    bounds: CGRect(x: 0, y: 0, width: 400, height: 800), source: .accessibility,
                    validatesTargetsAtExecution: true, layoutSignature: initial ? "initial" : stable ? "stable" : "transient")
            }
        }
        final class Decisions: JevDecider {
            let name = "layout fixture"
            let plannerBound: Bool
            var observations: [JevObservation] = []
            init(_ plannerBound: Bool) { self.plannerBound = plannerBound }
            func decide(observation: JevObservation, state: JevState, apps: [(bundleId: String, name: String)],
                        textCandidates: [String]) async -> JevStepDecision {
                observations.append(observation)
                guard observations.count == 1 else {
                    return .init(action: .wait, confidence: 1, done: 0, blocked: 0, risky: 0)
                }
                return .init(action: .tap, confidence: 1, done: 0, blocked: 0, risky: 0, targetId: "advance",
                    executionToken: plannerBound ? UUID() : nil,
                    observationGuard: plannerBound ? .init(observation: observation, target: observation.elements[0], owner: nil) : nil)
            }
        }
        let layouts = Layouts(), decider = Decisions(plannerBound), input = FormValidationTests.Inputs()
        var policy = VPhoneJevAgent.Policy.default
        policy.maxSteps = 2; policy.settleMilliseconds = 0; policy.settlePollMilliseconds = 1
        _ = try await VPhoneJevAgent(goal: "Inspect the resulting view", decider: decider, provider: layouts,
            actuator: input, policy: policy, mode: .unattended).run()
        #expect(input.taps.count == 1)
        #expect(decider.observations.count == 2)
        #expect(decider.observations[1].elements.contains { $0.id == "toolbar" } == plannerBound)
        #expect(decider.observations[1].layoutSignature == (plannerBound ? "stable" : "transient"))
        #expect(layouts.reads == (plannerBound ? 5 : 3))
    }

    @Test func ordinaryBoundValuesAndSourceAreCheckedWithoutWholeScreenValueEquality() {
        var raw = ControlMemoryTests().observation("A")
        let field = JevElement(id: "field", role: "textfield", label: "Title", value: "Original", point: .zero)
        raw.elements.append(field)
        let evidence = JevPlannerObservationGuard(observation: raw, target: field, owner: nil)
        var changed = raw
        changed.elements[changed.elements.count - 1] = JevElement(id: "field2", role: "textfield", label: "Title", value: "Changed", point: .zero)
        #expect(evidence.rejection(in: changed) != nil)
        changed.elements[changed.elements.count - 1] = JevElement(id: "field2", role: "textfield", label: "Title", value: "Original", point: CGPoint(x: 20, y: 30))
        #expect(evidence.rejection(in: changed) == nil)
        let wrongSource = JevObservation(foregroundApp: raw.foregroundApp, elements: raw.elements,
            bounds: raw.bounds, source: .ocr, documentTitle: raw.documentTitle)
        #expect(evidence.rejection(in: wrongSource) != nil)
    }
}
