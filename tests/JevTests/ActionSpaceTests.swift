@testable import vphone_cli
import CoreGraphics
import Foundation
import Testing

@MainActor
struct ActionSpaceTests {
    private func element(_ id: String, _ role: String, _ value: String? = nil) -> JevElement {
        JevElement(id: id, role: role, label: id, value: value, point: CGPoint(x: 30, y: 50))
    }
    private func space(_ elements: [JevElement]) -> JevActionSpace {
        var observation = JevObservation(foregroundApp: "Test", elements: elements,
            bounds: CGRect(x: 0, y: 0, width: 402, height: 874), source: .accessibility)
        observation.supportsPickerSelection = true
        return JevActionSpace(observation: observation, apps: [], textCandidates: ["hello"], pickerValues: ["6", "PM"])
    }
    private func answer(_ choice: String, ids: [String]) -> JevAnswer {
        JevAnswer(type: "choice", noul: nil, choice: choice, score: nil,
                  probabilities: Dictionary(uniqueKeysWithValues: ids.map { ($0, $0 == choice ? 1.0 : 0.0) }), confidence: 0.9)
    }
    @Test func operationsOnlyOfferCompatibleControls() {
        let s = space([element("button", "button"), element("text", "textfield"), element("slider", "slider")])
        #expect(Set(s.targets[.dragUp]!.keys) == ["slider"])
        #expect(Set(s.targets[.dragDown]!.keys) == ["slider"])
        #expect(s.targets[.typeText]!.values.allSatisfy { $0.elementID == "text" && $0.value == "hello" })
        #expect(!space([element("button", "button")]).operations.contains(.dragUp))
    }
    @Test func selectionBindsControlAndCompatibleValueAndExcludesNoops() {
        let s = space([element("number", "picker", "9"), element("period", "picker", "AM"), element("done", "picker", "6")])
        let targets = s.targets[.setPickerValue]!
        #expect(targets.count == 2)
        #expect(targets.values.contains { $0.elementID == "number" && $0.value == "6" })
        #expect(targets.values.contains { $0.elementID == "period" && $0.value == "PM" })
        #expect(!targets.values.contains { $0.elementID == "done" })
    }
    @Test func nativeOptionsRejectImpossibleSelectionsAndWheelTaps() throws {
        var hour = element("hour", "picker", "2 o’clock")
        hour.pickerOptions = (1...12).map(String.init)
        var minute = element("minute", "picker", "45 minutes")
        minute.pickerOptions = ["00", "15", "30", "45"]
        let observation = JevObservation(foregroundApp: "Any app", elements: [hour, minute],
            bounds: CGRect(x: 0, y: 0, width: 400, height: 800), source: .accessibility,
            supportsPickerSelection: true)
        let s = JevActionSpace(observation: observation, apps: [], textCandidates: [],
            pickerValues: ["2026", "00", "2", "30", "6", "45"])
        let targets = try #require(s.targets[.setPickerValue])
        #expect(Set(targets.values.filter { $0.elementID == "hour" }.compactMap(\.value)) == ["6"])
        #expect(Set(targets.values.filter { $0.elementID == "minute" }.compactMap(\.value)) == ["00", "30"])
        #expect(s.targets[.tap] == nil)
        #expect(s.targets[.dragUp]?.count == 2)
        #expect(try JevPickerValues.direction(from: "45 minutes", to: "0", options: minute.pickerOptions) == false)
        #expect(throws: (any Error).self) {
            try JevPickerValues.direction(from: "45 minutes", to: "1", options: minute.pickerOptions)
        }
        var changed = minute
        changed.pickerOptions = ["00", "30"]
        #expect(changed.signature != minute.signature)
        #expect(minute.described.pickerOptions == minute.pickerOptions)
    }
    @Test func selectedTargetMustHaveAValidDistribution() {
        let s = space([element("button", "button")])
        let action = answer("tap", ids: s.operations.map(\.rawValue))
        let invalid = answer("unknown", ids: ["unknown"])
        let result = JevModelDecider.decode(JevResponse(model: "test", answers: ["action": action, "tap_target": invalid], usage: nil), space: s)
        #expect(result.failure?.contains("tap_target") == true)
        let missing = JevModelDecider.decode(JevResponse(model: "test", answers: ["action": action], usage: nil), space: s)
        #expect(missing.failure != nil)
    }
    @Test func unusedInvalidHeadCannotChangeSelectedAction() {
        let s = space([element("button", "button"), element("text", "textfield")])
        let response = JevResponse(model: "test", answers: [
            "action": answer("tap", ids: s.operations.map(\.rawValue)),
            "tap_target": answer("button", ids: Array(s.targets[.tap]!.keys)),
            "type_text_target": answer("invalid", ids: ["invalid"]),
        ], usage: nil)
        let decision = JevModelDecider.decode(response, space: s)
        #expect(decision.failure == nil)
        #expect(decision.targetId == "button")
        #expect(decision.textId == nil)
        #expect(decision.targetConfidence == 0.9)
        #expect(decision.targetProbability == 1)
    }
    @Test func chosenSelectionDecodesOneCompleteBinding() {
        let s = space([element("number", "picker", "9"), element("period", "picker", "AM")])
        let options = s.targets[.setPickerValue]!
        let chosen = options.first { $0.value.elementID == "period" }!.key
        let decision = JevModelDecider.decode(JevResponse(model: "test", answers: [
            "action": answer("set_picker_value", ids: s.operations.map(\.rawValue)),
            "set_picker_value_target": answer(chosen, ids: Array(options.keys)),
        ], usage: nil), space: s)
        #expect(decision.failure == nil)
        #expect(decision.targetId == "period")
        #expect(decision.pickerValue == "PM")
    }
    @Test func invalidConfidenceIsRejected() {
        let invalid = JevAnswer(type: "choice", noul: nil, choice: "tap", score: nil,
            probabilities: ["tap": 1], confidence: .nan)
        #expect(invalid.validated(against: ["tap"]) != nil)
    }

    @Test func operationCertaintyDoesNotEraseSelectedTargetUncertainty() {
        let s = space([element("first", "button"), element("second", "button")])
        let target = JevAnswer(type: "choice", noul: nil, choice: "first", score: nil,
            probabilities: ["first": 0.55, "second": 0.45], confidence: 0.2)
        let decision = JevModelDecider.decode(JevResponse(model: "test", answers: [
            "action": answer("tap", ids: s.operations.map(\.rawValue)), "tap_target": target,
        ], usage: nil), space: s)
        #expect(decision.confidence == 0.9)
        #expect(decision.targetConfidence == 0.2)
        #expect(decision.targetProbability == 0.55)
        #expect(decision.executionConfidence == 0.2)
        let finished = JevModelDecider.decode(JevResponse(model: "test", answers: [
            "action": answer("finish", ids: s.operations.map(\.rawValue)), "tap_target": target,
        ], usage: nil), space: s)
        #expect(finished.targetConfidence == nil)
        #expect(finished.targetProbability == nil)
        #expect(finished.executionConfidence == 0.9)
    }
    @Test func densePagesStayWithinChoiceLimitDeterministically() {
        let elements = (1...300).map { element("e\($0)", "button") }
        let a = space(elements)
        let b = space(elements.reversed())
        #expect(a.targets[.tap]?.count == JevActionSpace.maxTargetsPerOperation)
        #expect(Set(a.targets[.tap]!.keys) == Set(b.targets[.tap]!.keys))
        #expect(a.targets[.tap]?["e1"] != nil)
        #expect(a.targets[.tap]?["e300"] == nil)
    }

    @Test func terminalExperimentCannotLeakIntoDefaultVocabulary() {
        let observation = JevObservation(foregroundApp: "Test", elements: [],
            bounds: CGRect(x: 0, y: 0, width: 400, height: 800), source: .accessibility)
        let normal = JevActionSpace(observation: observation, apps: [], textCandidates: [], pickerValues: [])
        let experiment = JevActionSpace(observation: observation, apps: [], textCandidates: [], pickerValues: [], includeStopUnable: true)
        #expect(!normal.operations.contains(.stopUnable))
        #expect(experiment.operations.contains(.stopUnable))
        let response = JevResponse(model: "test", answers: ["action": answer("stop_unable", ids: experiment.operations.map(\.rawValue))], usage: nil)
        #expect(JevModelDecider.decode(response, space: normal).failure != nil)
        #expect(JevModelDecider.decode(response, space: experiment).action == .stopUnable)
    }
}
