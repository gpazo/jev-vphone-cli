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
        /// When Jev itself chooses to stop, the `done` probability at or above
        /// which that counts as success rather than giving up.
        var finishAccepted = 0.5
        /// Hand back to the human at or above this `blocked` probability.
        ///
        /// Measured on real permission dialogs, which sat at 0.54-0.59 — just
        /// under the old 0.6, so the agent granted location access on its own.
        /// Handing those back is the whole point of the gate.
        var blocked = 0.45
        /// Cap on interstitials dismissed in code, so a screen that keeps
        /// re-presenting one cannot loop.
        var maxInterstitials = 4
        /// Consecutive scrolls before the loop is treated as lost.
        ///
        /// Stuck detection cannot catch this: every scroll changes the screen,
        /// so it looks like progress. A real run scrolled eleven times in a
        /// row hunting for a settings row, turning a six-step task into
        /// twenty-four.
        var maxConsecutiveScrolls = 6
        /// Require confirmation at or above this `risky` probability.
        var risky = 0.5
        /// Below this action confidence, stop rather than guess — but only
        /// when the step is consequential, see `confirmUncertainAboveRisk`.
        /// Two equally good ways to do the same safe thing split the
        /// probability between them, which is not a reason to give up.
        var stopBelowConfidence = 0.5
        /// Between the two, act only after confirmation — but only when the
        /// step is also somewhat consequential, see `confirmUncertainAboveRisk`.
        var confirmBelowConfidence = 0.85
        /// Uncertainty alone is not worth interrupting for when the action is
        /// plainly reversible: getting it wrong costs a step, not damage.
        /// Observed benign navigation sits at 0.80-0.99 confidence with risk
        /// near 0.03, which would otherwise prompt constantly.
        var confirmUncertainAboveRisk = 0.15
        var maxSteps = 25
        /// Identical screens in a row before declaring the loop stuck.
        var stuckLimit = 3
        /// Fixed pause after acting, before the first re-observation.
        var settleMilliseconds = 400
        /// How long to keep re-observing while the screen still looks
        /// identical to the one just acted on.
        var settleTimeoutMilliseconds = 2500
        /// Gap between those re-observations.
        var settlePollMilliseconds = 250

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
    /// Reads observed device state, so "did it work" is answered by fact
    /// rather than by the model's reading of its own screenshot.
    var facts: (any JevFactProvider)?
    /// Types by tapping the on-screen keyboard, where the target has no
    /// working key-event channel. Falls back to the actuator when absent.
    var typist: JevKeyboardTypist?
    /// Populated from `facts` each step; shown to the model separately from
    /// what the screen appears to say.
    private(set) var verifiedFacts: [String] = []
    /// Asked before a risky or low-confidence action. Returning false stops.
    var confirm: @MainActor (String) async -> Bool = { _ in false }
    /// Called after every step, for live output.
    var onStep: @MainActor (Step) -> Void = { _ in }

    private var history: [JevHistoryEntry] = []
    private var recentSignatures: [String] = []
    private var interstitialsDismissed = 0
    private var consecutiveScrolls = 0
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

        // Baseline before anything is touched, so later readings describe
        // what this run changed rather than how the device happened to be.
        let baseline = await facts?.snapshot() ?? [:]

        var lastSignature: String?

        for index in 1 ... policy.maxSteps {
            let observation: JevObservation
            do {
                observation = try await observeSettled(after: lastSignature)
            } catch {
                return .stopped(reason: "could not observe the phone: \(error)", steps: index - 1)
            }
            if let previous = lastSignature, let last = history.indices.last {
                history[last] = JevHistoryEntry(
                    action: history[last].action,
                    changedScreen: observation.signature != previous
                )
            }
            lastSignature = observation.signature

            // Clear interstitials before asking anything: they are not a
            // judgment, and they otherwise eat a step each.
            if interstitialsDismissed < policy.maxInterstitials,
               let dismissal = interstitialDismissal(in: observation)
            {
                interstitialsDismissed += 1
                _ = await tapFindingControl(dismissal, in: observation)
                history.append(
                    JevHistoryEntry(action: "dismissed \"\(dismissal.label)\"", changedScreen: true)
                )
                lastSignature = nil
                continue
            }

            if let facts {
                verifiedFacts = await facts.changes(since: baseline)
            }

            let state = JevState(
                goal: goal,
                device: device(for: observation),
                foregroundApp: observation.foregroundApp,
                observationSource: observation.source.rawValue,
                elements: observation.elements.map(\.described),
                history: history,
                verifiedFacts: verifiedFacts.isEmpty ? nil : verifiedFacts
            )

            // A failed request ends the run cleanly rather than throwing out
            // of it — the caller still gets the steps and cost so far.
            let response: JevResponse
            do {
                response = try await client.ask(
                    state: state,
                    questions: JevQuestions.build(
                        observation: observation,
                        apps: installedApps,
                        textCandidates: textCandidates,
                        hasVerifiedFacts: !verifiedFacts.isEmpty
                    )
                )
            } catch {
                return .stopped(reason: "Jev request failed: \(error)", steps: index)
            }
            totalInputTokens += response.usage?.inputTokens ?? 0

            let doneP = response[JevQuestions.done]?.noul ?? 0
            let blockedP = response[JevQuestions.blocked]?.noul ?? 0
            let riskyP = response[JevQuestions.risky]?.noul ?? 0

            let offeredActions = JevQuestions.availableActions(
                observation: observation, apps: installedApps, textCandidates: textCandidates
            ).map(\.rawValue)

            guard let actionAnswer = response[JevQuestions.action] else {
                return .stopped(reason: "Jev returned no action answer", steps: index)
            }
            if let failure = actionAnswer.validated(against: offeredActions) {
                return .stopped(reason: "unusable action answer — \(failure)", steps: index)
            }
            guard let raw = actionAnswer.choice, let action = JevAction(rawValue: raw) else {
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
                return doneP >= policy.finishAccepted
                    ? .achieved(steps: index)
                    : .stopped(reason: "Jev stopped without the goal being met", steps: index)
            }

            // Scrolling forever is its own failure: it changes the screen
            // every time, so it reads as progress to every other guard.
            if action == .scrollDown || action == .scrollUp {
                consecutiveScrolls += 1
                if consecutiveScrolls > policy.maxConsecutiveScrolls {
                    report(index, action, confidence, "scrolling without progress", doneP, blockedP, riskyP, false, response)
                    return .stopped(
                        reason: "scrolled \(consecutiveScrolls) times in a row without finding anything",
                        steps: index
                    )
                }
            } else {
                consecutiveScrolls = 0
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

            // ── Can this even work? ──
            //
            // The gates below ask whether we *should* act. This asks whether
            // the action is possible at all, which is a different question
            // and one code can often answer from the observation.
            if let refusal = infeasible(plan) {
                report(index, action, confidence, plan.detail, doneP, blockedP, riskyP, false, response)
                return .stopped(reason: refusal, steps: index)
            }

            // ── Gates ──

            if confidence < policy.stopBelowConfidence,
               riskyP >= policy.confirmUncertainAboveRisk
            {
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
            } else if confidence < policy.confirmBelowConfidence,
                      riskyP >= policy.confirmUncertainAboveRisk
            {
                needsConfirmation = true
                reason = "uncertain (confidence \(pct(confidence)), risky \(pct(riskyP)))"
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

            var executable = plan
            if case let .tap(element) = plan {
                switch await revalidate(element) {
                case let .fresh(current):
                    executable = .tap(current)
                case let .stale(reason):
                    // The screen moved on between the judgment and the touch.
                    // Acting now would act on something Jev never saw.
                    report(index, action, confidence, plan.detail, doneP, blockedP, riskyP, false, response)
                    history.append(
                        JevHistoryEntry(
                            action: "skipped \(plan.detail) — \(reason)",
                            changedScreen: true
                        )
                    )
                    lastSignature = nil
                    continue
                }
            }

            var detail = plan.detail
            if case let .tap(element) = executable {
                let result = await tapFindingControl(element, in: observation)
                if result.why != "label" {
                    detail += " (\(result.why))"
                }
                // The retry already re-observed, so the next step's settle has
                // nothing left to wait for.
                lastSignature = nil
            } else {
                try await execute(executable)
            }

            report(index, action, confidence, detail, doneP, blockedP, riskyP, true, response)
            history.append(JevHistoryEntry(action: detail, changedScreen: nil))

            try? await Task.sleep(nanoseconds: UInt64(policy.settleMilliseconds) * 1_000_000)
        }


        return .exhausted(steps: policy.maxSteps)
    }

    // MARK: Interstitials

    /// Buttons that decline whatever is being offered.
    ///
    /// Declining is always the neutral choice, so tapping one needs no
    /// judgment — which matters because apps throw these constantly on first
    /// launch (dictation prompts, tracking prompts, promos) and each one
    /// otherwise costs a model call and a step. Anything that *accepts* is
    /// deliberately absent: granting a permission is consequential and stays
    /// behind the `blocked` gate.
    private static let decliningLabels: Set<String> = [
        "not now", "skip", "maybe later", "later", "dismiss", "no thanks",
        "don't allow", "dont allow", "ask app not to track",
    ]

    /// A declining button on screen, if this looks like an interstitial.
    ///
    /// Requires a sparse screen: a declining label among many elements is
    /// more likely ordinary UI than a sheet demanding an answer.
    private func interstitialDismissal(in observation: JevObservation) -> JevElement? {
        guard observation.elements.count <= 14 else { return nil }
        return observation.elements.first { element in
            Self.decliningLabels.contains(
                element.label.lowercased().trimmingCharacters(in: .whitespaces)
            )
        }
    }

    // MARK: Tapping

    /// Where a control might be, given where its label is.
    private struct TapCandidate {
        let point: CGPoint
        /// Named in step output so a retry is visible rather than mysterious.
        let why: String
    }

    /// Tap an element, retrying where the control actually lives when the
    /// first attempt changes nothing.
    ///
    /// OCR reports where an element's *text* is. The control it labels may be
    /// somewhere else, and where depends on the control type, which the text
    /// does not reveal — measured on iOS 18.5, a Settings switch sits about
    /// 90% across its row while a home screen icon sits about 5% of screen
    /// height above its label.
    ///
    /// Rather than guess an offset up front — a wrong guess fails silently —
    /// this taps the label and lets the screen say whether it worked. Each
    /// retry costs one observation and no model call, and only happens after
    /// a tap has provably done nothing, so the point being retried is one the
    /// screen just ignored.
    ///
    /// Returns whether anything changed.
    private func tapFindingControl(
        _ element: JevElement, in observation: JevObservation
    ) async -> (changed: Bool, why: String) {
        let before = observation.signature

        for candidate in tapCandidates(for: element, in: observation) {
            try? await actuator.tap(at: candidate.point)
            try? await Task.sleep(nanoseconds: UInt64(policy.settleMilliseconds) * 1_000_000)

            // No observation means no evidence it failed; assume it landed
            // rather than tapping again somewhere else.
            guard let after = try? await provider.observe() else {
                return (true, candidate.why)
            }
            if after.signature != before {
                return (true, candidate.why)
            }
        }
        return (false, "no effect")
    }

    /// The label point first, then the places a control hides relative to it.
    ///
    /// Only OCR needs the alternatives: an accessibility tree reports the
    /// control's own frame, so its point is already right.
    private func tapCandidates(
        for element: JevElement, in observation: JevObservation
    ) -> [TapCandidate] {
        var candidates = [TapCandidate(point: element.point, why: "label")]
        guard observation.source == .ocr else { return candidates }

        let bounds = observation.bounds
        guard bounds.width > 0, bounds.height > 0 else { return candidates }

        let rowControl = TapCandidate(
            point: CGPoint(x: bounds.minX + bounds.width * 0.90, y: element.point.y),
            why: "row control"
        )
        let aboveLabel = TapCandidate(
            point: CGPoint(x: element.point.x, y: element.point.y - bounds.height * 0.05),
            why: "above label"
        )

        // A label hugging the left edge reads as a list row, whose control is
        // at the far right; anything more centred reads as an icon caption,
        // whose control is above it.
        let isLeftAligned = element.point.x < bounds.minX + bounds.width * 0.45
        candidates.append(contentsOf: isLeftAligned ? [rowControl, aboveLabel] : [aboveLabel, rowControl])
        return candidates
    }

    // MARK: Freshness

    /// What a re-check of the chosen target found.
    private enum Freshness {
        /// Still the element that was judged; carries current coordinates,
        /// which may differ from those observed a moment ago.
        case fresh(JevElement)
        /// Gone, or no longer the thing that was judged.
        case stale(String)
    }

    /// Re-resolve the target immediately before acting on it.
    ///
    /// Time passes between observing a screen, asking Jev about it, and
    /// touching it — and phones animate constantly. Two cases must be told
    /// apart, following browser-use's jev-ultrafast:
    ///
    /// - The element merely **moved**. Its identity is intact, so use its
    ///   current position and act. Re-deciding would waste a call on an
    ///   unchanged situation.
    /// - The element **changed or vanished**. What Jev judged is not what is
    ///   there now, so the decision is void and the situation must be judged
    ///   again.
    ///
    /// Identity is the signature — role, label and value — not the id, which
    /// is positional and renumbers whenever the screen reflows. Because the
    /// signature includes the value, a switch that flipped between the
    /// decision and the touch correctly reads as stale rather than being
    /// toggled back.
    private func revalidate(_ element: JevElement) async -> Freshness {
        guard let observation = try? await provider.observe() else {
            // Cannot check. Acting on a slightly old position beats refusing
            // to act because an observation failed.
            return .fresh(element)
        }

        if let current = observation.element(id: element.id),
           current.signature == element.signature
        {
            return .fresh(current)
        }
        if let current = observation.elements.first(where: { $0.signature == element.signature }) {
            return .fresh(current)
        }
        return .stale("\"\(element.label)\" is no longer on screen as it was judged")
    }

    // MARK: Observation

    /// Observe, giving the screen a chance to actually change first.
    ///
    /// Asking about a screen identical to the one just acted on buys the same
    /// judgment twice. Polling until it changes is also faster than a fixed
    /// sleep, since most transitions finish well inside the timeout.
    ///
    /// An unchanged screen is a legitimate outcome — a control that does not
    /// re-render, a tap that missed — so this gives up and proceeds rather
    /// than looping, and lets stuck detection make the call.
    private func observeSettled(after previous: String?) async throws -> JevObservation {
        var observation = try await provider.observe()
        guard let previous else { return observation }

        let deadline = Date().addingTimeInterval(Double(policy.settleTimeoutMilliseconds) / 1000)
        while Date() < deadline {
            if observation.signature != previous {
                // Changed — but a launching app shows a splash before its real
                // first screen, and judging that produces "nothing to tap". So
                // wait for the screen to stop changing, not merely to change.
                try? await Task.sleep(nanoseconds: UInt64(policy.settlePollMilliseconds) * 1_000_000)
                let again = try await provider.observe()
                if again.signature == observation.signature { return again }
                observation = again
                continue
            }
            try? await Task.sleep(nanoseconds: UInt64(policy.settlePollMilliseconds) * 1_000_000)
            observation = try await provider.observe()
        }
        return observation
    }

    /// What the machine itself can do, and what this observation can and
    /// cannot see.
    ///
    /// Without this the model has no way to know that typing needs a focused
    /// field, or that an OCR observation simply omits controls with no text —
    /// it would read their absence as absence from the screen.
    private func device(for observation: JevObservation) -> JevDevice {
        var constraints = [
            "Only the elements listed in `elements` can be acted on this step; anything not listed cannot be reached.",
            "Text can only be typed into a field that is already focused. Tap the field before typing into it.",
            "There is no hardware back button. Go back by tapping an on-screen back control.",
            "Scrolling reveals content outside the visible area, so elements that are not listed may still exist above or below.",
        ]

        switch observation.source {
        case .accessibility:
            constraints.append(
                "`elements` comes from the accessibility tree: controls without visible text are included, and `value` reflects real on/off state."
            )
        case .ocr:
            constraints.append(
                "`elements` comes from reading text off the screen. A control with no text label does not appear at all, and a switch's on/off state cannot be seen — absence from this list does not mean absence from the screen."
            )
            constraints.append(
                "Each element sits where its *text* is, which is not always where the control is: a home screen icon is above its label, and tapping the label does nothing. Launching an app by identifier is more reliable than tapping its icon."
            )
        }

        return JevDevice(
            kind: "iPhone running iOS in a virtual machine, driven by synthetic touch events",
            screen: "\(Int(observation.screen.width))x\(Int(observation.screen.height)) pixels",
            constraints: constraints
        )
    }

    // MARK: Feasibility

    /// Refuse an action the observation says cannot work, and say why.
    ///
    /// Mostly empty by design: an action with no valid target is never
    /// offered in the first place (see `JevQuestions.availableActions`), which
    /// is more reliable than letting the model choose and refusing afterwards.
    /// What remains is a consistency check between question and resolution.
    private func infeasible(_ plan: Plan) -> String? {
        switch plan {
        // Defence in depth rather than a live check: the app options offered
        // to Jev are built from this same list, so a selection outside it
        // means the question and the resolution have drifted apart.
        case let .launch(bundleId, _):
            guard !installedApps.isEmpty else { return nil }
            return installedApps.contains { $0.bundleId == bundleId }
                ? nil
                : "Jev chose to open \(bundleId), which is not installed"

        // Scrolling is deliberately not vetoed: nothing in the observation
        // reliably says whether a view scrolls, and stuck detection already
        // catches a scroll that changes nothing.
        default:
            return nil
        }
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
            // No target usually means the screen is mid-transition rather
            // than a dead end, so wait and look again. The step budget and
            // stuck detection bound how long that can go on.
            guard let choice = response[JevQuestions.tapTarget]?.choice, choice != "none" else {
                return .wait
            }
            guard let element = observation.element(id: choice) else {
                throw PlanError(description: "Jev selected unknown element \(choice)")
            }

            // Mechanics, not judgment: the model decided to open this thing,
            // and when the thing is an installed app there is an exact way to
            // do that. Under OCR an element sits where its *text* is, so an
            // app icon's label is below the icon and tapping it misses —
            // measured on the iOS Simulator, where tapping "Settings" did
            // nothing and tapping 130px higher opened it. Launching by
            // identifier has no coordinates to get wrong, and relaunching a
            // frontmost app just brings it forward.
            if observation.source == .ocr,
               let app = installedApps.first(where: {
                   $0.name.compare(element.label, options: .caseInsensitive) == .orderedSame
               })
            {
                return .launch(bundleId: app.bundleId, name: app.name)
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
        case let .type(text):
            if let typist {
                try await typist.type(text)
            } else {
                try await actuator.type(text)
            }
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
