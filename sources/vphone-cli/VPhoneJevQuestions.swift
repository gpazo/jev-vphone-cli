import Foundation

// MARK: - Action Vocabulary

/// The bounded set of things the agent can do to the phone in one step.
///
/// Named by *intent* rather than gesture — `scrollDown` rather than
/// `swipeUp` — because the model reasons about what should happen, and the
/// gesture that achieves it is code's business.
enum JevAction: String, CaseIterable {
    case tap
    case scrollDown = "scroll_down"
    case scrollUp = "scroll_up"
    case typeText = "type_text"
    case pressHome = "press_home"
    case openApp = "open_app"
    case wait
    case finish

    /// Description shown to Jev as this option's criterion.
    var criterion: String {
        switch self {
        case .tap:
            "Tap one of the elements listed in `elements` — a button, link, switch, list row or text field."
        case .scrollDown:
            "Scroll the current view to reveal content further down the page, because what is needed is probably below the visible area."
        case .scrollUp:
            "Scroll the current view back towards the top, because what is needed is probably above the visible area."
        case .typeText:
            "Type text into the text field that is currently focused. Only appropriate when a field is already accepting input."
        case .pressHome:
            "Press the hardware home button to leave the current app and return to the home screen."
        case .openApp:
            "Launch a different app directly, rather than navigating to it by tapping."
        case .wait:
            "Do nothing this step because the screen is mid-transition, loading, or otherwise not ready to act on."
        case .finish:
            "Stop. The goal has been accomplished, or it cannot be accomplished from here."
        }
    }
}

// MARK: - State

/// Exactly what Jev is shown each step.
///
/// Everything here is text, because Jev takes text only. Note what is
/// absent: no pixel coordinates, no screenshot, no ids that carry meaning.
/// The model judges the situation; code owns the mechanics.
struct JevState: Encodable {
    let goal: String
    let foregroundApp: String
    let observationSource: String
    let elements: [JevElement.Described]
    /// What has already been tried, oldest first, so the model can tell
    /// progress from repetition.
    let history: [String]
    /// Ground-truth facts code has verified, distinct from what the screen
    /// appears to show.
    let verifiedFacts: [String]?
}

// MARK: - Question Construction

enum JevQuestions {
    static let action = "action"
    static let target = "target"
    static let app = "app"
    static let textSpan = "text_span"
    static let done = "done"
    static let blocked = "blocked"
    static let risky = "risky"

    /// Cap on options offered for app launch. The API allows 255 per Choice;
    /// staying well under keeps per-step token cost predictable.
    static let maxAppOptions = 150

    /// Build one step's batch.
    ///
    /// Every question is asked over the same state and answered in parallel,
    /// including speculative ones — `target` matters only if the action turns
    /// out to be `tap`, `app` only if it is `open_app`. Code discards the
    /// branches it does not need. Each question states its own premise so it
    /// stands alone, since the questions cannot see each other's answers.
    static func build(
        observation: JevObservation,
        apps: [(bundleId: String, name: String)] = [],
        textCandidates: [String] = []
    ) -> [String: JevQuestion] {
        var questions: [String: JevQuestion] = [
            action: .choice(
                """
                An automated agent is operating an iPhone to accomplish `goal`. \
                Given what is currently on screen in `elements`, and what has already \
                been tried in `history`, what single action should it take next?
                """,
                Dictionary(uniqueKeysWithValues: JevAction.allCases.map { ($0.rawValue, $0.criterion) })
            ),
            done: .noul(
                """
                Has `goal` already been fully accomplished, as evidenced by the current \
                screen in `elements` and by `verifiedFacts`? Answer yes only if nothing \
                further needs to be done — not merely if progress has been made.
                """
            ),
            blocked: .noul(
                """
                Does the current screen require a decision a person must make themselves — \
                such as entering a password or passcode, completing two-factor \
                authentication, confirming a purchase, or accepting legal terms — rather \
                than one an automated agent should make on their behalf?
                """
            ),
            risky: .noul(
                """
                Would acting on the current screen cause a change that cannot be undone? \
                Consider deleting data, sending a message or email, making a purchase or \
                payment, signing out, erasing the device, or changing security settings. \
                Ordinary reversible navigation and settings toggles are not irreversible.
                """
            ),
        ]

        // Speculative: consumed only when the action is `tap`.
        if !observation.elements.isEmpty {
            var options: [String: String?] = [:]
            for element in observation.elements {
                options[element.id] = describe(element)
            }
            options["none"] = "No element currently on screen is the right thing to tap."

            questions[target] = .choice(
                """
                Suppose the agent taps something this step. Which of the elements listed \
                in `elements` should it tap to make progress toward `goal`? Each option \
                below is identified by the same id used in `elements`.
                """,
                options
            )
        }

        // Speculative: consumed only when the action is `open_app`.
        if !apps.isEmpty {
            var options: [String: String?] = [:]
            for app in apps.prefix(maxAppOptions) {
                options[app.bundleId] = "The \(app.name) app."
            }
            options["none"] = "No installed app is the right one to open."

            questions[app] = .choice(
                """
                Suppose the agent launches an app directly this step. Which installed app \
                should it open to make progress toward `goal`?
                """,
                options
            )
        }

        // Speculative: consumed only when the action is `type_text`.
        // Jev selects among spans code has already extracted from the goal —
        // it never generates the text itself.
        if !textCandidates.isEmpty {
            var options: [String: String?] = [:]
            for (index, candidate) in textCandidates.enumerated() {
                options["t\(index + 1)"] = "Type exactly: \(candidate)"
            }
            options["none"] = "None of these is the text that should be typed."

            questions[textSpan] = .choice(
                """
                Suppose the agent types text this step. Which of these candidate strings, \
                taken from `goal`, is the text that should be entered into the focused \
                field?
                """,
                options
            )
        }

        return questions
    }

    /// How one element is described to the model.
    private static func describe(_ element: JevElement) -> String {
        var parts = ["\"\(element.label)\""]
        if let role = element.role { parts.append("a \(role)") }
        if let value = element.value { parts.append("currently \(value)") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Text Candidates

/// Pulls candidate literal strings out of the goal.
///
/// Jev returns typed judgments, not generated text, so anything the agent
/// types must already exist as a span code can offer it. This is the
/// pre-parsed value extraction pattern: code finds candidates, the model
/// picks the intended one.
enum JevTextCandidates {
    private static let leadIns = [
        "search for ", "searching for ", "type ", "typing ", "enter ",
        "entering ", "write ", "writing ", "look up ", "query ",
    ]

    static func extract(from goal: String) -> [String] {
        var found: [String] = []

        // Quoted spans are the strongest signal.
        for pattern in ["\"([^\"]+)\"", "'([^']+)'", "\u{201C}([^\u{201D}]+)\u{201D}"] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(goal.startIndex..., in: goal)
            for match in regex.matches(in: goal, range: range) {
                guard match.numberOfRanges > 1,
                      let captured = Range(match.range(at: 1), in: goal)
                else { continue }
                found.append(String(goal[captured]))
            }
        }

        // Otherwise, whatever follows a lead-in verb.
        let lowered = goal.lowercased()
        for leadIn in leadIns {
            guard let range = lowered.range(of: leadIn) else { continue }
            let tail = String(goal[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            if !tail.isEmpty { found.append(tail) }
        }

        // De-duplicate, preserving order, and drop anything empty.
        var seen = Set<String>()
        return found.filter { candidate in
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return false }
            return true
        }
    }
}
