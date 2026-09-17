import CoreGraphics
import Foundation

// MARK: - Actuation

/// Everything the agent can physically do to the phone.
///
/// Abstracted so the loop is testable and so `--dry-run` is a substitution
/// rather than a branch threaded through the decision code.
@MainActor
protocol JevActuator {
    func tap(at point: CGPoint) async throws
    func scroll(reveal: JevScrollDirection) async throws
    func type(_ text: String) async throws
    func pressHome() async throws
    func launch(bundleId: String) async throws
}

enum JevScrollDirection {
    /// Reveal content below the fold.
    case below
    /// Reveal content above.
    case above
}

// MARK: - Agent

/// Drives the phone toward a natural-language goal, one bounded step at a
/// time.
///
/// Each step: observe the screen as text, ask Jev one batch of questions
/// about it, then let *code* decide what that means. The model supplies
/// judgment; every threshold, guard and stopping rule lives here, where it
/// can be read, tested and tuned without retraining anything.
@MainActor
final class VPhoneJevAgent {
    // MARK: Policy

    /// Thresholds are starting points, not tuned constants. TypeSafe's own
    /// guidance is that they must be evaluated against real data and real
    /// consequences — expect to move these after watching actual runs.
    struct Policy {
        /// Stop successfully at or above this `done` probability.
        var done = 0.8
        /// Hand back to the human at or above this `blocked` probability.
        var blocked = 0.6
        /// Require confirmation at or above this `risky` probability.
        var risky = 0.5
        /// Below this action confidence, stop rather than guess.
        var stopBelowConfidence = 0.5
        /// Between the two, act only after confirmation.
        var confirmBelowConfidence = 0.85
        var maxSteps = 25
        /// Identical screens in a row before declaring the loop stuck.
        var stuckLimit = 3
        /// Let the UI settle before the next observation.
        var settleMilliseconds = 900

        static let `default` = Policy()
    }

    enum Mode {
        /// Decide and act, gated by `Policy`.
        case live
        /// Decide and report, touch nothing.
        case dryRun
        /// Decide and act, skipping confirmation prompts.
        case unattended
    }

    enum Outcome {
        case achieved(steps: Int)
        case stopped(reason: String, steps: Int)
        case exhausted(steps: Int)

        var succeeded: Bool {
            if case .achieved = self { return true }
            return false
        }
    }

    /// One step, as reported to the caller for logging.
    struct Step {
        let index: Int
        let action: JevAction
        let actionConfidence: Double
        let detail: String
        let done: Double
        let blocked: Double
        let risky: Double
        let executed: Bool
        let inputTokens: Int
    }

    // MARK: Dependencies

    private let goal: String
    private let client: VPhoneJevClient
    private let provider: any JevObservationProvider
    private let actuator: any JevActuator
    private let policy: Policy
    private let mode: Mode

    /// Installed apps offered as `open_app` options. Empty disables the branch.
    var installedApps: [(bundleId: String, name: String)] = []
    /// Ground truth code has checked — e.g. a `settingsGet` reading — shown
    /// to the model separately from what the screen appears to say. Nothing
    /// populates this yet; it is the seam for goal-specific verification.
    var verifiedFacts: [String] = []
    /// Asked before a risky or low-confidence action. Returning false stops.
    var confirm: @MainActor (String) async -> Bool = { _ in false }
    /// Called after every step, for live output.
    var onStep: @MainActor (Step) -> Void = { _ in }

    private var history: [String] = []
    private var recentSignatures: [String] = []
    private(set) var totalInputTokens = 0

    init(
        goal: String,
        client: VPhoneJevClient,
        provider: any JevObservationProvider,
        actuator: any JevActuator,
        policy: Policy = .default,
        mode: Mode = .live
    ) {
        self.goal = goal
        self.client = client
        self.provider = provider
        self.actuator = actuator
        self.policy = policy
        self.mode = mode
    }

