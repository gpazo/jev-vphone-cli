import Foundation

/// Code-owned bindings. A speculative head never depends on another head's
/// answer: selection and text candidates include both their control and value.
struct JevActionSpace {
    static let maxTargetsPerOperation = 250
    struct Target {
        let description: String
        var elementID: String?
        var value: String?
        var textID: String?
        var appID: String?
    }

    var targets: [JevAction: [String: Target]] = [:]
    var operations: [JevAction] = []

    static func head(for action: JevAction) -> String {
        switch action {
        case .tap: "tap_target"
        case .openApp: "app"
        default: action.rawValue + "_target"
        }
    }

    init(observation: JevObservation, apps: [(bundleId: String, name: String)],
         textCandidates: [String], pickerValues: [String], includeStopUnable: Bool = false) {
        func describe(_ element: JevElement) -> String {
            "\(element.id): \(element.role ?? "element") \"\(element.label)\"; current value \"\(element.value ?? "")\"; context: \(element.context ?? "")"
        }
        for element in observation.elements {
            let description = describe(element) + (observation.progress?.evidence(for: element, in: observation) ?? "")
            // The centre of a wheel is its already-selected row. Its bounded
            // selection/adjustment operations express the supported input.
            if element.isTappable, element.role != "picker" {
                targets[.tap, default: [:]][element.id] = Target(description: description, elementID: element.id)
            }
            if element.isAdjustable {
                for operation in [JevAction.dragUp, .dragDown] {
                    targets[operation, default: [:]][element.id] = Target(description: description, elementID: element.id)
                }
            }
            if element.isTextInput {
                for (index, text) in textCandidates.enumerated() where text != element.value {
                    let textID = "t\(index + 1)"
                    targets[.typeText, default: [:]]["\(element.id):\(textID)"] = Target(
                        description: "Enter \"\(text)\" in \(description)", elementID: element.id, value: text, textID: textID)
                }
            }
            if observation.supportsPickerSelection, element.role == "picker" {
                for (index, value) in pickerValues.enumerated() {
                    // Native options exclude impossible values before judgment;
                    // execution checks the same options again after each step.
                    guard let direction = try? JevPickerValues.direction(from: element.value, to: value, options: element.pickerOptions) else { continue }
                    _ = direction
                    targets[.setPickerValue, default: [:]]["\(element.id):v\(index + 1)"] = Target(
                        description: "Set \(description) to \"\(value)\"", elementID: element.id, value: value)
                }
            }
        }
        for app in apps.prefix(JevQuestions.maxAppOptions) {
            targets[.openApp, default: [:]][app.bundleId] = Target(description: "Open \(app.name)", appID: app.bundleId)
        }
        // Bound the request even on a dense page or a large field/value cross
        // product. Retain candidates deterministically; scrolling can reveal
        // more controls on a subsequent observation.
        for operation in JevAction.allCases {
            if let options = targets[operation], options.count > Self.maxTargetsPerOperation {
                let keys = options.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                targets[operation] = Dictionary(uniqueKeysWithValues:
                    keys.prefix(Self.maxTargetsPerOperation).map { ($0, options[$0]!) })
            }
        }
        operations = [.scrollDown, .scrollUp, .pressHome, .wait, .finish]
        if includeStopUnable { operations.append(.stopUnable) }
        operations += JevAction.allCases.filter { targets[$0]?.isEmpty == false }
    }
}
