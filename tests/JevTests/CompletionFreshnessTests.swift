@testable import vphone_cli
import CoreGraphics
import Testing

@MainActor
struct CompletionFreshnessTests {
    final class Screens: JevObservationProvider {
        var titles: [String]
        var reads = 0
        var incompleteReads: Set<Int> = []
        init(_ titles: [String]) { self.titles = titles }
        func observe() async throws -> JevObservation {
            reads += 1
            let title = titles.count > 1 ? titles.removeFirst() : titles[0]
            var observation = JevObservation(foregroundApp: "Browser", elements: [],
                bounds: CGRect(x: 0, y: 0, width: 400, height: 800),
                source: .accessibility, documentTitle: title)
            if incompleteReads.contains(reads) { observation.completenessIssue = "Remote content unavailable" }
            return observation
        }
    }
    final class Finisher: JevDecider {
        let name = "test"
        var calls = 0
        var probability = 1.0
        var doneEstimate = 1.0
        var action: JevAction = .finish
        func decide(observation: JevObservation, state: JevState,
                    apps: [(bundleId: String, name: String)], textCandidates: [String]) async -> JevStepDecision {
            calls += 1
            return JevStepDecision(action: action, confidence: 1, done: doneEstimate, blocked: 0, risky: 0,
                                   actionProbability: probability)
        }
    }
    struct NoInput: JevActuator {
        func tap(at point: CGPoint) async throws { Issue.record("Unexpected input") }
        func scroll(reveal: JevScrollDirection) async throws { Issue.record("Unexpected input") }
        func drag(at point: CGPoint, up: Bool) async throws { Issue.record("Unexpected input") }
        func type(_ text: String) async throws { Issue.record("Unexpected input") }
        func pressHome() async throws { Issue.record("Unexpected input") }
        func launch(bundleId: String) async throws { Issue.record("Unexpected input") }
    }

    @Test func changedDocumentCannotBeCertifiedByAnOldDecision() async throws {
        let decider = Finisher()
        var policy = VPhoneJevAgent.Policy.default
        policy.maxSteps = 1
        let agent = VPhoneJevAgent(goal: "Read the page", decider: decider,
            provider: Screens(["Old", "New"]), actuator: NoInput(), policy: policy)
        #expect(try await !agent.run().succeeded)
        #expect(decider.calls == 1)
    }

    @Test func changedCompletionEvidenceIsRejudgedBeforeSuccess() async throws {
        let decider = Finisher()
        let screens = Screens(["Old", "New", "New"])
        let agent = VPhoneJevAgent(goal: "Read the page", decider: decider,
            provider: screens, actuator: NoInput())
        #expect(try await agent.run().succeeded)
        #expect(decider.calls == 2)
        #expect(screens.reads == 3) // initial, changed evidence, fresh completion check
    }

    @Test func handedOffObservationStillRequiresAnotherFreshCompletionCheck() async throws {
        let decider = Finisher()
        let screens = Screens(["Old", "New", "Changed again"])
        var policy = VPhoneJevAgent.Policy.default
        policy.maxSteps = 2
        let agent = VPhoneJevAgent(goal: "Read the page", decider: decider,
            provider: screens, actuator: NoInput(), policy: policy)
        #expect(try await !agent.run().succeeded)
        #expect(decider.calls == 2)
        #expect(screens.reads == 3)
    }

    @Test func changedReadOnlyEvidenceMustBeRejudgedBeforeCompletion() async throws {
        final class ContextScreens: JevObservationProvider {
            var reads = 0
            func observe() async throws -> JevObservation {
                reads += 1
                return JevObservation(foregroundApp: "Forms", elements: [],
                    bounds: CGRect(x: 0, y: 0, width: 400, height: 800), source: .accessibility,
                    nearbyElements: [.init(id: "context1", role: "textfield", label: "Duration",
                        value: reads == 1 ? "45" : "60", visibility: "covered; not actionable")])
            }
        }
        let provider = ContextScreens()
        let decider = Finisher()
        let agent = VPhoneJevAgent(goal: "Check the form", decider: decider,
            provider: provider, actuator: NoInput())
        #expect(try await agent.run().succeeded)
        #expect(decider.calls == 2)
        #expect(provider.reads == 3)
    }

    @Test(arguments: [1, 2])
    func incompleteInitialOrFreshScreenCannotBeCertified(read: Int) async throws {
        let screens = Screens(["Stable"])
        screens.incompleteReads = [read]
        let agent = VPhoneJevAgent(goal: "Read the page", decider: Finisher(),
            provider: screens, actuator: NoInput())
        #expect(try await !agent.run().succeeded)
        #expect(screens.reads == read)
    }

