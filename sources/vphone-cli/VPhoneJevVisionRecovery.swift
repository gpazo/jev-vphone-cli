import Foundation

enum JevRecoveryDisposition: Equatable {
    case unresolvedVision
    case reobserve
}

struct JevVisionJudgment: Encodable {
    enum Diagnosis: String, CaseIterable, Encodable {
        case stillNeeded, alreadySatisfied, targetUnavailable, ambiguous, unknown
    }
    let diagnosis: Diagnosis
    let confidence: Double
    let probability: Double

    init?(answer: JevAnswer) {
        guard answer.validated(against: Diagnosis.allCases.map(\.rawValue)) == nil,
              let choice = answer.choice, let diagnosis = Diagnosis(rawValue: choice),
              let confidence = answer.confidence else { return nil }
        self.diagnosis = diagnosis
        self.confidence = confidence
        probability = answer.topProbability
    }
}

struct JevPlannerVisionFeedback: Encodable {
    let sourceObservationID: String
    let rejectedProposal: JevState.PlannerContext.ProposedAction
    let judgment: JevVisionJudgment
}
