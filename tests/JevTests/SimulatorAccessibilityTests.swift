@testable import vphone_cli
import CoreGraphics
import Foundation
import Testing

@MainActor
struct SimulatorAccessibilityTests {
    @Test func nativePickerOptionsParseWithoutInventingOrTruncatingValues() {
        #expect(JevSimulatorObserver.pickerOptions(nil) == nil)
        #expect(JevSimulatorObserver.pickerOptions("(00, 05, 10, 15)") == ["00", "05", "10", "15"])
        #expect(JevSimulatorObserver.pickerOptions(["AM", "PM"]) == ["AM", "PM"])
        #expect(JevSimulatorObserver.pickerOptions([1, 2, 3]) == ["1", "2", "3"])
        #expect(JevSimulatorObserver.pickerOptions("(1, 2") == [])
        #expect(JevSimulatorObserver.pickerOptions(["A", "A"]) == [])
        #expect(JevSimulatorObserver.pickerOptions([true]) == [])
        #expect(JevSimulatorObserver.pickerOptions(Array(0...256)) == [])
        let p = "XC_kAXXCAttribute"
        let n = JevSimulatorObserver.normalize([p + "AutomationType": 39,
            p + "DatePickerPossibleValues": "(00, 15, 30, 45)"])
        #expect(n["pickerOptions"] as? [String] == ["00", "15", "30", "45"])
    }
    @Test func unnamedInlineEditorsRetainOnlyTheirImmediateNativeRowNeighbour() throws {
        let p = "XC_kAXXCAttribute"
        func node(_ type: Int, _ label: String = "", children: [[String: Any]] = []) -> [String: Any] {
            [p + "AutomationType": type, p + "Label": label, p + "Children": children,
             p + "Frame": ["X": 20, "Y": 100, "Width": 200, "Height": 100]]
        }
        var wheel = node(39)
        wheel[p + "Value"] = "30 minutes"
        wheel[p + "DatePickerPossibleValues"] = "(00, 15, 30, 45)"
        let unnamed = node(75, children: [wheel])
        var root = node(1, "Any form", children: [
            node(75, "Start value"), unnamed,
            node(75, "Other row"), node(0), unnamed,
            node(75, "Named editor", children: [wheel])])
        root[p + "ElementBaseType"] = "UIApplication"
        root[p + "Frame"] = ["X": 0, "Y": 0, "Width": 400, "Height": 800]
        let normalized = JevSimulatorObserver.normalize(root)
        let children = try #require(normalized["children"] as? [[String: Any]])
        #expect(children[1]["contextLabel"] as? String == "After row: Start value")
        #expect(children[4]["contextLabel"] == nil) // Never jump across a section/container.
        #expect(children[5]["contextLabel"] == nil) // Preserve explicit native labels.
        let observation = try JevSimulatorObserver.decode(roots: [normalized])
        let picker = try #require(observation.elements.first { $0.role == "picker" })
        #expect(picker.context == "After row: Start value")
        #expect(picker.pickerOptions == ["00", "15", "30", "45"])
        #expect(!observation.elements.contains { $0.label == "After row: Start value" })
    }
    @Test func unresolvedVisibleRemoteSubtreeIsIncompleteEvenWithoutTruncation() {
        let p = "XC_kAXXCAttribute"
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        var stub: [String: Any] = [p + "ElementType": "AXRemoteElement", p + "Children": [],
            p + "Frame": ["X": 0.0, "Y": 0.0, "Width": 400.0, "Height": 800.0]]
        #expect(JevSimulatorObserver.hasUnresolvedRemoteContent(in: [p + "Children": [stub]], bounds: bounds))
        stub[p + "Frame"] = ["X": 0.0, "Y": 900.0, "Width": 400.0, "Height": 800.0]
        #expect(!JevSimulatorObserver.hasUnresolvedRemoteContent(in: stub, bounds: bounds))
        stub.removeValue(forKey: p + "Frame")
        #expect(JevSimulatorObserver.hasUnresolvedRemoteContent(in: stub, bounds: bounds))
        stub[p + "Children"] = [[p + "ElementType": "Content", p + "Label": "Loaded"]]
        #expect(!JevSimulatorObserver.hasUnresolvedRemoteContent(in: stub, bounds: bounds))
        #expect(!JevSimulatorObserver.hasUnresolvedRemoteContent(in: [p + "ElementType": "Native button"], bounds: bounds))
    }

