import Foundation

struct JevPlannerObservationGuard {
    struct Node: Hashable {
        let role: String?
        let context: String?
        let label: String?
        let action: String?
        let nativePress: Bool
        let options: [String]?
        let visibility: String?
    }
    let app: String
    let document: String?
    let source: JevObservation.Source
    let structure: [Node: Int]
    let nearbyStructure: [Node: Int]
    let target: JevElement?
    let owner: JevElement?
    var expectedValue: String?

    init(observation: JevObservation, target: JevElement?, owner: JevElement?) {
        app = observation.foregroundApp; document = observation.documentTitle; source = observation.source
        structure = Self.nodes(observation.elements)
        nearbyStructure = Dictionary(grouping: observation.nearbyElements.map {
            Node(role: $0.role, context: $0.context, label: Self.passive($0.role) ? nil : $0.label,
                action: nil, nativePress: false, options: $0.pickerOptions, visibility: $0.visibility)
        }, by: { $0 }).mapValues(\.count)
        self.target = target; self.owner = owner; expectedValue = owner?.value ?? target?.value
    }
    private static func passive(_ role: String?) -> Bool {
        ["statictext", "static_text", "label", "heading", "image", "text"].contains(role?.lowercased() ?? "")
    }
    private static func nodes(_ elements: [JevElement]) -> [Node: Int] {
        Dictionary(grouping: elements.map {
            Node(role: $0.role, context: $0.context,
                label: $0.nativePress || !passive($0.role) ? $0.label : nil,
                action: $0.customAction?.name, nativePress: $0.nativePress, options: $0.pickerOptions, visibility: nil)
        }, by: { $0 }).mapValues(\.count)
    }
    func rejection(in observation: JevObservation) -> String? {
        guard observation.completenessIssue == nil else { return "incomplete observation" }
        guard observation.foregroundApp == app, observation.documentTitle == document, observation.source == source else {
            return "application, document or observation source changed"
        }
        let current = Self(observation: observation, target: nil, owner: nil)
        guard structure == current.structure, nearbyStructure == current.nearbyStructure else { return "screen structure changed" }
        if let owner {
            let matches = observation.elements.filter { $0.customAction == nil && $0.label == owner.label && $0.context == owner.context }
            guard matches.count == 1, matches[0].role == owner.role, matches[0].value == expectedValue else {
                return "named-action owner changed or became ambiguous"
            }
        } else if let target {
            let matches = observation.elements.filter {
                $0.role == target.role && $0.label == target.label && $0.context == target.context && $0.customAction == nil
            }
            guard matches.count == 1, matches[0].value == expectedValue else { return "bound control changed or became ambiguous" }
        }
        return nil
    }
}
