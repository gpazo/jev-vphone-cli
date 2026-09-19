import SwiftUI

/// A deliberately ordinary alarm app.
///
/// The iOS Simulator ships no Clock app, so this stands in for it. It uses
/// stock controls — a plain list, a `+` bar button, a wheel `DatePicker` —
/// with no concessions to make it easier to drive. A wheel picker is the
/// genuinely hard case for a tap-driven agent, which is the point: an easier
/// control would prove nothing.
///
/// Saved alarms go to `UserDefaults` so the outcome can be checked against
/// the device rather than taken from the agent's own report.
@main
struct AlarmApp: App {
    var body: some Scene {
        WindowGroup { AlarmListView() }
    }
}

struct Alarm: Identifiable, Codable {
    var id = UUID()
    var hour: Int
    var minute: Int

    var label: String {
        let suffix = hour < 12 ? "AM" : "PM"
        let display = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d %@", display, minute, suffix)
    }
}

struct AlarmListView: View {
    @State private var alarms: [Alarm] = AlarmStore.load()
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                if alarms.isEmpty {
                    Text("No Alarms").foregroundStyle(.secondary)
                }
                ForEach(alarms) { alarm in
                    HStack {
                        Text(alarm.label).font(.system(size: 40, weight: .light))
                        Spacer()
                    }
                }
            }
            .navigationTitle("Alarms")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: {
                        Image(systemName: "plus").accessibilityLabel("Add Alarm")
                    }
                }
            }
            .sheet(isPresented: $adding) {
                AddAlarmView { alarm in
                    alarms.append(alarm)
                    AlarmStore.save(alarms)
                    adding = false
                } cancel: {
                    adding = false
                }
            }
        }
    }
}

struct AddAlarmView: View {
    var save: (Alarm) -> Void
    var cancel: () -> Void

    @State private var time = Calendar.current.date(
        bySettingHour: 9, minute: 0, second: 0, of: Date()
    ) ?? Date()

    var body: some View {
        NavigationStack {
            VStack {
                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                Spacer()
            }
            .navigationTitle("Add Alarm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: cancel)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
                        save(Alarm(hour: parts.hour ?? 0, minute: parts.minute ?? 0))
                    }
                }
            }
        }
    }
}

enum AlarmStore {
    static let key = "alarms"

    static func load() -> [Alarm] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let alarms = try? JSONDecoder().decode([Alarm].self, from: data)
        else { return [] }
        return alarms
    }

    static func save(_ alarms: [Alarm]) {
        guard let data = try? JSONEncoder().encode(alarms) else { return }
        UserDefaults.standard.set(data, forKey: key)
        // A plain readable copy, so the result can be checked with
        // `defaults read` without decoding JSON.
        UserDefaults.standard.set(alarms.map(\.label).joined(separator: ", "), forKey: "alarmsDescription")
    }
}