    @Test func nativeBackControlKeepsDestinationLabelAndExposesNavigationMeaning() throws {
        let p = "XC_kAXXCAttribute"
        let root: [String: Any] = [p + "ElementBaseType": "UIApplication", p + "Label": "Any app",
            p + "Frame": ["X": 0, "Y": 0, "Width": 400, "Height": 800], p + "Children": [
                [p + "ElementType": "UIAccessibilityBackButtonElement", p + "AutomationType": 9,
                 p + "Label": "Previous screen", p + "Frame": ["X": 0, "Y": 50, "Width": 50, "Height": 40]],
                [p + "ElementType": "UIButton", p + "AutomationType": 9,
                 p + "Label": "Previous screen", p + "Frame": ["X": 100, "Y": 50, "Width": 50, "Height": 40]],
            ]]
        let roots = [JevSimulatorObserver.normalize(root)]
        let direct = try JevSimulatorObserver.decode(roots: roots)
        let wire = try JevSimulatorObserver.decode(JSONSerialization.data(withJSONObject: roots))
        #expect(direct.elements == wire.elements)
        #expect(direct.elements[0].label == "Previous screen")
        #expect(direct.elements[0].context == "Back navigation")
        #expect(direct.elements[1].context == nil)
        #expect(direct.elements[0].signature != direct.elements[1].signature)
        #expect(JevSimulatorObserver.matchesHit(direct.elements[0], hit: [p + "Label": "Previous screen"]))
    }

    @Test func literalReplacementOmitsCharacterKeysButKeepsSubmitAndCustomKeypads() {
        let keys = ["a", "1", "go", "delete"].map { JevElement(id: $0, role: "button", label: $0, value: nil, point: .zero, context: "Keyboard") }
        let field = JevElement(id: "field", role: "textfield", label: "Query", value: "", point: .zero)
        let appButton = JevElement(id: "app", role: "button", label: "A", value: nil, point: .zero)
        #expect(JevSimulatorObserver.controlsForTextReplacement(keys) == keys)
        #expect(JevSimulatorObserver.controlsForTextReplacement([field, appButton] + keys).map(\.id) == ["field", "app", "go", "delete"])
    }

    @Test(arguments: [45, 49, 50, 52])
    func unlabeledEditableFieldsRetainNativePlaceholdersAndGuardTheirIdentity(type: Int) throws {
        let p = "XC_kAXXCAttribute"
        let field: [String: Any] = [p + "AutomationType": type, p + "PlaceholderValue": "Field name",
            p + "Value": "Field name", p + "Frame": ["X": 20, "Y": 100, "Width": 300, "Height": 40]]
        let root: [String: Any] = [p + "ElementBaseType": "UIApplication", p + "Label": "Form",
            p + "Frame": ["X": 0, "Y": 0, "Width": 400, "Height": 800], p + "Children": [field]]
        let observation = try JevSimulatorObserver.decode(JSONSerialization.data(withJSONObject: [JevSimulatorObserver.normalize(root)]))
        let target = try #require(observation.elements.first)
        #expect(target.isTextInput && target.label == "Field name" && target.placeholder == "Field name")
        #expect(JevSimulatorObserver.matchesHit(target, hit: field))
        var wrong = field
        wrong[p + "PlaceholderValue"] = "Different field"
        #expect(!JevSimulatorObserver.matchesHit(target, hit: wrong))
        wrong = field; wrong[p + "AutomationType"] = 9
        #expect(!JevSimulatorObserver.matchesHit(target, hit: wrong))
        let space = JevActionSpace(observation: observation, apps: [], textCandidates: ["Mira"], pickerValues: [])
        #expect(space.targets[.typeText]?.values.first?.elementID == target.id)
    }

