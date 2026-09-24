import Foundation

/// Observed UI evidence, not a task plan or a completion oracle. No app storage,
/// website rules or model-generated summaries enter this journal.
struct JevProgress {
    struct Controls: Encodable, Equatable {
        let role: String?
        let label: String
        let value: String?
        var context: String? = nil
    }
    struct Visit: Encodable, Equatable {
        let app: String
        let document: String
    }
    struct Outcome: Encodable {
        let action: String
        let sourceApp: String
        let sourceDocument: String?
        let targetLabel: String?
        let beforeControls: [Controls]
        var observedApp: String?
        var observedDocument: String?
        var afterControls: [Controls]?
        var screenChanged: Bool?
        // Local matching data are not claims about persistent native identity.
        fileprivate let targetKey: String?
        fileprivate let beforeSignature: String
        fileprivate let completeBefore: Bool
        fileprivate var afterSignature: String?
        enum CodingKeys: String, CodingKey {
            case action, sourceApp, sourceDocument, targetLabel, beforeControls
            case observedApp, observedDocument, afterControls, screenChanged
        }
    }
    struct Snapshot: Encodable {
        let documentVisits: [Visit]
        let outcomes: [Outcome]
        var history: [JevHistoryEntry] {
            outcomes.map { JevHistoryEntry(action: $0.action, changedScreen: $0.screenChanged,
                fromDocument: $0.sourceDocument, toDocument: $0.observedDocument) }
        }

        func evidence(for element: JevElement, in observation: JevObservation) -> String {
            let matches = outcomes.filter {
                $0.sourceApp == observation.foregroundApp && $0.sourceDocument == observation.documentTitle
                    && $0.targetKey == JevProgress.key(element)
            }
            var evidence = ""
            let destinations = matches.compactMap { outcome -> String? in
                guard let title = outcome.observedDocument, title != outcome.sourceDocument else { return nil }
                return title
            }
            if !matches.isEmpty {
                evidence = "; prior executions on this document: \(matches.count); subsequently observed documents: \(destinations)"
            }
            return evidence
        }
    }

    private(set) var documentVisits: [Visit] = []
    private(set) var outcomes: [Outcome] = []
    var snapshot: Snapshot { Snapshot(documentVisits: documentVisits, outcomes: outcomes) }

    mutating func observe(_ observation: JevObservation) {
        if let title = observation.documentTitle {
            let visit = Visit(app: observation.foregroundApp, document: title)
            if documentVisits.last != visit { documentVisits.append(visit) }
            if documentVisits.count > 50 { documentVisits.removeFirst() }
        }
        guard let last = outcomes.indices.last else { return }
        outcomes[last].observedApp = observation.foregroundApp
        outcomes[last].observedDocument = observation.documentTitle
        outcomes[last].afterControls = Self.controls(observation)
        outcomes[last].screenChanged = outcomes[last].beforeSignature != observation.signature
            || outcomes[last].sourceApp != observation.foregroundApp
        outcomes[last].afterSignature = observation.completenessIssue == nil ? observation.signature : nil
    }

    /// Call only after acknowledged execution. Passive waits and rejected input
    /// do not replace the action whose subsequent observations are being read.
    mutating func executed(_ action: String, target: JevElement?, before: JevObservation) {
        observe(before)
        outcomes.append(Outcome(action: action, sourceApp: before.foregroundApp,
            sourceDocument: before.documentTitle, targetLabel: target?.label,
            beforeControls: Self.controls(before), targetKey: target.map(Self.key),
            beforeSignature: before.signature, completeBefore: before.completenessIssue == nil))
        if outcomes.count > 20 { outcomes.removeFirst() }
    }

    /// Detect repeated identical short cycles, not merely revisiting a
    /// screen. Different next actions (Back then a second result, for example)
    /// remain possible. Only acknowledged input with complete observed outcomes
    /// counts; transient reads, waits and rejected inputs add no transitions.
    func repeatedCycleLength(repeating action: String, target: JevElement?, from observation: JevObservation,
                             maxLength: Int, repetitions: Int) -> Int? {
        guard observation.completenessIssue == nil, maxLength >= 2, repetitions >= 2,
              outcomes.count / repetitions >= 2 else { return nil }
        func sameTransition(_ a: Outcome, _ b: Outcome) -> Bool {
            a.action == b.action && a.targetKey == b.targetKey
                && a.sourceApp == b.sourceApp && a.sourceDocument == b.sourceDocument
                && a.beforeSignature == b.beforeSignature
                && a.observedApp == b.observedApp && a.observedDocument == b.observedDocument
                && a.afterSignature != nil && a.afterSignature == b.afterSignature
        }
        for length in 2...min(maxLength, outcomes.count / repetitions) {
            let recent = Array(outcomes.suffix(length * repetitions))
            let first = recent[0]
            guard first.action == action, first.targetKey == target.map(Self.key),
                  first.sourceApp == observation.foregroundApp,
                  first.sourceDocument == observation.documentTitle,
                  first.beforeSignature == observation.signature,
                  recent.allSatisfy({ $0.completeBefore && $0.afterSignature != nil }),
                  (length..<recent.count).allSatisfy({ sameTransition(recent[$0 % length], recent[$0]) }),
                  (0..<recent.count).allSatisfy({ index in
                      let next = recent[(index + 1) % recent.count]
                      return recent[index].observedApp == next.sourceApp
                          && recent[index].afterSignature == next.beforeSignature
                  }) else { continue }
            return length
        }
        return nil
    }

    private static func controls(_ observation: JevObservation) -> [Controls] {
        // Preserve edited values before a form disappears, with bounded context.
        let valued = observation.elements.filter { $0.isTextInput || $0.role == "picker" || $0.role == "switch" || $0.role == "slider" }
        let remaining = observation.documentTitle == nil
            ? observation.elements.filter { $0.value == nil && $0.role == "button" } : []
        var result = (valued + remaining).prefix(12).map { Controls(role: $0.role, label: $0.label, value: $0.value, context: $0.context) }
        var seen = Set<String>()
        for element in observation.elements {
            guard let action = element.customAction,
                  seen.insert("\(action.ownerLabel)|\(action.ownerValue ?? "")").inserted else { continue }
            result.insert(Controls(role: "accessibility", label: action.ownerLabel, value: action.ownerValue), at: 0)
        }
        return Array(result.prefix(12))
    }

    private static func key(_ element: JevElement) -> String {
        let context = element.context ?? ""
        // Web parent nesting can change after Back. Preserve an exposed URL
        // where available; do not derive one from a domain guess or app name.
        let range = context.range(of: #"https?://[^\s]+"#, options: .regularExpression)
        let identityContext = range.map { String(context[$0]) } ?? context
        return [element.role ?? "", element.label, identityContext].joined(separator: "|")
    }
}
