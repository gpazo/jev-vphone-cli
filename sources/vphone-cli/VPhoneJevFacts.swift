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

/// Reads synchronized guest preferences through a persistent read-only helper.
/// `defaults` remains a fallback if that connection fails.
@MainActor
struct JevSimulatorFacts: JevFactProvider {
    let udid: String
    var alarmPreferencesURL: URL?
    var preferences: JevSimulatorPreferences?

    private static let alarmPrefix = "com.jevdemo.alarm.saved."
    private static let alarmReadKey = "com.jevdemo.alarm.readable"
    private static let readPrefix = "jev.readable."

    /// Domains worth watching; fetched together over one warm connection.
    var domains: [String] = [
        "com.apple.Accessibility",
        "com.apple.Preferences",
        "NSGlobalDomain",
    ]

    func snapshot() async -> [String: String] {
        var values: [String: String] = [:]
        let warm = preferences.flatMap { try? $0.read(domains: domains) }
        for domain in domains {
            guard let reading = warm?[domain] ?? read(domain: domain) else { continue }
            values[Self.readPrefix + domain] = "true"
            for (key, value) in reading {
                values["\(domain).\(key)"] = value
            }
        }
        if let alarmPreferencesURL, let alarms = try? readAlarms(at: alarmPreferencesURL) {
            values[Self.alarmReadKey] = "true"
            for (id, time) in alarms { values[Self.alarmPrefix + id] = time }
        }
        return values
    }

    private func readAlarms(at url: URL) throws -> [String: String] {
        if let preferences {
            let container = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let data = try preferences.readData(domain: "com.jevdemo.alarm", container: container, key: "alarms")
            return try data.map(Self.savedAlarms(data:)) ?? [:]
        }
        return try Self.savedAlarms(at: url)
    }

    func changes(since baseline: [String: String]) async -> [String] {
        let current = await snapshot()
        return Self.changes(from: baseline, to: current)
    }

    static func changes(from baseline: [String: String], to current: [String: String]) -> [String] {
        var facts: [String] = []

        for (key, value) in current where baseline[key] != value {
            if key == Self.alarmReadKey || key.hasPrefix(Self.readPrefix) { continue }
            if key.hasPrefix(Self.alarmPrefix) {
                facts.append("Alarms app: saved alarm \(key.dropFirst(Self.alarmPrefix.count)) is now \(value).")
                continue
            }
            let name = key.split(separator: ".").last.map(String.init) ?? key
            if let was = baseline[key] {
                facts.append("Device setting \(name) changed from \(was) to \(value).")
            } else {
                facts.append("Device setting \(name) is now \(value).")
            }
        }
        // Keys that disappeared are changes too, and read as a reset.
        for (key, was) in baseline where current[key] == nil {
            // A failed app-file read is not proof an alarm was deleted.
            if key.hasPrefix("com.jevdemo.alarm.") { continue }
            if key.hasPrefix(Self.readPrefix) { continue }
            // A failed read is not evidence that every setting was reset.
            let readDomains = current.keys.filter { $0.hasPrefix(Self.readPrefix) }
                .map { String($0.dropFirst(Self.readPrefix.count)) }
            guard readDomains.contains(where: { key.hasPrefix($0 + ".") }) else { continue }
            let name = key.split(separator: ".").last.map(String.init) ?? key
            facts.append("Device setting \(name) was \(was) and is no longer set.")
        }

        if baseline[Self.alarmReadKey] != nil, current[Self.alarmReadKey] != nil {
            let added = current.keys.filter { $0.hasPrefix(Self.alarmPrefix) && baseline[$0] == nil }.count
            facts.append("Alarms app: \(added) new saved alarm(s) since this run began. Picker values alone are not saved alarms.")
        }

        return facts.sorted()
    }

    /// App-container preferences do not resolve through `simctl spawn defaults`.
    static func alarmPreferencesURL(udid: String) -> URL? {
        guard let path = try? VPhoneJevSimulator.simctl(["get_app_container", udid, "com.jevdemo.alarm", "data"])
            .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).appendingPathComponent("Library/Preferences/com.jevdemo.alarm.plist")
    }

    static func savedAlarms(at url: URL) throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil)
        guard let dictionary = plist as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        guard let data = dictionary["alarms"] as? Data else { return [:] }
        return try savedAlarms(data: data)
    }

    static func savedAlarms(data: Data) throws -> [String: String] {
        struct SavedAlarm: Decodable { let id: UUID; let hour: Int; let minute: Int }
        let alarms = try JSONDecoder().decode([SavedAlarm].self, from: data)
        var result: [String: String] = [:]
        for alarm in alarms {
            guard (0...23).contains(alarm.hour), (0...59).contains(alarm.minute) else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            let displayHour = alarm.hour % 12 == 0 ? 12 : alarm.hour % 12
            result[alarm.id.uuidString] = String(format: "%d:%02d %@ (%02d:%02d)",
                displayHour, alarm.minute, alarm.hour < 12 ? "AM" : "PM", alarm.hour, alarm.minute)
        }
        return result
    }

    private func read(domain: String) -> [String: String]? {
        guard let raw = try? VPhoneJevSimulator.simctl(
            ["spawn", udid, "defaults", "read", domain]
        ) else { return nil }
        return Self.parseDomain(Data(raw.utf8))
    }

    /// Decode the actual plist, so nested entries cannot masquerade as global
    /// settings and switching to the fallback does not change string quoting.
    static func parseDomain(_ data: Data) -> [String: String]? {
        guard let dictionary = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any] else { return nil }
        return dictionary.reduce(into: [:]) { result, entry in
            let value: String
            if let string = entry.value as? String { value = string }
            else if let number = entry.value as? NSNumber { value = number.stringValue }
            else { return }
            if value.count < 60 { result[entry.key] = value }
        }
    }
}