    @Test func narrowValidationKeepsMovedAndChangedValuesButExcludesUnrelatedControls() {
        let chosen = JevElement(id: "e1", role: "switch", label: "Enabled", value: "0", point: .zero, context: "Alice")
        let moved = JevElement(id: "e9", role: "switch", label: "Enabled", value: "1", point: CGPoint(x: 30, y: 80), context: "Alice")
        let otherRow = JevElement(id: "e2", role: "switch", label: "Enabled", value: "0", point: .zero, context: "Bob")
        let otherRole = JevElement(id: "e3", role: "button", label: "Enabled", value: "0", point: .zero, context: "Alice")
        #expect(JevSimulatorObserver.isValidationCandidate(moved, for: chosen))
        #expect(moved.signature != chosen.signature)
        #expect(!JevSimulatorObserver.isValidationCandidate(otherRow, for: chosen))
        #expect(!JevSimulatorObserver.isValidationCandidate(otherRole, for: chosen))
        let owner = JevElement(id: "e4", role: "statictext", label: "Counter", value: "1", point: .zero)
        let named = JevSimulatorObserver.customElements(for: owner, names: ["Increase"])[0]
        #expect(JevSimulatorObserver.isValidationCandidate(owner, for: named))
        #expect(!JevSimulatorObserver.isValidationCandidate(chosen, for: named))
    }

    @Test func namedActionsBindOwnerStateAndRejectAmbiguousNames() throws {
        let owner = JevElement(id: "e1", role: "statictext", label: "Counter", value: "1", point: .zero)
        let actions = JevSimulatorObserver.customElements(for: owner, names: ["Increase", "Duplicate", "Duplicate", " "])
        #expect(actions.count == 1)
        let action = try #require(actions.first)
        #expect(action.label == "Increase")
        #expect(action.customAction?.ownerLabel == "Counter")
        #expect(action.customAction?.ownerValue == "1")
        #expect(action.isTappable && !action.isAdjustable && !action.isTextInput)
        let changedOwner = JevElement(id: "e1", role: "statictext", label: "Counter", value: "2", point: .zero)
        #expect(action.signature != JevSimulatorObserver.customElements(for: changedOwner, names: ["Increase"])[0].signature)
        let observation = JevObservation(foregroundApp: "Fixture", elements: [owner, action],
            bounds: CGRect(x: 0, y: 0, width: 400, height: 800), source: .accessibility)
        let space = JevActionSpace(observation: observation, apps: [], textCandidates: [], pickerValues: [])
        #expect(space.targets[.tap]?[action.id]?.elementID == action.id)
        #expect(space.targets[.tap]?[owner.id] == nil)
    }

    @Test func unlabeledNativeRowsAndKeyboardPreserveContextWithoutInventingTargets() throws {
        let p = "XC_kAXXCAttribute"
        func node(_ type: Int, _ label: String = "", y: Double = 100,
                  children: [[String: Any]] = []) -> [String: Any] {
            [p + "AutomationType": type, p + "Label": label, p + "Children": children,
             p + "Frame": ["X": 0.0, "Y": y, "Width": 300.0, "Height": 40.0]]
        }
        var root = node(1, "Contacts", y: 0, children: [
            node(75, children: [node(48, "Alice"), node(9, "Edit")]),
            node(75, y: 200, children: [node(48, "Bob", y: 200), node(9, "Edit", y: 200)]),
            node(19, y: 700, children: [node(20, "go", y: 700)]),
        ])
        root[p + "ElementBaseType"] = "UIApplication"
        root[p + "Frame"] = ["X": 0, "Y": 0, "Width": 400, "Height": 800]
        let observation = try JevSimulatorObserver.decode(JSONSerialization.data(withJSONObject: [JevSimulatorObserver.normalize(root)]))
        let edits = observation.elements.filter { $0.label == "Edit" }
        #expect(edits.map(\.context) == ["Alice", "Bob"])
        #expect(edits[0].signature != edits[1].signature)
        #expect(observation.elements.first { $0.label == "go" }?.context == "Keyboard")
        #expect(observation.elements.filter(\.isTappable).map(\.label) == ["Edit", "Edit", "go"])
    }

