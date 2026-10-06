@testable import vphone_cli
import Foundation
import Testing

@MainActor
struct VisionFallbackTests {
    final class Observer: JevObservationProvider {
        var observations: [JevObservation]
        init(_ observations: [JevObservation]) { self.observations = observations }
        func observe() async throws -> JevObservation {
            observations.count > 1 ? observations.removeFirst() : observations[0]
        }
    }
    func run(_ wrapper: JevVisionFallbackDecider) async -> JevStepDecision {
        let fixture = PlannerTests()
        return await wrapper.decide(observation: fixture.observation, state: fixture.state(), apps: [], textCandidates: [])
    }
    func wrapper(_ primary: PlannerTests.Base, _ secondary: PlannerTests.Base, limit: Int = 12,
                 observations: [JevObservation]? = nil) -> JevVisionFallbackDecider {
        JevVisionFallbackDecider(primary: primary, vision: secondary,
            observer: Observer(observations ?? [PlannerTests().observation]), maxRequests: limit)
    }

    @Test func confidentJevMakesNoVisionCallAndTargetUncertaintyTriggersOne() async {
        let primary = PlannerTests.Base(), secondary = PlannerTests.Base()
        primary.decision.targetConfidence = 0.9
        secondary.decision.targetConfidence = 0.95
        let agent = wrapper(primary, secondary)
        _ = await run(agent)
        #expect(agent.requests == 0 && secondary.states.isEmpty)
        primary.decision.targetConfidence = 0.84
        let answer = await run(agent)
        #expect(agent.requests == 1 && secondary.states.count == 1)
        #expect(answer.failure == nil && answer.targetConfidence == 0.95)
        #expect(answer.inputTokens == 34)
        #expect(secondary.states[0].elements.count == primary.states[1].elements.count)
        #expect(secondary.states[0].goal == primary.states[1].goal)
    }

    @Test func errorsTerminalAndSafetyGatesCannotTriggerVision() async {
        let primary = PlannerTests.Base(), secondary = PlannerTests.Base()
        let original = primary.decision
        for scenario in 0..<7 {
            primary.decision = original
            switch scenario {
            case 0: primary.decision.failure = "HTTP 429"
            case 1: primary.decision = JevStepDecision(action: .finish, confidence: 0.1, done: 0, blocked: 0, risky: 0)
            case 2: primary.decision = JevStepDecision(action: .stopUnable, confidence: 0.1, done: 0, blocked: 0, risky: 0)
            case 3: primary.decision = JevStepDecision(action: .tap, confidence: 0.1, done: 0.9, blocked: 0, risky: 0)
            case 4: primary.decision.blocked = 0.5
            case 5: primary.decision.risky = 0.5
            default: primary.decision.originalGoalStatus = "stop"
            }
            let agent = wrapper(primary, secondary)
            _ = await run(agent)
            #expect(agent.requests == 0)
        }
        #expect(secondary.states.isEmpty)
    }

    @Test func fallbackMustResolveUncertaintyAndPreserveWarnings() async {
        let primary = PlannerTests.Base(), secondary = PlannerTests.Base()
        #expect(await run(wrapper(primary, secondary)).failure != nil)
        secondary.decision.targetConfidence = 0.95
        secondary.decision.blocked = 0
        secondary.decision.risky = 0
        let answer = await run(wrapper(primary, secondary))
        #expect(answer.blocked == primary.decision.blocked && answer.risky == primary.decision.risky)
        secondary.decision = .failed("HTTP 429")
        #expect(await run(wrapper(primary, secondary)).failure == "HTTP 429")
    }

    @Test func staleOwnerAndFallbackCapStopWithoutFurtherCalls() async {
        let primary = PlannerTests.Base(), secondary = PlannerTests.Base()
        secondary.decision.targetConfidence = 0.95
        let old = PlannerTests().observation, changed = ControlMemoryTests().observation("Changed")
        let before = wrapper(primary, secondary, observations: [changed])
        #expect(await run(before).failure != nil)
        #expect(before.requests == 0)
        let during = wrapper(primary, secondary, observations: [old, changed])
        #expect(await run(during).failure != nil)
        #expect(during.requests == 1)
        let capped = wrapper(primary, secondary, limit: 1)
        #expect(await run(capped).failure == nil)
        #expect(await run(capped).failure != nil)
        #expect(capped.requests == 1)
    }

    @Test func weakFinishCannotBecomeAnotherUncertainPlannerWait() async {
        let primary = PlannerTests.Base(), secondary = PlannerTests.Base()
        primary.decision.risky = 0.05
        secondary.decision = JevStepDecision(action: .finish, confidence: 0.1368, done: 0.1644,
            blocked: 0.0178, risky: 0.05, actionProbability: 0.368)
        let answer = await run(wrapper(primary, secondary))
        #expect(answer.failure == "Clef vision remained below the action/target confidence threshold")
    }

    @Test func fallbackCLIIsOptInAndRejectsIncompatibleModes() throws {
        #expect(try !VPhoneJevCommand.parse(["play"]).clefVisionFallback)
        #expect(try VPhoneJevCommand.parse(["play", "--simulator", "booted", "--clef-vision-fallback"]).clefVisionFallback)
        for flags in [[], ["--simulator", "booted", "--provider", "cloudflare"],
                      ["--simulator", "booted", "--baseline"], ["--simulator", "booted", "--validate-forms"]] {
            #expect(throws: (any Error).self) { try VPhoneJevCommand.parse(["play", "--clef-vision-fallback"] + flags) }
        }
    }
}
