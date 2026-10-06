import Foundation

/// Observed UI evidence, not a task plan or a completion oracle. No app storage,
/// website rules or model-generated summaries enter this journal.
struct JevProgress {
    struct OwnerScope: Encodable, Hashable {
        let app: String
        let document: String?
        let owner: String
        let context: String?
    }
    struct RememberedOwner: Encodable {
        let scope: OwnerScope
        var previouslyObservedValues: [String]
    }
    struct ControlMemory: Encodable {
        let meaning = "Historical verbatim accessibility observations from this controller run, not current facts or proof of action safety. Current observations take precedence. Unchanged owner values do not prove no effect elsewhere."
        let owners: [RememberedOwner]
    }
    fileprivate struct OwnerTransition {
        let scope: OwnerScope
        let action: String
        let before: String
        var after: String?
    }
    fileprivate struct AttemptedEdge {
        let scope: OwnerScope
        let source: String
        let action: String
    }
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
        fileprivate var ownerTransition: OwnerTransition? = nil
        enum CodingKeys: String, CodingKey {
            case action, sourceApp, sourceDocument, targetLabel, beforeControls
            case observedApp, observedDocument, afterControls, screenChanged
        }
    }
    struct Snapshot: Encodable {
        let documentVisits: [Visit]
        let outcomes: [Outcome]
        var controlMemory: ControlMemory? = nil
        fileprivate var attemptedEdges: [AttemptedEdge] = []
        enum CodingKeys: String, CodingKey { case documentVisits, outcomes, controlMemory }
        var history: [JevHistoryEntry] {
            outcomes.map { JevHistoryEntry(action: $0.action, changedScreen: $0.screenChanged,
                fromDocument: $0.sourceDocument, toDocument: $0.observedDocument) }
        }

        /// nil means the current owner cannot be associated unambiguously.
        /// This records acknowledged input, not guaranteed current effects;
        /// even an unresolved subsequent observation counts as already tried.
        func hasRecordedTransition(for element: JevElement, in observation: JevObservation) -> Bool? {
            guard controlMemory != nil, let action = element.customAction else { return nil }
            let scope = JevProgress.scope(for: element, in: observation)
            guard controlMemory?.owners.contains(where: { $0.scope == scope }) == true else { return nil }
            guard let value = JevProgress.ownerValues(in: observation)[scope] else { return nil }
            return attemptedEdges.contains { $0.scope == scope && $0.source == value && $0.action == action.name }
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
            if controlMemory != nil, let action = element.customAction {
                let scope = JevProgress.scope(for: element, in: observation)
                if let value = JevProgress.ownerValues(in: observation)[scope] {
                    let previous = outcomes.compactMap(\.ownerTransition).filter {
                        $0.scope == scope && $0.action == action.name && $0.before == value
                    }.compactMap(\.after)
                    let counts = Dictionary(grouping: previous, by: { $0 }).mapValues(\.count)
                    let summary = counts.keys.sorted().map { "after owner value \"\($0)\": \(counts[$0]!) executions" }
                    let withoutOutcome = hasRecordedTransition(for: element, in: observation) == true
                        ? "acknowledged input recorded; subsequent outcome not retained in recent journal"
                        : "none recorded (outcome unknown)"
                    evidence += "; observed prior executions from this exact owner value: "
                        + (summary.isEmpty ? withoutOutcome : summary.joined(separator: "; "))
                    evidence += "; unchanged owner value is not proof of no effect elsewhere"
                }
            }
            return evidence
        }
    }

    private(set) var documentVisits: [Visit] = []
    private(set) var outcomes: [Outcome] = []
    let rememberControls: Bool
    private var rememberedOwners: [RememberedOwner] = []
    /// Acknowledged inputs, not future-effect claims. Global LRU bound is
    /// 512 entries across eight retained owner scopes.
    private var attemptedEdges: [AttemptedEdge] = []
    private var currentOwners: Set<OwnerScope> = []
    init(rememberControls: Bool = false) { self.rememberControls = rememberControls }
    var snapshot: Snapshot {
        let visibleMemory = rememberedOwners.filter { currentOwners.contains($0.scope) }
        return Snapshot(documentVisits: documentVisits, outcomes: outcomes,
            controlMemory: rememberControls && !visibleMemory.isEmpty ? ControlMemory(owners: visibleMemory) : nil,
            attemptedEdges: attemptedEdges)
    }

    mutating func observe(_ observation: JevObservation) {
        let ownerValues = rememberControls ? Self.ownerValues(in: observation) : [:]
        if rememberControls {
            currentOwners = Set(ownerValues.keys)
            // Deterministic LRU bounds: eight semantic owner scopes and 128
            // distinct verbatim values per scope. No values are interpreted.
            for scope in ownerValues.keys.sorted(by: { ($0.owner, $0.context ?? "") < ($1.owner, $1.context ?? "") }) {
                var memory: RememberedOwner
                if let index = rememberedOwners.firstIndex(where: { $0.scope == scope }) {
                    memory = rememberedOwners.remove(at: index)
                } else {
                    memory = RememberedOwner(scope: scope, previouslyObservedValues: [])
                }
                let value = ownerValues[scope]!
                memory.previouslyObservedValues.removeAll { $0 == value }
                memory.previouslyObservedValues.append(value)
                if memory.previouslyObservedValues.count > 128 { memory.previouslyObservedValues.removeFirst() }
                rememberedOwners.append(memory)
                if rememberedOwners.count > 8 {
                    let evicted = rememberedOwners.removeFirst().scope
                    attemptedEdges.removeAll { $0.scope == evicted }
                }
            }
        }
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
        if let transition = outcomes[last].ownerTransition {
            outcomes[last].ownerTransition?.after = ownerValues[transition.scope]
        }
    }

    /// Call only after acknowledged execution. Passive waits and rejected input
    /// do not replace the action whose subsequent observations are being read.
    mutating func executed(_ action: String, target: JevElement?, before: JevObservation) {
        observe(before)
        outcomes.append(Outcome(action: action, sourceApp: before.foregroundApp,
            sourceDocument: before.documentTitle, targetLabel: target?.label,
            beforeControls: Self.controls(before), targetKey: target.map(Self.key),
            beforeSignature: before.signature, completeBefore: before.completenessIssue == nil))
        if rememberControls, let target, let named = target.customAction {
            let scope = Self.scope(for: target, in: before)
            if let value = Self.ownerValues(in: before)[scope], value == named.ownerValue {
                outcomes[outcomes.count - 1].ownerTransition = OwnerTransition(
                    scope: scope, action: named.name, before: value)
                let edge = AttemptedEdge(scope: scope, source: value, action: named.name)
                if let existing = attemptedEdges.firstIndex(where: { $0.scope == scope && $0.source == value && $0.action == named.name }) {
                    attemptedEdges.remove(at: existing)
                }
                attemptedEdges.append(edge)
                if attemptedEdges.count > 512 { attemptedEdges.removeFirst() }
            }
        }
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

    static func scope(for element: JevElement, in observation: JevObservation) -> OwnerScope {
        OwnerScope(app: observation.foregroundApp, document: observation.documentTitle,
            owner: element.customAction?.ownerLabel ?? element.label, context: element.context)
    }

    /// Match an action group to exactly one exposed owner. Semantic scope is
    /// useful for recalling text, never a substitute for native target freshness.
    private static func ownerValues(in observation: JevObservation) -> [OwnerScope: String] {
        guard observation.completenessIssue == nil else { return [:] }
        let groups = Dictionary(grouping: observation.elements.filter { $0.customAction != nil }) {
            scope(for: $0, in: observation)
        }
        var result: [OwnerScope: String] = [:]
        for (scope, actions) in groups {
            let owners = observation.elements.filter {
                $0.customAction == nil && $0.label == scope.owner
                    && [$0.context, $0.label].compactMap { $0 }.joined(separator: " > ") == scope.context
            }
            guard owners.count == 1, let value = owners[0].value,
                  actions.allSatisfy({ $0.customAction?.ownerValue == value }),
                  Set(actions.compactMap { $0.customAction?.name }).count == actions.count else { continue }
            result[scope] = value
        }
        return result
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