    // MARK: Loop

    func run() async throws -> Outcome {
        let textCandidates = JevTextCandidates.extract(from: goal)

        for index in 1 ... policy.maxSteps {
            let observation = try await provider.observe()

            let state = JevState(
                goal: goal,
                foregroundApp: observation.foregroundApp,
                observationSource: observation.source.rawValue,
                elements: observation.elements.map(\.described),
                history: history,
                verifiedFacts: verifiedFacts.isEmpty ? nil : verifiedFacts
            )

            let response = try await client.ask(
                state: state,
                questions: JevQuestions.build(
                    observation: observation,
                    apps: installedApps,
                    textCandidates: textCandidates,
                    hasVerifiedFacts: !verifiedFacts.isEmpty
                )
            )
            totalInputTokens += response.usage?.inputTokens ?? 0

            let doneP = response[JevQuestions.done]?.noul ?? 0
            let blockedP = response[JevQuestions.blocked]?.noul ?? 0
            let riskyP = response[JevQuestions.risky]?.noul ?? 0

            guard let actionAnswer = response[JevQuestions.action],
                  let raw = actionAnswer.choice,
                  let action = JevAction(rawValue: raw)
            else {
                return .stopped(reason: "Jev returned no usable action", steps: index)
            }

            let confidence = actionAnswer.confidenceOrZero

            // ── Stopping conditions, checked before anything is executed ──

            if doneP >= policy.done {
                report(index, action, confidence, "goal already satisfied", doneP, blockedP, riskyP, false, response)
                return .achieved(steps: index)
            }

            if blockedP >= policy.blocked {
                report(index, action, confidence, "needs a human decision", doneP, blockedP, riskyP, false, response)
                return .stopped(
                    reason: "screen requires a human decision (blocked \(pct(blockedP)))",
                    steps: index
                )
            }

            if action == .finish {
                report(index, action, confidence, "Jev chose to stop", doneP, blockedP, riskyP, false, response)
                return doneP >= 0.5
                    ? .achieved(steps: index)
                    : .stopped(reason: "Jev stopped without the goal being met", steps: index)
            }

            // Stuck detection is code's job, not the model's: the model sees
            // one screen at a time and cannot reliably notice a loop.
            recentSignatures.append(observation.signature)
            if recentSignatures.count > policy.stuckLimit {
                recentSignatures.removeFirst()
            }
            if recentSignatures.count == policy.stuckLimit,
               Set(recentSignatures).count == 1
            {
                return .stopped(
                    reason: "screen unchanged across \(policy.stuckLimit) steps",
                    steps: index
                )
            }

            // ── Resolve the action into something concrete ──

            let plan: Plan
            do {
                plan = try resolve(action: action, response: response, observation: observation,
                                   textCandidates: textCandidates)
            } catch let error as PlanError {
                return .stopped(reason: error.description, steps: index)
            }

            // ── Gates ──

            if confidence < policy.stopBelowConfidence {
                report(index, action, confidence, plan.detail, doneP, blockedP, riskyP, false, response)
                return .stopped(
                    reason: "confidence \(pct(confidence)) too low to act on \(plan.detail)",
                    steps: index
                )
            }

            var needsConfirmation = false
            var reason = ""
            if riskyP >= policy.risky {
                needsConfirmation = true
                reason = "irreversible (risky \(pct(riskyP)))"
            } else if confidence < policy.confirmBelowConfidence {
                needsConfirmation = true
                reason = "uncertain (confidence \(pct(confidence)))"
            }

            // A dry run reports the next decision and stops. Continuing would
            // be misleading: with nothing executed the screen cannot change,
            // so every further step would re-decide the same screen and
            // eventually trip stuck detection.
            if mode == .dryRun {
                report(index, action, confidence, plan.detail, doneP, blockedP, riskyP, false, response)
                return .stopped(reason: "dry run — would \(plan.detail)", steps: index)
            }

            if needsConfirmation, mode == .live {
                let approved = await confirm("\(plan.detail) — \(reason). Proceed?")
                guard approved else {
                    report(index, action, confidence, plan.detail, doneP, blockedP, riskyP, false, response)
                    return .stopped(reason: "declined: \(plan.detail)", steps: index)
                }
            }

            // ── Act ──

            try await execute(plan)
            report(index, action, confidence, plan.detail, doneP, blockedP, riskyP, true, response)
            history.append(plan.detail)

            try? await Task.sleep(nanoseconds: UInt64(policy.settleMilliseconds) * 1_000_000)
        }

        return .exhausted(steps: policy.maxSteps)
    }

