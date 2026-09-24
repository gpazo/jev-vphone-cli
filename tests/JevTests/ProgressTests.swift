@testable import vphone_cli
import CoreGraphics
import Foundation
import Testing

@MainActor
struct ProgressTests {
    func page(_ title: String?, app: String = "Browser", elements: [JevElement] = []) -> JevObservation {
        JevObservation(foregroundApp: app, elements: elements,
            bounds: CGRect(x: 0, y: 0, width: 400, height: 800), source: .accessibility,
            documentTitle: title)
    }
    func link(_ context: String = "Publisher https://first.example Article") -> JevElement {
        JevElement(id: "e1", role: "link", label: "Article", value: nil,
            point: CGPoint(x: 20, y: 20), context: context)
    }

    @Test func delayedNavigationStaysWithExecutionAcrossPassiveObservations() {
        var progress = JevProgress()
        let search = page("Results", elements: [link()])
        progress.observe(search)
        progress.executed("tap Article", target: link(), before: search)
        progress.observe(page(nil)) // transient keyboard/chrome/tree gap
        progress.observe(search) // old body while navigation starts
        progress.observe(page("First destination"))
        #expect(progress.outcomes.count == 1)
        #expect(progress.outcomes[0].observedDocument == "First destination")
        #expect(progress.documentVisits.map(\.document) == ["Results", "First destination"])
        progress.executed("return", target: nil, before: page("First destination"))
        progress.observe(search)
        #expect(progress.outcomes[0].observedDocument == "First destination")
        #expect(progress.documentVisits.map(\.document) == ["Results", "First destination", "Results"])
        #expect(progress.snapshot.history[0].toDocument == "First destination")
        #expect(progress.snapshot.history[1].fromDocument == "First destination")
        #expect(progress.snapshot.history[1].toDocument == "Results")
    }

    @Test func priorNavigationEvidenceIsScopedAndSurvivesParentRenesting() {
        var progress = JevProgress()
        let search = page("Results", elements: [link()])
        progress.executed("tap Article", target: link(), before: search)
        progress.observe(page("First destination"))
        let nested = link("Results > Publisher https://first.example Article > Article")
        #expect(progress.snapshot.evidence(for: nested, in: search).contains("First destination"))
        #expect(progress.snapshot.evidence(for: link("https://second.example"), in: search).isEmpty)
        #expect(progress.snapshot.evidence(for: nested, in: page("Other results")).isEmpty)
        #expect(progress.snapshot.evidence(for: nested, in: page("Results", app: "Other app")).isEmpty)
    }

    @Test func unchangedInputDoesNotInventADestinationOrCompletion() {
        var progress = JevProgress()
        let search = page("Results", elements: [link()])
        progress.executed("tap Article", target: link(), before: search)
        progress.observe(search)
        #expect(progress.outcomes[0].screenChanged == false)
        #expect(progress.snapshot.evidence(for: link(), in: search).contains("documents: []"))
        #expect(progress.documentVisits.count == 1)
    }

    @Test func formValuesRemainEvidenceAfterDismissal() {
        let field = JevElement(id: "field", role: "textfield", label: "Title", value: "A note", point: .zero, context: "New item")
        var progress = JevProgress()
        progress.executed("Save", target: nil, before: page(nil, app: "Notes", elements: [field]))
        progress.observe(page(nil, app: "Notes"))
        #expect(progress.outcomes[0].beforeControls.first?.value == "A note")
        #expect(progress.outcomes[0].beforeControls.first?.context == "New item")
        #expect(progress.outcomes[0].afterControls?.isEmpty == true)
        // The journal records observation, never certifies storage or task completion.
        #expect(progress.outcomes[0].observedDocument == nil)
    }

    @Test(arguments: [2, 3, 4])
    func cyclesRequireRepeatedActionsAndObservedTransitions(length: Int) {
        var progress = JevProgress()
        let pages = (0..<length).map { page("Page \($0)", elements: [link()]) }
        for index in 0..<(2 * length) {
            let offset = index % length
            // Passive reads cannot create actions or prematurely trip the guard.
            progress.observe(pages[offset]); progress.observe(pages[offset])
            #expect(progress.repeatedCycleLength(repeating: "visit \(offset)", target: link(), from: pages[offset], maxLength: 4, repetitions: 2) == nil)
            progress.executed("visit \(offset)", target: link(), before: pages[offset])
            progress.observe(pages[(offset + 1) % length])
        }
        #expect(progress.repeatedCycleLength(repeating: "visit 0", target: link(), from: pages[0], maxLength: 4, repetitions: 2) == length)
        #expect(progress.repeatedCycleLength(repeating: "different action", target: link(), from: pages[0], maxLength: 4, repetitions: 2) == nil)
        #expect(progress.repeatedCycleLength(repeating: "visit 0", target: link("https://other.example"), from: pages[0], maxLength: 4, repetitions: 2) == nil)
        #expect(progress.repeatedCycleLength(repeating: "visit 0", target: link(), from: page("Page 0", app: "Other app", elements: [link()]), maxLength: 4, repetitions: 2) == nil)
    }

    @Test func incompleteEvidenceCannotCertifyACycle() {
        var progress = JevProgress()
        let a = page("A"), b = page("B")
        for _ in 0..<2 {
            var incomplete = a; incomplete.completenessIssue = "Missing subtree"
            progress.executed("next", target: nil, before: incomplete); progress.observe(b)
            progress.executed("back", target: nil, before: b); progress.observe(a)
        }
        #expect(progress.repeatedCycleLength(repeating: "next", target: nil, from: a, maxLength: 4, repetitions: 2) == nil)
    }
}
