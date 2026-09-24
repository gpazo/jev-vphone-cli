import Foundation

// MARK: - Decision

/// One step's judgment, however it was arrived at.
///
/// The agent consumes this and nothing else, so the judgment can be swapped
/// without touching the loop, the gates, the freshness checks or the
/// actuation. That is what makes an honest ablation possible: exactly one
/// thing differs between the two arms.
struct JevStepDecision {
    let action: JevAction
    let confidence: Double
    let done: Double
    let blocked: Double
    let risky: Double
    var actionProbability: Double = 0
    /// Keep the selected branch's uncertainty; unused speculative heads have
    /// no bearing on execution. This is not a joint success probability.
    var targetConfidence: Double?
    var targetProbability: Double?
    var executionConfidence: Double { min(confidence, targetConfidence ?? confidence) }

    /// Selections for the speculative branches, consumed only by whichever
    /// branch the action actually takes.
    var targetId: String?
    var appId: String?
    var textId: String?
    var pickerValue: String?
    var tapReadiness: String?
    var readinessProbability: Double = 0

    var inputTokens: Int = 0

    /// Set when no usable decision could be produced; the agent stops.
    var failure: String?

    static func failed(_ reason: String) -> JevStepDecision {
        JevStepDecision(
            action: .wait, confidence: 0, done: 0, blocked: 0, risky: 0, failure: reason
        )
    }
}

@MainActor
protocol JevDecider {
    /// Named in run output, so which policy produced a result is never in doubt.
    var name: String { get }

    func decide(
        observation: JevObservation,
        state: JevState,
        apps: [(bundleId: String, name: String)],
        textCandidates: [String]
    ) async -> JevStepDecision
}

// MARK: - Jev

/// The real policy: one batched System One request per step.
@MainActor
struct JevModelDecider: JevDecider {
    let client: VPhoneJevClient
    var terminalChoiceCompletion = false
    var validateForms = false
    var compactRequests = false

    var name: String { "jev (\(client.model))" + (validateForms ? " + experimental form validation" : "")
        + (compactRequests ? " + experimental compact requests" : "") }

    func decide(
        observation: JevObservation,
        state: JevState,
        apps: [(bundleId: String, name: String)],
        textCandidates: [String]
    ) async -> JevStepDecision {
        var questions = JevQuestions.build(
            observation: observation,
            apps: apps,
            textCandidates: textCandidates,
            hasVerifiedFacts: state.verifiedFacts != nil,
            pickerValues: JevPickerValues.extract(from: state.goal),
            includeStopUnable: terminalChoiceCompletion
        )

        let space = JevActionSpace(observation: observation, apps: apps,
            textCandidates: textCandidates, pickerValues: JevPickerValues.extract(from: state.goal),
            includeStopUnable: terminalChoiceCompletion)
        // Bound speculative work on dense pages. A selected target outside
        // the batch receives the same judgment in one follow-up request.
        if validateForms, let taps = space.targets[.tap] {
            for id in taps.keys.sorted().prefix(24) {
                questions[JevQuestions.readinessHead(id)] = JevQuestions.readiness(for: taps[id]!)
            }
        }
        if compactRequests { questions = JevQuestions.compacted(questions) }

        let response: JevResponse
        do {
            response = try await client.ask(state: state, questions: questions)
        } catch {
            return .failed("Jev request failed: \(error)")
        }

        var decision = Self.decode(response, space: space)
        if validateForms, decision.failure == nil, decision.action == .tap,
           let id = decision.targetId, let target = space.targets[.tap]?[id] {
            let head = JevQuestions.readinessHead(id)
            var answer = response[head]
            if questions[head] == nil {
                do {
                    let validation = try await client.ask(state: state, questions: [head: JevQuestions.readiness(for: target)])
                    answer = validation[head]
                    decision.inputTokens += validation.usage?.inputTokens ?? 0
                } catch { return .failed("Form validation failed: \(error)") }
            }
            guard let answer, answer.validated(against: JevQuestions.readinessOptions) == nil else {
                return .failed("Missing or invalid readiness judgment for the selected tap")
            }
            decision.tapReadiness = answer.choice
            decision.readinessProbability = answer.topProbability
        }
        return decision
    }