    @Test func deeplyNestedDocumentKeepsFirstNonemptyWebTitle() {
        let p = "XC_kAXXCAttribute"
        let first: [String: Any] = [p + "ElementType": "WebAccessibilityObjectWrapper", p + "Label": "First document"]
        let second: [String: Any] = [p + "ElementType": "WebAccessibilityObjectWrapper", p + "Label": "Second document"]
        let empty: [String: Any] = [p + "ElementType": "WebAccessibilityObjectWrapper", p + "Label": ""]
        var tree: [String: Any] = [p + "Children": [empty, first, second]]
        // A lazy filter/map recursion performs exponentially repeated work
        // here. Real browser trees already contain this degree of nesting.
        for _ in 0..<24 { tree = [p + "Children": [tree]] }
        #expect(JevSimulatorObserver.documentTitle(in: tree) == "First document")
        #expect(JevSimulatorObserver.documentTitle(in: [p + "Label": "Native screen"]) == nil)
    }

    @Test func nestedLinksExposeLeafAndKeepSectionContext() throws {
        let leaf = element("Link", "Read article", value: "3")
        let parent = element("Link", "Publisher https://example.org Read article", children: [leaf])
        let section = element("Group", "Results", children: [parent])
        let observation = try decode([section])
        #expect(!observation.elements.contains { $0.label.contains("https://") })
        let link = try #require(observation.elements.first { $0.label == "Read article" })
        #expect(link.role == "link")
        #expect(link.context?.contains("Publisher https://example.org") == true)
    }

    @Test func coveredTargetsAreNotReachableAndUnlabelledPickersUseValue() {
        let link = JevElement(id: "x", role: "link", label: "Article", value: nil, point: .zero)
        #expect(!JevSimulatorObserver.matchesHit(link, hit: ["XC_kAXXCAttributeLabel": "Overlay"]))
        #expect(JevSimulatorObserver.matchesHit(link, hit: ["XC_kAXXCAttributeLabel": "Article"]))
        let picker = JevElement(id: "p", role: "picker", label: "Picker wheel", value: "9", point: .zero)
        #expect(JevSimulatorObserver.matchesHit(picker, hit: ["XC_kAXXCAttributeAutomationType": 39, "XC_kAXXCAttributeValue": "9"]))
        #expect(!JevSimulatorObserver.matchesHit(picker, hit: ["XC_kAXXCAttributeAutomationType": 39, "XC_kAXXCAttributeValue": "10"]))
    }

    @Test func homeScreenAndAppIconsAreNamedAsControls() throws {
        let p = "XC_kAXXCAttribute"
        let tree: [String: Any] = [p + "ElementType": "SpringBoard", p + "ElementBaseType": "UISystemShellApplication",
            p + "Label": " ", p + "Frame": ["X": 0, "Y": 0, "Width": 402, "Height": 874],
            p + "Children": [[p + "ElementType": "SBIconView", p + "AutomationType": 44, p + "Label": "Alarms",
                               p + "Frame": ["X": 100, "Y": 100, "Width": 64, "Height": 86]]]]
        let observation = try JevSimulatorObserver.decode(JSONSerialization.data(withJSONObject: [JevSimulatorObserver.normalize(tree)]))
        #expect(observation.foregroundApp == "Home Screen")
        #expect(observation.elements.first?.role == "button")
        #expect(observation.elements.first?.label == "Alarms")
    }

    @Test func pickerTargetsAreLiteralAndAdjustmentsUnderstandTimeValues() throws {
        #expect(JevPickerValues.extract(from: "Set an alarm for 6:00 AM, not 6 PM") == ["6", "00", "AM", "PM"])
        #expect(JevPickerValues.extract(from: "6AM") == ["6", "AM"])
        #expect(try JevPickerValues.direction(from: "9 o’clock", to: "6") == false)
        #expect(try JevPickerValues.direction(from: "06 minutes", to: "6") == nil)
        #expect(try JevPickerValues.direction(from: "AM", to: "PM") == true)
        #expect(throws: (any Error).self) { try JevPickerValues.direction(from: nil, to: "6") }
        #expect(throws: (any Error).self) { try JevPickerValues.direction(from: "January", to: "6") }
    }