    @Test func scrollWaitsForLayoutNotJustAChangedSemanticScreen() async throws {
        final class MovingScreens: JevObservationProvider {
            var reads = 0
            func observe() async throws -> JevObservation {
                reads += 1
                let position = min(reads - 1, 3)
                let label = position == 0 ? "Initial" : "Article"
                return JevObservation(foregroundApp: "Browser",
                    elements: [JevElement(id: "e1", role: "statictext", label: label, value: nil, point: .zero)],
                    bounds: CGRect(x: 0, y: 0, width: 400, height: 800), source: .accessibility,
                    validatesTargetsAtExecution: true, layoutSignature: String(position))
            }
        }
        final class ScrollThenFinish: JevDecider {
            let name = "test"
            var layouts: [String?] = []
            func decide(observation: JevObservation, state: JevState,
                        apps: [(bundleId: String, name: String)], textCandidates: [String]) async -> JevStepDecision {
                layouts.append(observation.layoutSignature)
                return JevStepDecision(action: layouts.count == 1 ? .scrollDown : .finish,
                    confidence: 1, done: layouts.count == 1 ? 0 : 1, blocked: 0, risky: 0, actionProbability: 1)
            }
        }
        struct ScrollInput: JevActuator {
            func scroll(reveal: JevScrollDirection) async throws {}
            func tap(at point: CGPoint) async throws { Issue.record("Unexpected tap") }
            func drag(at point: CGPoint, up: Bool) async throws { Issue.record("Unexpected drag") }
            func type(_ text: String) async throws { Issue.record("Unexpected type") }
            func pressHome() async throws { Issue.record("Unexpected home") }
            func launch(bundleId: String) async throws { Issue.record("Unexpected launch") }
        }
        var policy = VPhoneJevAgent.Policy.default
        policy.settlePollMilliseconds = 0
        let decider = ScrollThenFinish()
        let agent = VPhoneJevAgent(goal: "Read further down", decider: decider,
            provider: MovingScreens(), actuator: ScrollInput(), policy: policy)
        #expect(try await agent.run().succeeded)
        #expect(decider.layouts == ["0", "3"])
    }

    @Test(arguments: [0, 1, 2])
    func nativeNavigationWaitsThroughGapButEditingAndOtherAppsAreReady(mode: Int) async throws {
        final class NavigationScreens: JevObservationProvider {
            var reads = 0
            let mode: Int
            init(mode: Int) { self.mode = mode }
            func observe() async throws -> JevObservation {
                reads += 1
                let title: String? = reads <= 2 ? "Detail" : (mode != 0 || reads == 3 ? nil : "Results")
                let control = mode == 1 && reads > 2
                    ? JevElement(id: "e1", role: "textfield", label: "Query", value: "", point: .zero)
                    : JevElement(id: "e1", role: "button", label: "Return", value: nil, point: .zero)
                return JevObservation(foregroundApp: mode == 2 && reads > 2 ? "Other app" : "Reader", elements: [control],
                    bounds: CGRect(x: 0, y: 0, width: 400, height: 800), source: .accessibility,
                    documentTitle: title, validatesTargetsAtExecution: true)
            }
        }
        final class NavigateThenFinish: JevDecider {
            let name = "test"
            var states: [JevState] = []
            func decide(observation: JevObservation, state: JevState,
                        apps: [(bundleId: String, name: String)], textCandidates: [String]) async -> JevStepDecision {
                states.append(state)
                return JevStepDecision(action: states.count == 1 ? .tap : .finish,
                    confidence: 1, done: states.count == 1 ? 0 : 1, blocked: 0, risky: 0,
                    actionProbability: 1, targetId: "e1")
            }
        }
        struct NativeInput: JevSemanticActuator {
            func press(_ element: JevElement) async throws { #expect(element.label == "Return") }
            func tap(at point: CGPoint) async throws { Issue.record("Unexpected tap") }
            func scroll(reveal: JevScrollDirection) async throws { Issue.record("Unexpected scroll") }
            func drag(at point: CGPoint, up: Bool) async throws { Issue.record("Unexpected drag") }
            func type(_ text: String) async throws { Issue.record("Unexpected type") }
            func pressHome() async throws { Issue.record("Unexpected home") }
            func launch(bundleId: String) async throws { Issue.record("Unexpected launch") }
            func adjust(_ element: JevElement, up: Bool) async throws { Issue.record("Unexpected adjust") }
            func select(_ value: String, on element: JevElement) async throws { Issue.record("Unexpected select") }
            func fill(_ text: String, on element: JevElement) async throws { Issue.record("Unexpected fill") }
        }
        var policy = VPhoneJevAgent.Policy.default
        policy.settlePollMilliseconds = 0
        let decider = NavigateThenFinish()
        let provider = NavigationScreens(mode: mode)
        let agent = VPhoneJevAgent(goal: "Return to the list", decider: decider,
            provider: provider, actuator: NativeInput(), policy: policy)
        #expect(try await agent.run().succeeded)
        #expect(decider.states.count == 2)
        #expect(decider.states.last?.documentTitle == (mode == 0 ? "Results" : nil))
        #expect(decider.states.last?.observedProgress?.outcomes.last?.observedDocument == (mode == 0 ? "Results" : nil))
        #expect(provider.reads == (mode == 0 ? 5 : 4))
    }

    @Test func terminalChoiceRequiresMajorityAndLegacyRuleIsReproducible() async throws {
        func run(probability: Double, done: Double, corroborate: Bool) async throws -> Bool {
            let decider = Finisher()
            decider.probability = probability
            decider.doneEstimate = done
            var policy = VPhoneJevAgent.Policy.default
            policy.corroborateCompletion = corroborate
            let agent = VPhoneJevAgent(goal: "Read the page", decider: decider,
                provider: Screens(["Stable"]), actuator: NoInput(), policy: policy)
            return try await agent.run().succeeded
        }
        #expect(try await run(probability: 0.7, done: 0.2, corroborate: false))
        #expect(try await !run(probability: 0.49, done: 0.9, corroborate: false))
        #expect(try await !run(probability: 0.5, done: 0.9, corroborate: false))
        #expect(try await !run(probability: 0, done: 0.9, corroborate: false))
        #expect(try await !run(probability: 0.7, done: 0.2, corroborate: true))
    }

    @Test func givingUpCannotBeMisreportedAsSuccessByIndependentDoneHead() async throws {
        let decider = Finisher()
        decider.action = .stopUnable
        let agent = VPhoneJevAgent(goal: "Unsupported operation", decider: decider,
            provider: Screens(["Stable"]), actuator: NoInput())
        #expect(try await !agent.run().succeeded)
    }
}
