@testable import vphone_cli
import Foundation
import Testing

@MainActor
struct PlannerTerminalTests {
    @Test(arguments: ["continue", "complete", "stop"])
    func originalGoalStatusTakesPrecedenceOverProposedInput(status: String) async {
        let fixture = PlannerTests(), base = PlannerTests.Base()
        let planned = JevPlannerDecider(base: base, executable: "/unused")
        var calls = 0
        planned.requestOverride = { input in calls += 1; return fixture.reply(to: input) }
        base.decision = .init(action: .tap, confidence: 0.99, done: 0, blocked: 0.1, risky: 0.2,
            targetId: "owner:action1", originalGoalStatus: status, originalGoalStatusProbability: 0.9, inputTokens: 23)
        let result = await fixture.decide(planned)
        #expect(result.action == (status == "continue" ? .tap : status == "complete" ? .wait : .stopUnable))
        #expect(result.done == 0 && result.inputTokens == 23)
        #expect(result.blocked == 0.1 && result.risky == 0.2)
        if status == "complete" {
            base.decision = .init(action: .finish, confidence: 1, done: 0.99, blocked: 0, risky: 0)
            let confirmed = await fixture.decide(planned)
            #expect(confirmed.action == .finish && confirmed.done == 0.99 && calls == 1)
            #expect(base.states.last?.plannerContext == nil)
        }
    }

    @Test func missingInvalidOrUncertainOriginalGoalStatusCannotPermitInput() async {
        let decision = JevStepDecision(action: .tap, confidence: 1, done: 0, blocked: 0, risky: 0, targetId: "owner:action1")
        for choice in ["continue", "complete", "stop"] {
            let answer = JevAnswer(type: "choice", noul: nil, choice: choice, score: nil,
                probabilities: Dictionary(uniqueKeysWithValues: JevQuestions.originalGoalStatusOptions.map { ($0, $0 == choice ? 1.0 : 0) }), confidence: 1)
            let response = JevResponse(model: "fixture", answers: [JevQuestions.originalGoalStatus: answer], usage: nil)
            #expect(JevModelDecider.bindOriginalGoalStatus(response, to: decision).originalGoalStatus == choice)
        }
        let missing = JevResponse(model: "fixture", answers: [:], usage: JevUsage(inputTokens: 17, outputTokens: 0))
        #expect(JevModelDecider.bindOriginalGoalStatus(missing, to: decision).failure != nil)
        #expect(JevModelDecider.bindOriginalGoalStatus(missing, to: decision).inputTokens == 17)
        let base = PlannerTests.Base(), fixture = PlannerTests()
        let planned = JevPlannerDecider(base: base, executable: "/unused")
        planned.requestOverride = { input in fixture.reply(to: input) }
        base.decision = .init(action: .tap, confidence: 1, done: 0, blocked: 0, risky: 0,
            targetId: "owner:action1", originalGoalStatus: "continue", originalGoalStatusProbability: 0.5, inputTokens: 19)
        let result = await fixture.decide(planned)
        #expect(result.failure != nil && result.inputTokens == 19)
    }
}