    @Test func pickerSelectionRequiresBackendCapabilityAndLiteralTarget() throws {
        var observation = try decode([element("Picker", "Hour", value: "9 o’clock")])
        func actions(_ values: [String]) -> [JevAction] {
            JevQuestions.availableActions(observation: observation, apps: [], textCandidates: [], pickerValues: values)
        }
        #expect(!actions(["6"]).contains(.setPickerValue))
        observation.supportsPickerSelection = true
        #expect(actions(["6"]).contains(.setPickerValue))
        #expect(!actions([]).contains(.setPickerValue))
    }

    @Test func failedPreferenceReadCannotInventResets() {
        let baseline = ["jev.readable.com.apple.Accessibility": "true",
                        "com.apple.Accessibility.BoldTextEnabled": "1"]
        #expect(JevSimulatorFacts.changes(from: baseline, to: [:]).isEmpty)
        let readableEmpty = ["jev.readable.com.apple.Accessibility": "true"]
        #expect(JevSimulatorFacts.changes(from: baseline, to: readableEmpty)
            == ["Device setting BoldTextEnabled was 1 and is no longer set."])
    }

    @Test func fallbackPreferencesKeepScalarTypesAndIgnoreNestedValues() {
        let data = Data("""
        {enabled = 1; name = "A quoted name"; nested = {hidden = 1;}; list = (one, two);}
        """.utf8)
        #expect(JevSimulatorFacts.parseDomain(data) == ["enabled": "1", "name": "A quoted name"])
        #expect(JevSimulatorFacts.parseDomain(Data("invalid".utf8)) == nil)
    }

    @Test func nativePickerKeepsReadableValueAndControlPoint() throws {
        let p = "XC_kAXXCAttribute"
        let tree: [String: Any] = [
            p + "ElementBaseType": "UIApplication", p + "Label": "Alarms",
            p + "Frame": ["X": 0, "Y": 0, "Width": 402, "Height": 874],
            p + "Children": [[p + "AutomationType": 39, p + "Value": "9 o’clock",
                              p + "Frame": ["X": 111, "Y": 90.5, "Width": 55, "Height": 291]]],
        ]
        let wire = try #require(JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: tree)) as? [String: Any])
        let normalized = JevSimulatorObserver.normalize(wire)
        let observation = try JevSimulatorObserver.decode(JSONSerialization.data(withJSONObject: [normalized]))
        let wheel = try #require(observation.elements.first)
        #expect(wheel.role == "picker")
        #expect(wheel.value == "9 o’clock")
        #expect(wheel.point == CGPoint(x: 138.5, y: 236))
        let text = try JSONSerialization.jsonObject(with: JSONEncoder().encode(wheel.described)) as? [String: Any]
        #expect(text?["point"] == nil)
        #expect(text?["x"] == nil)
    }

    @Test func savedAlarmFactsDistinguishNewRecordsFromPickerState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("alarm.plist")
        let facts = JevSimulatorFacts(udid: "unused", alarmPreferencesURL: url, domains: [])
        let baseline = await facts.snapshot()
        #expect(await facts.changes(since: baseline).contains { $0.contains("0 new saved") })
        let alarms: [[String: Any]] = [["id": UUID().uuidString, "hour": 6, "minute": 0]]
        let data = try JSONSerialization.data(withJSONObject: alarms)
        try PropertyListSerialization.data(fromPropertyList: ["alarms": data], format: .binary, options: 0).write(to: url)
        let changed = await facts.changes(since: baseline)
        #expect(changed.contains { $0.contains("6:00 AM (06:00)") })
        #expect(changed.contains { $0.contains("1 new saved") })
        let saved = await facts.snapshot()
        try Data("corrupt".utf8).write(to: url)
        #expect(await facts.changes(since: saved).isEmpty)
    }

    private func element(_ type: String, _ label: String, value: Any = NSNull(),
                         x: Double = 20, y: Double = 100, enabled: Bool = true,
                         children: [[String: Any]] = []) -> [String: Any] {
        ["type": type, "AXLabel": label, "AXValue": value, "enabled": enabled,
         "frame": ["x": x, "y": y, "width": 50.0, "height": 30.0], "children": children]
    }

    private func decode(_ children: [[String: Any]]) throws -> JevObservation {
        let root: [String: Any] = [
            "type": "Application", "AXLabel": "Settings",
            "frame": ["x": 0, "y": 0, "width": 402, "height": 874], "children": children,
        ]
        return try JevSimulatorObserver.decode(JSONSerialization.data(withJSONObject: [root]))
    }

    @Test func switchUsesActualControlFrameAndState() throws {
        let control = element("CheckBox", "Bold Text", value: "1", x: 315)
        let row = element("Group", "Bold Text", value: "1", children: [
            element("StaticText", "Bold Text"), control,
        ])
        let observation = try decode([row])
        let tappable = observation.elements.filter(\.isTappable)
        #expect(observation.source == .accessibility)
        #expect(observation.foregroundApp == "Settings")
        #expect(tappable.count == 1)
        #expect(tappable.first?.role == "switch")
        #expect(tappable.first?.value == "on")
        #expect(tappable.first?.point == CGPoint(x: 340, y: 115))
        #expect(try decode([element("CheckBox", "Bold Text", value: 0)]).elements.first?.value == "off")
    }

    @Test func hiddenOffscreenAndDisabledControlsAreNotOffered() throws {
        var hidden = element("Group", "hidden", children: [element("Button", "hidden child")])
        hidden["hidden"] = true
        let observation = try decode([
            hidden, element("Button", "below screen", y: 900),
            element("Button", "disabled", enabled: false), element("Button", "Back"),
        ])
        #expect(observation.elements.filter(\.isTappable).map(\.label) == ["Back"])
        #expect(!observation.elements.contains { $0.label == "hidden child" })
    }

    @Test func nearbyContextExplainsScrollingButCannotBeExecuted() throws {
        let observation = try decode([
            element("Button", "Visible"), element("Link", "Next article", y: 920),
            element("Link", "Earlier article", y: -70), element("Link", "Far away", y: 5000),
            element("Button", "Disabled below", y: 950, enabled: false),
        ])
        #expect(observation.nearbyElements.map(\.label) == ["Next article", "Earlier article"])
        #expect(observation.nearbyElements[0].visibility?.contains("below") == true)
        #expect(observation.nearbyElements[1].visibility?.contains("above") == true)
        let space = JevActionSpace(observation: observation, apps: [], textCandidates: [], pickerValues: [])
        #expect(space.targets[.tap]?.count == 1)
        #expect(!space.targets[.tap]!.values.contains { $0.description.contains("Next article") })
    }

    @Test func emptyOrInvalidTreesFailWithoutOCR() throws {
        #expect(throws: (any Error).self) { try decode([]) }
        #expect(throws: (any Error).self) { try JevSimulatorObserver.decode(Data("[]".utf8)) }
        #expect(throws: (any Error).self) { try JevSimulatorObserver.decode(Data("{}".utf8)) }
    }

    @Test func coveredControlsRemainContextOnlyAndChangeCompletionEvidence() throws {
        var observation = try decode([element("Button", "Back")])
        let oldSignature = observation.signature
        let covered = JevElement(id: "covered", role: "button", label: "Draft: 9:30 to 10:15",
            value: nil, point: CGPoint(x: 100, y: 130), context: "List")
        JevSimulatorObserver.retainUnreachable(covered, in: &observation)
        #expect(observation.nearbyElements.last?.label == covered.label)
        #expect(observation.nearbyElements.last?.visibility?.contains("not actionable") == true)
        #expect(observation.signature != oldSignature)
        let space = JevActionSpace(observation: observation, apps: [], textCandidates: [], pickerValues: [])
        #expect(space.targets[.tap]?.count == 1)
        #expect(!space.targets[.tap]!.values.contains { $0.elementID == covered.id })
        #expect(observation.element(id: "unreachable:covered") == nil)
        for _ in 0..<100 { JevSimulatorObserver.retainUnreachable(covered, in: &observation) }
        #expect(observation.nearbyElements.count == 48)
    }

    @Test func rowNavigationAndTextFieldsRemainAvailable() throws {
        let observation = try decode([
            element("Group", "Accessibility", children: [element("StaticText", "Accessibility")]),
            element("TextField", "Search", value: "hello"),
        ])
        #expect(observation.elements.filter(\.isTappable).map(\.label) == ["Accessibility", "Search"])
        #expect(observation.elements.last?.isTextInput == true)
        #expect(observation.elements.last?.value == "hello")
    }
}