    // MARK: Resolution

    private enum Plan {
        case tap(JevElement)
        case scroll(JevScrollDirection)
        case type(String)
        case home
        case launch(bundleId: String, name: String)
        case wait

        var detail: String {
            switch self {
            case let .tap(element): "tap \"\(element.label)\""
            case let .scroll(direction): direction == .below ? "scroll down" : "scroll up"
            case let .type(text): "type \"\(text)\""
            case .home: "press home"
            case let .launch(_, name): "open \(name)"
            case .wait: "wait for the screen to settle"
            }
        }
    }

    private struct PlanError: Error, CustomStringConvertible {
        let description: String
    }

    /// Turn Jev's typed answers into a concrete plan, consuming only the
    /// speculative branches that this step's action actually needs.
    private func resolve(
        action: JevAction,
        response: JevResponse,
        observation: JevObservation,
        textCandidates: [String]
    ) throws -> Plan {
        switch action {
        case .tap:
            guard let choice = response[JevQuestions.target]?.choice, choice != "none" else {
                throw PlanError(description: "Jev chose to tap but selected no element")
            }
            guard let element = observation.element(id: choice) else {
                throw PlanError(description: "Jev selected unknown element \(choice)")
            }
            return .tap(element)

        case .scrollDown:
            return .scroll(.below)

        case .scrollUp:
            return .scroll(.above)

        case .typeText:
            guard let choice = response[JevQuestions.textSpan]?.choice, choice != "none" else {
                throw PlanError(description: "Jev chose to type but selected no text")
            }
            let index = Int(choice.dropFirst()) ?? 0
            guard index >= 1, index <= textCandidates.count else {
                throw PlanError(description: "Jev selected unknown text candidate \(choice)")
            }
            return .type(textCandidates[index - 1])

        case .pressHome:
            return .home

        case .openApp:
            guard let bundleId = response[JevQuestions.app]?.choice, bundleId != "none" else {
                throw PlanError(description: "Jev chose to open an app but selected none")
            }
            let name = installedApps.first { $0.bundleId == bundleId }?.name ?? bundleId
            return .launch(bundleId: bundleId, name: name)

        case .wait:
            return .wait

        case .finish:
            throw PlanError(description: "finish is handled before resolution")
        }
    }

    private func execute(_ plan: Plan) async throws {
        switch plan {
        case let .tap(element): try await actuator.tap(at: element.point)
        case let .scroll(direction): try await actuator.scroll(reveal: direction)
        case let .type(text): try await actuator.type(text)
        case .home: try await actuator.pressHome()
        case let .launch(bundleId, _): try await actuator.launch(bundleId: bundleId)
        case .wait: break
        }
    }

    // MARK: Reporting

    private func report(
        _ index: Int, _ action: JevAction, _ confidence: Double, _ detail: String,
        _ done: Double, _ blocked: Double, _ risky: Double, _ executed: Bool,
        _ response: JevResponse
    ) {
        onStep(
            Step(
                index: index,
                action: action,
                actionConfidence: confidence,
                detail: detail,
                done: done,
                blocked: blocked,
                risky: risky,
                executed: executed,
                inputTokens: response.usage?.inputTokens ?? 0
            )
        )
    }

    private func pct(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
