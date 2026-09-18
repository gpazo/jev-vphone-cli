import Foundation

// MARK: - Ground Truth

/// Observed device state, kept separate from what the screen appears to show.
///
/// The agent otherwise judges "done" from the screen alone, which fails in a
/// specific and costly way: it can accomplish the goal and not know. Measured
/// on iOS 18.5 — the agent turned Bold Text off at step 6, navigated to
/// another page at step 7, and gave up at step 8 with `done` at 0.31, because
/// the toggle it had just flipped was no longer visible.
///
/// Rather than map goals to settings keys, which does not generalise, this
/// reports what actually **changed** since the run began. That is goal
/// agnostic and it is fact: "EnhancedTextLegibilityEnabled changed from 1 to
/// 0" answers "did it work" without anyone having to anticipate the question.
@MainActor
protocol JevFactProvider {
    /// A baseline to compare later readings against.
    func snapshot() async -> [String: String]
    /// Human-readable descriptions of what has changed since `baseline`.
    func changes(since baseline: [String: String]) async -> [String]
}

// MARK: - iOS Simulator

/// Reads device preferences through `simctl spawn defaults`.
@MainActor
struct JevSimulatorFacts: JevFactProvider {
    let udid: String

    /// Domains worth watching. Deliberately few: every domain costs a
    /// subprocess per step, and these cover the settings a phone-control goal
    /// usually touches.
    var domains: [String] = [
        "com.apple.Accessibility",
        "com.apple.Preferences",
        "NSGlobalDomain",
    ]

    func snapshot() async -> [String: String] {
        var values: [String: String] = [:]
        for domain in domains {
            for (key, value) in read(domain: domain) {
                values["\(domain).\(key)"] = value
            }
        }
        return values
    }

    func changes(since baseline: [String: String]) async -> [String] {
        let current = await snapshot()
        var facts: [String] = []

        for (key, value) in current where baseline[key] != value {
            let name = key.split(separator: ".").last.map(String.init) ?? key
            if let was = baseline[key] {
                facts.append("Device setting \(name) changed from \(was) to \(value).")
            } else {
                facts.append("Device setting \(name) is now \(value).")
            }
        }
        // Keys that disappeared are changes too, and read as a reset.
        for (key, was) in baseline where current[key] == nil {
            let name = key.split(separator: ".").last.map(String.init) ?? key
            facts.append("Device setting \(name) was \(was) and is no longer set.")
        }

        return facts.sorted()
    }

    /// `defaults read <domain>` emits an old-style plist; parse the flat
    /// scalar entries and ignore nested containers, which are noise here.
    private func read(domain: String) -> [String: String] {
        guard let raw = try? VPhoneJevSimulator.simctl(
            ["spawn", udid, "defaults", "read", domain]
        ) else { return [:] }

        var values: [String: String] = [:]
        for line in raw.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasSuffix(";"),
                  let equals = trimmed.firstIndex(of: "=")
            else { continue }

            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
                .trimmingCharacters(in: .whitespaces)

            // Skip containers and anything unhelpfully long.
            guard !value.hasPrefix("{"), !value.hasPrefix("("), value.count < 60,
                  !key.isEmpty, !key.contains(" ")
            else { continue }
            values[key] = value
        }
        return values
    }
}