    static func decode(_ response: JevResponse, space: JevActionSpace) -> JevStepDecision {
        guard let answer = response[JevQuestions.action] else { return .failed("Jev returned no action answer") }
        if let invalid = answer.validated(against: space.operations.map(\.rawValue)) {
            return .failed("unusable action answer — \(invalid)")
        }
        guard let raw = answer.choice, let action = JevAction(rawValue: raw) else { return .failed("Jev returned no usable action") }
        var target: JevActionSpace.Target?
        var targetAnswer: JevAnswer?
        if let candidates = space.targets[action] {
            let head = JevActionSpace.head(for: action)
            guard let selected = response[head] else { return .failed("Jev returned no \(head) answer") }
            if let invalid = selected.validated(against: candidates.keys) {
                return .failed("unusable \(head) answer — \(invalid)")
            }
            target = selected.choice.flatMap { candidates[$0] }
            targetAnswer = selected
        }
        return JevStepDecision(action: action, confidence: answer.confidenceOrZero,
            done: response[JevQuestions.done]?.noul ?? 0,
            blocked: response[JevQuestions.blocked]?.noul ?? 0,
            risky: response[JevQuestions.risky]?.noul ?? 0,
            actionProbability: answer.topProbability,
            targetConfidence: targetAnswer?.confidence, targetProbability: targetAnswer?.topProbability,
            targetId: target?.elementID, appId: target?.appID, textId: target?.textID,
            pickerValue: action == .setPickerValue ? target?.value : nil,
            inputTokens: response.usage?.inputTokens ?? 0)
    }
}

// MARK: - Baseline

/// The ablation: the same agent with the judgment removed.
///
/// Taps whichever visible label best matches the goal by word overlap, opens
/// an app when the goal names one, and scrolls when nothing matches. This is
/// deliberately the *best* version of a no-model policy — labels are
/// normalised so "Wi-Fi" matches "wifi", and app launching is available —
/// because an ablation only informs if the baseline is not strawmanned.
///
/// What it structurally cannot do is the point of running it:
///
/// - **Terminate.** It has no notion of the goal being satisfied, so it keeps
///   acting, including undoing a setting it has already set.
/// - **Navigate indirectly.** It can only act on labels sharing words with
///   the goal, so "open Settings to reach Bold Text" is unreachable until the
///   word is already on screen.
/// - **Refuse.** It produces no risk judgment, so every gate that depends on
///   one is inert and a destructive screen is acted on like any other.
@MainActor
struct JevBaselineDecider: JevDecider {
    let goal: String

    var name: String { "baseline (label match, no model)" }

    private static let stopWords: Set<String> = [
        "the", "a", "an", "to", "on", "off", "in", "into", "my", "me", "please",
        "and", "for", "of", "it", "is", "up", "then", "with", "at", "by", "app",
        "set", "open", "go", "turn", "make",
    ]

    /// Lowercased words with punctuation stripped, so "Wi-Fi" becomes "wifi".
    static func tokens(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
                .map { String($0.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }) }
                .filter { !$0.isEmpty && !stopWords.contains($0) }
        )
    }

    /// Fraction of a label's own words that the goal also mentions.
    static func score(label: String, goalTokens: Set<String>) -> Double {
        let labelTokens = tokens(label)
        guard !labelTokens.isEmpty else { return 0 }
        return Double(labelTokens.intersection(goalTokens).count) / Double(labelTokens.count)
    }

    func decide(
        observation: JevObservation,
        state: JevState,
        apps: [(bundleId: String, name: String)],
        textCandidates: [String]
    ) async -> JevStepDecision {
        let goalTokens = Self.tokens(goal)

        // Launching a named app is the one thing a matcher can do well, so it
        // gets the same advantage the real policy has.
        let bestApp = apps
            .map { (app: $0, score: Self.score(label: $0.name, goalTokens: goalTokens)) }
            .max { $0.score < $1.score }
        if let bestApp, bestApp.score >= 1.0,
           observation.elements.contains(where: { $0.label.lowercased() == bestApp.app.name.lowercased() })
        {
            return JevStepDecision(
                action: .openApp, confidence: bestApp.score, done: 0, blocked: 0, risky: 0,
                appId: bestApp.app.bundleId
            )
        }

        let best = observation.elements
            .filter(\.isTappable)
            .map { (element: $0, score: Self.score(label: $0.label, goalTokens: goalTokens)) }
            .max { $0.score < $1.score }

        guard let best, best.score > 0 else {
            // Nothing on screen relates to the goal; look further down.
            return JevStepDecision(
                action: .scrollDown, confidence: 0.5, done: 0, blocked: 0, risky: 0
            )
        }

        // done, blocked and risky are all zero: this policy has no opinion
        // about completion or danger, which is exactly what the gates need.
        return JevStepDecision(
            action: .tap,
            confidence: best.score,
            done: 0,
            blocked: 0,
            risky: 0,
            targetId: best.element.id
        )
    }
}
