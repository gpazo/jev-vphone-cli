import Foundation

/// Jev judges AX first. Vision is evidence escalation, never an error retry or
/// permission bypass. The planner and agent still bind and validate the action.
@MainActor
final class JevVisionFallbackDecider: JevDecider {
    let primary: any JevDecider
    let vision: any JevDecider
    let observer: any JevObservationProvider
    let policy: VPhoneJevAgent.Policy
    let maxRequests: Int
    private(set) var requests = 0
    var name: String { primary.name + " + conditional Clef vision" }

    init(primary: any JevDecider, vision: any JevDecider, observer: any JevObservationProvider,
         policy: VPhoneJevAgent.Policy = .default, maxRequests: Int = 12) {
        self.primary = primary; self.vision = vision; self.observer = observer
        self.policy = policy; self.maxRequests = maxRequests
    }

    func executionDidResolve(_ event: JevExecutionEvent) {
        primary.executionDidResolve(event); vision.executionDidResolve(event)
    }

    func mayEscalate(_ decision: JevStepDecision) -> Bool {
        decision.failure == nil && decision.action != .finish && decision.action != .stopUnable
            && decision.done < policy.done && decision.blocked < policy.blocked && decision.risky < policy.risky
            && (decision.originalGoalStatus == nil || decision.originalGoalStatus == "continue")
            && (decision.originalGoalStatus == nil || decision.originalGoalStatusProbability > policy.finishActionProbability)
            && decision.executionConfidence < policy.confirmBelowConfidence
    }

    private func guardFor(_ decision: JevStepDecision, in observation: JevObservation) -> JevPlannerObservationGuard {
        let target = decision.targetId.flatMap { observation.element(id: $0) }
        let ownerID = target?.customAction?.ownerID
        let owner = ownerID.flatMap { observation.element(id: $0) }
        return JevPlannerObservationGuard(observation: observation, target: target, owner: owner)
    }

    func decide(observation: JevObservation, state: JevState, apps: [(bundleId: String, name: String)],
                textCandidates: [String]) async -> JevStepDecision {
        let initial = await primary.decide(observation: observation, state: state, apps: apps, textCandidates: textCandidates)
        guard mayEscalate(initial) else { return initial }
        func failed(_ reason: String, tokens: Int) -> JevStepDecision {
            var result = JevStepDecision.failed(reason); result.inputTokens = tokens; return result
        }
        guard requests < maxRequests else { return failed("Clef vision fallback request limit reached", tokens: initial.inputTokens) }
        var guards = [guardFor(initial, in: observation)]
        if let proposal = state.plannerContext?.proposedAction {
            let space = JevActionSpace(observation: observation, apps: apps, textCandidates: textCandidates,
                pickerValues: JevModelDecider.pickerValues(in: state))
            let bindings = JevPlannerDecider.bindings(observation: observation, space: space).filter {
                $0.operation.rawValue == proposal.operation && $0.key == proposal.targetKey
            }
            guard bindings.count == 1, let binding = bindings.first else {
                return failed("Planner proposal no longer binds before Clef vision", tokens: initial.inputTokens)
            }
            guards.append(JevPlannerObservationGuard(observation: observation, target: binding.element, owner: binding.owner))
        }
        do {
            let fresh = try await observer.observe()
            for evidence in guards {
                if let reason = evidence.rejection(in: fresh) {
                    return failed("Observation changed before Clef vision: " + reason, tokens: initial.inputTokens)
                }
            }
        } catch { return failed("Could not validate vision observation: \(error)", tokens: initial.inputTokens) }
        requests += 1
        print(String(format: "  vision    Jev execution confidence %.4f below %.2f; Clef fallback %d/%d",
                     initial.executionConfidence, policy.confirmBelowConfidence, requests, maxRequests))
        var result = await vision.decide(observation: observation, state: state, apps: apps, textCandidates: textCandidates)
        result.inputTokens += initial.inputTokens
        guard result.failure == nil else { return result }
        // Never lower the original safety judgments, even if Clef disagrees.
        result.blocked = max(initial.blocked, result.blocked)
        result.risky = max(initial.risky, result.risky)
        // Preserve terminal / safety judgments for the existing agent to handle.
        let acceptedFinish = result.action == .finish && (policy.corroborateCompletion
            ? result.done >= policy.finishAccepted : result.actionProbability > policy.finishActionProbability)
        let terminal = acceptedFinish || result.action == .stopUnable || result.done >= policy.done
            || (result.originalGoalStatus != nil && result.originalGoalStatus != "continue"
                && result.originalGoalStatusProbability > policy.finishActionProbability)
        do {
            let fresh = try await observer.observe()
            for evidence in guards + [guardFor(result, in: observation)] {
                if let reason = evidence.rejection(in: fresh) {
                    return failed("Observation changed during Clef vision: " + reason, tokens: result.inputTokens)
                }
            }
        } catch { return failed("Could not validate Clef vision result: \(error)", tokens: result.inputTokens) }
        if !terminal && result.blocked < policy.blocked && result.risky < policy.risky
            && result.executionConfidence < policy.confirmBelowConfidence {
            guard state.plannerContext?.proposedAction != nil, result.visionJudgment != nil,
                  result.originalGoalStatus == "continue",
                  result.originalGoalStatusProbability > policy.finishActionProbability else {
                return failed("Clef vision remained below the action/target confidence threshold", tokens: result.inputTokens)
            }
            result.recovery = .unresolvedVision
        }
        return result
    }
}

/// The experimental helper captures a screenshot only when invoked, reserves
/// the existing Python ledger before HTTP, and never retries or sends input.
@MainActor
enum JevClefVisionTransport {
    static func ask(client: VPhoneJevClient, state: JevState, questions: [String: JevQuestion],
                    simulator: String, executable: String) async throws -> JevResponse {
        let body = try client.makeRequest(state: state, questions: questions).httpBody!
        var request = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        request["simulator"] = simulator
        request["account_id"] = client.cloudflareAccountID
        let input = try JSONSerialization.data(withJSONObject: request)
        let result = try await Task.detached {
            try JevPlannerProcess.run(executable: executable, input: input, timeout: 45, limit: 262_144)
        }.value
        guard result.failure == nil, result.status == 0 else {
            throw VPhoneJevClient.ClientError.rejected(result.failure ?? String(decoding: result.diagnostic, as: UTF8.self))
        }
        return try JSONDecoder().decode(JevResponse.self, from: result.output)
    }
}
