@testable import vphone_cli
import CoreGraphics
import Foundation
import Testing

@MainActor
struct ControlMemoryTests {
    func observation(_ value: String?, app: String = "Viewer", document: String? = "Document",
                     context: String = "Canvas", clock: String = "0") -> JevObservation {
        let owner = JevElement(id: "owner", role: "statictext", label: "Selection", value: value,
            point: .zero, context: context)
        return JevObservation(foregroundApp: app, elements: [owner]
            + JevSimulatorObserver.customElements(for: owner, names: ["Advance", "Activate"])
            + [JevElement(id: "clock", role: "statictext", label: "Elapsed", value: clock, point: .zero)],
            bounds: CGRect(x: 0, y: 0, width: 400, height: 800), source: .accessibility,
            documentTitle: document)
    }

    func target(_ observation: JevObservation) -> JevElement {
        observation.elements.first { $0.customAction?.name == "Activate" }!
    }

    @Test func memoryIsOptInAndDoesNotChangeLegacyJournal() throws {
        let state = observation("first")
        var ordinary = JevProgress(), remembered = JevProgress(rememberControls: true)
        ordinary.executed("Activate", target: target(state), before: state)
        remembered.executed("Activate", target: target(state), before: state)
        ordinary.observe(state); remembered.observe(state)
        #expect(ordinary.snapshot.controlMemory == nil)
        let a = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ordinary.snapshot.outcomes)) as? [[String: Any]])
        let b = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(remembered.snapshot.outcomes)) as? [[String: Any]])
        #expect(NSArray(array: a).isEqual(to: b))
        #expect(try !VPhoneJevCommand.parse(["inspect"]).rememberControls)
        #expect(try VPhoneJevCommand.parse(["inspect", "--remember-controls"]).rememberControls)
    }

    @Test func distinctObservedValuesSurviveTheTwentyActionJournal() throws {
        var progress = JevProgress(rememberControls: true)
        for index in 0..<30 {
            let before = observation("value \(index)")
            progress.executed("Activate", target: target(before), before: before)
            progress.observe(observation("value \(index + 1)"))
        }
        #expect(progress.outcomes.count == 20)
        let values = try #require(progress.snapshot.controlMemory?.owners.first?.previouslyObservedValues)
        #expect(values.count == 31)
        #expect(values.contains("value 0"))
        #expect(values.last == "value 30")
    }

    @Test func pollingDeduplicatesAndValuesAreBounded() throws {
        var progress = JevProgress(rememberControls: true)
        for _ in 0..<30 { progress.observe(observation("same")) }
        #expect(progress.snapshot.controlMemory?.owners.first?.previouslyObservedValues == ["same"])
        for index in 0..<130 { progress.observe(observation("value \(index)")) }
        let values = try #require(progress.snapshot.controlMemory?.owners.first?.previouslyObservedValues)
        #expect(values.count == 128)
        #expect(values.first == "value 2")
        #expect(values.last == "value 129")
        #expect(progress.outcomes.isEmpty)
    }

    @Test func scopeIncludesAppDocumentAndOwnerContextAndEvictsAfterEight() throws {
        var progress = JevProgress(rememberControls: true)
        progress.observe(observation("first"))
        progress.observe(observation("other app", app: "Other"))
        #expect(progress.snapshot.controlMemory?.owners.first?.previouslyObservedValues == ["other app"])
        progress.observe(observation("other document", document: "Other"))
        #expect(progress.snapshot.controlMemory?.owners.first?.previouslyObservedValues == ["other document"])
        progress.observe(observation("other context", context: "Toolbar"))
        #expect(progress.snapshot.controlMemory?.owners.first?.previouslyObservedValues == ["other context"])
        progress.observe(observation("return"))
        #expect(progress.snapshot.controlMemory?.owners.first?.previouslyObservedValues == ["first", "return"])
        for index in 0..<8 { progress.observe(observation("scoped \(index)", context: "Context \(index)")) }
        progress.observe(observation("after eviction"))
        #expect(progress.snapshot.controlMemory?.owners.first?.previouslyObservedValues == ["after eviction"])
    }

    @Test func missingAmbiguousOrInconsistentOwnersCannotEstablishEvidence() throws {
        let valid = observation("before")
        var absent = valid
        absent.elements.removeAll { $0.id == "owner" }
        var duplicate = valid
        var second = valid.elements[0]; second = JevElement(id: "second", role: second.role,
            label: second.label, value: "different", point: second.point, context: second.context)
        duplicate.elements.append(second)
        var mismatched = valid
        mismatched.elements[0] = JevElement(id: "owner", role: "statictext", label: "Selection", value: "new",
            point: .zero, context: "Canvas")
        var incomplete = valid; incomplete.completenessIssue = "Missing native subtree"
        for state in [absent, duplicate, mismatched, incomplete, observation(nil)] {
            var progress = JevProgress(rememberControls: true)
            progress.executed("Activate", target: target(valid), before: valid)
            progress.observe(state)
            #expect(progress.snapshot.controlMemory == nil)
            #expect(!progress.snapshot.evidence(for: target(valid), in: state).contains("exact owner value"))
        }
        var ambiguousActions = valid
        ambiguousActions.elements.append(target(valid))
        var progress = JevProgress(rememberControls: true)
        progress.observe(ambiguousActions)
        #expect(progress.snapshot.controlMemory == nil)
    }

    @Test func unchangedOwnerDespiteClockIsOnlyLocalEvidenceAndPollingDoesNotCountActions() throws {
        var progress = JevProgress(rememberControls: true)
        let before = observation("unchanged", clock: "1")
        progress.executed("Activate", target: target(before), before: before)
        for index in 2..<6 { progress.observe(observation("unchanged", clock: "\(index)")) }
        let current = observation("unchanged", clock: "5")
        let evidence = progress.snapshot.evidence(for: target(current), in: current)
        #expect(progress.outcomes.count == 1)
        #expect(progress.outcomes[0].screenChanged == true)
        #expect(evidence.contains("after owner value \"unchanged\": 1 executions"))
        #expect(evidence.contains("not proof of no effect elsewhere"))
        #expect(progress.snapshot.controlMemory?.meaning.contains("Current observations take precedence") == true)
        progress.observe(observation("delayed change", clock: "6"))
        let restored = observation("unchanged", clock: "1")
        let delayedEvidence = progress.snapshot.evidence(for: target(restored), in: restored)
        #expect(delayedEvidence.contains("after owner value \"delayed change\": 1 executions"))
        #expect(!delayedEvidence.contains("after owner value \"unchanged\""))
    }

    @Test func transitionsAreSpecificToTheObservedSourceValue() {
        var progress = JevProgress(rememberControls: true)
        let before = observation("first")
        progress.executed("Activate", target: target(before), before: before)
        let after = observation("second")
        progress.observe(after)
        let evidence = progress.snapshot.evidence(for: target(after), in: after)
        #expect(evidence.contains("none recorded (outcome unknown)"))
        #expect(!evidence.contains("after owner value"))
    }
    @Test func acknowledgedInputIsSpecificToScopeSourceAndAction() {
        var progress = JevProgress(rememberControls: true)
        let raw = observation("selected")
        progress.observe(raw)
        #expect(progress.snapshot.hasRecordedTransition(for: target(raw), in: raw) == false)
        progress.executed("Activate", target: target(raw), before: raw)
        #expect(progress.snapshot.hasRecordedTransition(for: target(raw), in: raw) == true)
        let otherAction = raw.elements.first { $0.customAction?.name == "Advance" }!
        #expect(progress.snapshot.hasRecordedTransition(for: otherAction, in: raw) == false)
        let changed = observation("different")
        #expect(progress.snapshot.hasRecordedTransition(for: target(changed), in: changed) == false)
        for other in [observation("selected", app: "Other"), observation("selected", document: "Other"),
                      observation("selected", context: "Other")] {
            #expect(progress.snapshot.hasRecordedTransition(for: target(other), in: other) == nil)
        }
        var ambiguous = raw; ambiguous.elements.append(raw.elements[0])
        #expect(progress.snapshot.hasRecordedTransition(for: target(ambiguous), in: ambiguous) == nil)
    }

    @Test func acknowledgedEdgesSurviveJournalEvictionWithoutEnteringModelState() throws {
        var progress = JevProgress(rememberControls: true)
        let first = observation("first")
        progress.executed("Activate", target: target(first), before: first)
        for index in 0..<30 {
            let next = observation("value \(index)")
            progress.executed("Activate", target: target(next), before: next)
        }
        progress.observe(first)
        #expect(progress.outcomes.count == 20)
        #expect(progress.snapshot.hasRecordedTransition(for: target(first), in: first) == true)
        #expect(progress.snapshot.evidence(for: target(first), in: first).contains("acknowledged input recorded"))
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(progress.snapshot)) as? [String: Any])
        #expect(Set(json.keys) == ["documentVisits", "outcomes", "controlMemory"])
    }

    @Test func attemptedEdgeStoreDeduplicatesAndBoundsAllScopesTogether() {
        var progress = JevProgress(rememberControls: true)
        let first = observation("first")
        for _ in 0..<520 { progress.executed("Activate", target: target(first), before: first) }
        for index in 0..<511 {
            let next = observation("value \(index)")
            progress.executed("Activate", target: target(next), before: next)
        }
        progress.observe(first)
        #expect(progress.snapshot.hasRecordedTransition(for: target(first), in: first) == true)
        let otherScope = observation("new", context: "Other")
        progress.executed("Activate", target: target(otherScope), before: otherScope)
        progress.observe(first)
        #expect(progress.snapshot.hasRecordedTransition(for: target(first), in: first) == false)
        let retained = observation("value 0")
        progress.observe(retained)
        #expect(progress.snapshot.hasRecordedTransition(for: target(retained), in: retained) == true)
    }

    @Test func evictingOwnerScopeAlsoRemovesItsAttemptedEdges() {
        var progress = JevProgress(rememberControls: true)
        let original = observation("selected")
        progress.executed("Activate", target: target(original), before: original)
        for index in 0..<8 { progress.observe(observation("selected", context: "Other \(index)")) }
        progress.observe(original)
        #expect(progress.snapshot.hasRecordedTransition(for: target(original), in: original) == false)
    }
}
