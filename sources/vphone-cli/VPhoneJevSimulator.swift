import CoreGraphics
import Foundation
import VPhoneCore

// MARK: - Simulator Accessibility and HID

/// AXe reads the simulator's iOS accessibility server, not Simulator.app's
/// macOS window tree. Coordinates stay in device points all the way to HID.
/// There are no screenshots, OCR, host mouse events, or keyboard guessing.
@MainActor
enum VPhoneJevSimulator {
    struct SimulatorError: Error, CustomStringConvertible {
        let description: String
    }

    static func run(_ executable: URL, _ arguments: [String]) throws -> String {
        let result = try VPhoneProcessRunner.runCapturing(executable, arguments)
        guard result.succeeded else {
            throw SimulatorError(description:
                "\(executable.lastPathComponent) failed (\(result.exitCode)): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.stdout
    }

    @discardableResult
    static func simctl(_ arguments: [String]) throws -> String {
        try run(URL(fileURLWithPath: "/usr/bin/xcrun"), ["simctl"] + arguments)
    }

    /// Resolve once so observations and touches cannot target different devices.
    static func resolveDevice(_ requested: String) throws -> String {
        let raw = try simctl(["list", "devices", "booted", "--json"])
        let document = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        let devices = (document?["devices"] as? [String: [[String: Any]]] ?? [:])
            .values.flatMap { $0 }.filter { ($0["state"] as? String) == "Booted" }
        if requested == "booted" {
            guard devices.count == 1, let udid = devices.first?["udid"] as? String else {
                throw SimulatorError(description: "SIM=booted requires exactly one booted simulator; specify its UDID with SIM=<udid>.")
            }
            return udid
        }
        guard let device = devices.first(where: {
            ($0["udid"] as? String)?.caseInsensitiveCompare(requested) == .orderedSame
        }), let udid = device["udid"] as? String else {
            throw SimulatorError(description: "Simulator \(requested) is not booted. Run xcrun simctl boot <udid> first.")
        }
        return udid
    }

    static func axeURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let explicit = environment["JEV_AXE_PATH"] {
            candidates = [explicit]
        } else {
            candidates.append(FileManager.default.currentDirectoryPath + "/.tools/axe/axe")
            // Also work when the executable is invoked outside the checkout.
            var directory = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
            for _ in 0..<5 {
                candidates.append(directory.appendingPathComponent(".tools/axe/axe").path)
                directory.deleteLastPathComponent()
            }
            candidates += (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/axe" }
        }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw SimulatorError(description: "Simulator accessibility requires AXe. Run make setup_jev, or set JEV_AXE_PATH to the axe executable. OCR is not used.")
        }
        return URL(fileURLWithPath: path)
    }
}

/// Shared by observation and input, preserving one device and coordinate space.
@MainActor
final class JevSimulatorBridge {
    let udid: String
    let executable: URL
    var bounds = CGRect.zero
    var accessibility: JevSimulatorAccessibilityBridge?
    var services: JevSimulatorPreferences?
    var freshTraversal = false
    var inspectCustomActions = false
    var scrollAnchor: JevElement?
    let scopedValidation = ProcessInfo.processInfo.environment["JEV_SCOPED_VALIDATION"] == "1"
    var scopedObservation: (pid: Int, observation: JevObservation)?
    static let attributes = ["ElementType", "ElementBaseType", "Label", "Value", "Identifier", "Frame", "AutomationType", "Children", "PlaceholderValue", "DatePickerPossibleValues"].map { "XC_kAXXCAttribute" + $0 }
    static let hitAttributes = ["Label", "Value", "AutomationType", "PlaceholderValue"].map { "XC_kAXXCAttribute" + $0 }
    /// Diagnostic wall-clock breakdown; not part of the model's observation.
    var onObservationTiming: (_ tree: Double, _ decode: Double, _ hits: Double, _ count: Int, _ retry: Int, _ snapshot: Bool) -> Void = { _, _, _, _, _, _ in }

    init(udid: String) throws {
        self.udid = try VPhoneJevSimulator.resolveDevice(udid)
        executable = try VPhoneJevSimulator.axeURL()
    }

    func tree() throws -> [String: Any] {
        if accessibility == nil {
            let helper = ProcessInfo.processInfo.environment["JEV_AX_BRIDGE_PATH"].map { URL(fileURLWithPath: $0) }
                ?? executable.deletingLastPathComponent().appendingPathComponent("SimulatorFrameworkBridge-iOS")
            accessibility = try JevSimulatorAccessibilityBridge(udid: udid, helper: helper)
        }
        // The window-server resolver does not use the positional fallback
        // anchor. The returned root supplies the actual screen bounds.
        defer { freshTraversal = false }
        // A snapshot already fetches the entire native subtree. Starting at
        // 5,000 then retrying at 20,000 fetched large documents twice. Apply
        // our existing upper budget on the first read; reject any truncation.
        return try accessibility!.request(["verb": "describe", "method": "window-server", "x": bounds.midX, "y": bounds.midY,
                                           "snapshotTree": !freshTraversal, "automationMode": true, "attributes": Self.attributes,
                                           "maxNodes": 20_000])
    }

    func stop() { accessibility?.stop(); accessibility = nil }

    @discardableResult
    func command(_ arguments: [String]) throws -> String {
        try VPhoneJevSimulator.run(executable, arguments + ["--udid", udid])
    }
}

// MARK: - Observation

@MainActor
struct JevSimulatorObserver: JevObservationProvider {
    let bridge: JevSimulatorBridge

    func observe() async throws -> JevObservation {
        try await observe(attempt: 0)
    }

    func observeForValidation(of target: JevElement) async throws -> JevObservation {
        if let token = target.nativeTargetToken, let saved = bridge.scopedObservation,
           let services = bridge.services, let reader = bridge.accessibility {
            let root = try reader.foreground()
            guard root["pid"] as? Int == saved.pid,
                  let tree = root["tree"] as? [String: Any],
                  tree["XC_kAXXCAttributeLabel"] as? String == saved.observation.foregroundApp else {
                throw JevStaleTargetError(reason: "Foreground application changed")
            }
            var current = target
            current.point = try services.validateTarget(token)
            guard saved.observation.bounds.contains(current.point) else {
                throw JevStaleTargetError(reason: "Target left the screen")
            }
            return JevObservation(foregroundApp: saved.observation.foregroundApp, elements: [current],
                bounds: saved.observation.bounds, source: .accessibility, validatesTargetsAtExecution: true)
        }
        return try await observe(attempt: 0, target: target)
    }

    private func observe(attempt: Int, target: JevElement? = nil) async throws -> JevObservation {
        let started = ProcessInfo.processInfo.systemUptime
        let snapshot = !bridge.freshTraversal
        let response = try bridge.tree()
        let treeFinished = ProcessInfo.processInfo.systemUptime
        guard let tree = response["tree"] as? [String: Any] else {
            throw VPhoneJevSimulator.SimulatorError(description: "Accessibility reader returned no tree.")
        }
        var observation = try Self.decode(roots: [Self.normalize(tree)])
        if Self.hasUnresolvedRemoteContent(in: tree, bounds: observation.bounds) {
            observation.completenessIssue = "Visible embedded accessibility content is unavailable"
        }
        observation.documentTitle = Self.documentTitle(in: tree)
        observation.supportsPickerSelection = true
        observation.validatesTargetsAtExecution = true
        observation.elements = Self.controlsForTextReplacement(observation.elements)
        observation.layoutSignature = observation.elements.map {
            "\($0.signature)|\(Int($0.point.x.rounded()))|\(Int($0.point.y.rounded()))"
        }.joined(separator: "\n")
        if let target {
            // Still read the complete native tree for current app, document,
            // context and moved coordinates. Only candidate controls need live
            // hit tests when validating one choice; unrelated controls cannot
            // affect its identity. Full model observations check every target.
            observation.elements = observation.elements.filter { Self.isValidationCandidate($0, for: target) }
        }
        // A native snapshot can include content behind a sheet, suggestions,
        // or browser chrome. Check actionable points against the live hit-test
        // result before offering them. No mutation, pixels, or guessed offsets.
        var reachable: [JevElement] = []
        let decodeFinished = ProcessInfo.processInfo.systemUptime
        var hitCount = 0
        let candidates = observation.elements.filter(\.isTappable)
        let captured = target == nil && bridge.scopedValidation && observation.documentTitle == nil
            && observation.completenessIssue == nil && candidates.count <= 250
            ? try bridge.services?.captureTargets(candidates) : nil
        for var element in observation.elements {
            if !element.isTappable { reachable.append(element); continue }
            hitCount += 1
            if let captured, let hit = captured[hitCount - 1]["tree"] as? [String: Any] {
                guard Self.matchesHit(element, hit: hit) else {
                    if target == nil { Self.retainUnreachable(element, in: &observation) }
                    continue
                }
                let receipt = captured[hitCount - 1]
                // Match capture-time semantics and context to what Jev will see.
                // Duplicate semantic identities still use the full validation path.
                element.nativeTargetToken = Self.scopedToken(for: element, receipt: receipt, observation: observation)
                reachable.append(element)
                continue
            }
            let response = try bridge.accessibility!.request(["verb": "hittest", "x": element.point.x, "y": element.point.y,
                                                              "attributes": JevSimulatorBridge.hitAttributes])
            guard let hit = response["tree"] as? [String: Any],
                  Self.matchesHit(element, hit: hit) else {
                if target == nil { Self.retainUnreachable(element, in: &observation) }
                continue
            }
            reachable.append(element)
        }
        bridge.onObservationTiming(treeFinished - started, decodeFinished - treeFinished,
            ProcessInfo.processInfo.systemUptime - decodeFinished, hitCount, attempt, snapshot)
        if observation.elements.contains(where: \.isTappable), !reachable.contains(where: \.isTappable) {
            // The window moved between the snapshot and hit tests (commonly
            // a keyboard transition). Re-read instead of offering scrolls on
            // a torn observation. An enduring unavailable surface fails closed.
            guard attempt < 4 else { throw VPhoneJevSimulator.SimulatorError(description: "No controls could be reached in a stable observation") }
            bridge.freshTraversal = true
            // Sheet dismissal can outlast several fast reads. Back off only
            // on this observed transition, with 750 ms total sleep at most.
            try await Task.sleep(for: .milliseconds(50 * (1 << attempt)))
            return try await observe(attempt: attempt + 1, target: target)
        }
        if bridge.inspectCustomActions, let services = bridge.services {
            var expanded: [JevElement] = []
            for element in reachable {
                // A failed read gives no named choices. Existing controls still
                // have their normal hit-test and execution guards.
                let names = (try? services.customActions(on: element)) ?? []
                let named = Self.customElements(for: element, names: names)
                var owner = element
                if !named.isEmpty && !owner.nativePress && !owner.isTextInput && !owner.isAdjustable {
                    owner = JevElement(id: element.id, role: "statictext", label: element.label,
                        value: element.value, point: element.point, context: element.context)
                }
                expanded.append(owner)
                expanded += named
            }
            observation.elements = expanded
        } else { observation.elements = reachable }
        bridge.bounds = observation.bounds
        if target == nil {
            bridge.scopedObservation = captured == nil ? nil : (response["pid"] as? Int ?? -1, observation)
        }
        if target == nil {
            // A screen's centre can be a gap between controls. Scroll from
            // the nearest reachable control in the content, not the keyboard.
            let centre = CGPoint(x: observation.bounds.midX, y: observation.bounds.midY)
            bridge.scrollAnchor = observation.elements.filter {
                $0.isTappable && $0.customAction == nil && $0.context != "Keyboard"
            }.min { hypot($0.point.x - centre.x, $0.point.y - centre.y) < hypot($1.point.x - centre.x, $1.point.y - centre.y) }
        }
        return observation
    }

    static func isValidationCandidate(_ candidate: JevElement, for target: JevElement) -> Bool {
        if let action = target.customAction { return candidate.label == action.ownerLabel }
        return candidate.label == target.label && candidate.role == target.role && candidate.context == target.context
        // Values are deliberately not filtered: callers must see a changed
        // switch/picker value, and text-fill verification needs the new text.
    }

    static func normalizedNativeValue(_ hit: [String: Any], role: String?) -> String? {
        let value = stringValue(hit["XC_kAXXCAttributeValue"])
        if role == "switch", value == "1" { return "on" }
        if role == "switch", value == "0" { return "off" }
        return value
    }

    static func scopedToken(for element: JevElement, receipt: [String: Any], observation: JevObservation) -> String? {
        guard observation.documentTitle == nil, observation.completenessIssue == nil,
              element.customAction == nil, element.pickerOptions == nil, let hit = receipt["tree"] as? [String: Any],
              matchesHit(element, hit: hit), normalizedNativeValue(hit, role: element.role) == element.value,
              receipt["context"] as? String == (element.context ?? ""),
              receipt["app"] as? String == observation.foregroundApp,
              observation.elements.filter({ $0.signature == element.signature }).count == 1 else { return nil }
        return receipt["token"] as? String
    }

    static func hasUnresolvedRemoteContent(in node: [String: Any], bounds: CGRect) -> Bool {
        let p = "XC_kAXXCAttribute"
        let children = node[p + "Children"] as? [[String: Any]] ?? []
        if node[p + "ElementType"] as? String == "AXRemoteElement", children.isEmpty {
            // idb leaves a childless remote stub when the other process's
            // snapshot fails, even when the envelope says truncated=false.
            // Offscreen remote surfaces do not describe the current screen.
            guard let f = node[p + "Frame"] as? [String: Double],
                  let x = f["X"], let y = f["Y"], let w = f["Width"], let h = f["Height"],
                  [x, y, w, h].allSatisfy(\.isFinite) else { return true }
            return CGRect(x: x, y: y, width: w, height: h).intersects(bounds)
        }
        return children.contains { hasUnresolvedRemoteContent(in: $0, bounds: bounds) }
    }

    static func controlsForTextReplacement(_ elements: [JevElement]) -> [JevElement] {
        // A native editable field already supports complete literal entry.
        // Keep submit/editing keys, but do not offer or hit-test every character
        // key as an alternative way to type the same text. Custom keypads
        // without an editable AX field retain their individual controls.
        guard elements.contains(where: \.isTextInput) else { return elements }
        return elements.filter { !($0.context == "Keyboard" && $0.label.count == 1) }
    }

    static func documentTitle(in node: [String: Any]) -> String? {
        let p = "XC_kAXXCAttribute"
        if node[p + "ElementType"] as? String == "WebAccessibilityObjectWrapper",
           let label = node[p + "Label"] as? String, !label.isEmpty { return label }
        // lazy.compactMap(...).first evaluates a matching transform twice:
        // once to find its index and again to fetch it. Recursing that pattern
        // repeats the successful subtree exponentially with nesting depth.
        for child in node[p + "Children"] as? [[String: Any]] ?? [] {
            if let title = documentTitle(in: child) { return title }
        }
        return nil
    }

    static func customElements(for owner: JevElement, names: [String]) -> [JevElement] {
        let counts = Dictionary(grouping: names, by: { $0 }).mapValues(\.count)
        return names.enumerated().prefix(32).compactMap { index, name in
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  name.count <= 160, counts[name] == 1 else { return nil }
            return JevElement(id: "\(owner.id):action\(index + 1)", role: "accessibilityaction", label: name,
                value: owner.value, point: owner.point,
                context: [owner.context, owner.label].compactMap { $0 }.joined(separator: " > "),
                customAction: .init(name: name, ownerLabel: owner.label, ownerValue: owner.value))
        }
    }

    static func matchesHit(_ element: JevElement, hit: [String: Any]) -> Bool {
        if element.isTextInput, let placeholder = element.placeholder {
            return hit["XC_kAXXCAttributePlaceholderValue"] as? String == placeholder
                && [45, 49, 50, 52].contains(hit["XC_kAXXCAttributeAutomationType"] as? Int ?? 0)
        }
        if element.role == "picker" {
            return hit["XC_kAXXCAttributeAutomationType"] as? Int == 39
                && hit["XC_kAXXCAttributeValue"] as? String == element.value
        }
        return hit["XC_kAXXCAttributeLabel"] as? String == element.label
    }

    /// A failed hit test removes an action, not the native text that could
    /// explain how to reveal it. Never promote this context into a tap target.
    static func retainUnreachable(_ element: JevElement, in observation: inout JevObservation) {
        guard observation.nearbyElements.count < 48 else { return }
        let fraction = (element.point.y - observation.bounds.minY) / observation.bounds.height
        let position = fraction < 1.0 / 3 ? "upper" : fraction > 2.0 / 3 ? "lower" : "middle"
        observation.nearbyElements.append(JevElement.Described(id: "unreachable:\(element.id)",
            role: element.role, label: element.label, value: element.value, context: element.context,
            visibility: "native tree only, \(position) screen; covered or clipped; not actionable"))
    }

    /// idb preserves XCTest's native attribute names. Normalize those into the
    /// same decoder vocabulary as the host bridge, including readable wheels.
    static func pickerOptions(_ raw: Any?) -> [String]? {
        guard let raw, !(raw is NSNull) else { return nil }
        // idb serializes unsupported collection attributes as OpenStep plists.
        // Parse the complete collection; never split strings or accept a prefix.
        let decoded: Any? = if let text = raw as? String {
            try? PropertyListSerialization.propertyList(from: Data(text.utf8), options: [], format: nil)
        } else { raw }
        guard let values = decoded as? [Any], values.count <= 256 else { return [] }
        let options = values.compactMap { value -> String? in
            if let value = value as? String, !value.isEmpty, value.count <= 160 { return value }
            if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { return value.stringValue }
            return nil
        }
        guard options.count == values.count, Set(options).count == options.count else { return [] }
        return options
    }

    static func normalize(_ node: [String: Any]) -> [String: Any] {
        let prefix = "XC_kAXXCAttribute"
        let automationType = node[prefix + "AutomationType"] as? Int ?? 0
        let className = node[prefix + "ElementType"] as? String ?? ""
        let roles = [9: "Button", 10: "Button", 33: "Slider", 39: "Picker", 44: "Button",
                     40: "Switch", 42: "Link", 43: "Image", 20: "Button", 45: "SearchField", 48: "StaticText", 49: "TextField", 50: "TextField", 51: "StaticText", 52: "TextArea", 75: "Cell"]
        var type = roles[automationType] ?? "Group"
        let base = node[prefix + "ElementBaseType"] as? String
        if base == "UIApplication" || base == "UISystemShellApplication" { type = "Application" }
        var label = node[prefix + "Label"] as? String ?? ""
        let placeholder = node[prefix + "PlaceholderValue"] as? String
        if [45, 49, 50, 52].contains(automationType), label.isEmpty, let placeholder { label = placeholder }
        if className == "SpringBoard", label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { label = "Home Screen" }
        if automationType == 39, label.isEmpty { label = "Picker wheel" }
        if className.contains("ScrollIndicator") { type = "StaticText" }
        // Web containers are not actionable merely because they have text.
        if className == "WebAccessibilityObjectWrapper", automationType == 0 { type = "StaticText" }
        var result: [String: Any] = ["type": type, "AXLabel": label,
            "AXValue": node[prefix + "Value"] ?? NSNull(),
            "children": (node[prefix + "Children"] as? [[String: Any]] ?? []).map(normalize)]
        if var children = result["children"] as? [[String: Any]] {
            // Inline editors can occupy an unnamed sibling row. Preserve the
            // actual adjacent row as context, without asserting it is the owner.
            // This is native tree order, not a spatial/app-specific association.
            for index in children.indices.dropFirst() {
                guard children[index]["type"] as? String == "Cell",
                      (children[index]["AXLabel"] as? String ?? "").isEmpty,
                      children[index]["contextLabel"] == nil,
                      children[index - 1]["type"] as? String == "Cell",
                      let previous = children[index - 1]["AXLabel"] as? String, !previous.isEmpty else { continue }
                children[index]["contextLabel"] = "After row: " + String(previous.prefix(160))
            }
            result["children"] = children
        }
        if let placeholder, !placeholder.isEmpty { result["placeholder"] = placeholder }
        if automationType == 39, let options = pickerOptions(node[prefix + "DatePickerPossibleValues"]) {
            result["pickerOptions"] = options
        }
        // Preserve native grouping even when its container has no label.
        // This distinguishes keyboard keys and identically named row buttons
        // without teaching the controller any app's navigation or semantics.
        if automationType == 19 { result["contextLabel"] = "Keyboard" }
        if className == "UIAccessibilityBackButtonElement" { result["controlContext"] = "Back navigation" }
        if type == "Cell", label.isEmpty {
            let labels = (result["children"] as? [[String: Any]] ?? []).compactMap { child -> String? in
                guard child["type"] as? String == "StaticText" else { return nil }
                return child["AXLabel"] as? String
            }.filter { !$0.isEmpty }
            if !labels.isEmpty { result["contextLabel"] = labels.prefix(3).joined(separator: " / ") }
        }
        result["nativePress"] = [9, 10, 20, 40, 42, 44].contains(automationType) && className != "_UIButtonBarButton"
        if let enabled = node[prefix + "IsEnabled"] as? Bool { result["enabled"] = enabled }
        if let frame = node[prefix + "Frame"] as? [String: Any] {
            result["frame"] = ["x": (frame["X"] as? NSNumber)?.doubleValue ?? 0,
                               "y": (frame["Y"] as? NSNumber)?.doubleValue ?? 0,
                               "width": (frame["Width"] as? NSNumber)?.doubleValue ?? 0,
                               "height": (frame["Height"] as? NSNumber)?.doubleValue ?? 0]
        }
        return result
    }

    /// Flatten semantic nodes, retaining control values and ignoring invisible,
    /// disabled, and duplicate container/label versions of a real control.
    static func decode(_ data: Data) throws -> JevObservation {
        guard let roots = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw VPhoneJevSimulator.SimulatorError(description: "Accessibility returned no application tree.")
        }
        return try decode(roots: roots)
    }

    static func decode(roots: [[String: Any]]) throws -> JevObservation {
        guard let root = roots.first, let bounds = frame(root),
              bounds.width > 0, bounds.height > 0 else {
            throw VPhoneJevSimulator.SimulatorError(description: "Accessibility returned no application frame; refusing to fall back to OCR.")
        }
        var elements: [JevElement] = []
        var nearby: [JevElement.Described] = []
        var seen = Set<String>()
        func walk(_ node: [String: Any], context: [String] = []) {
            guard node["hidden"] as? Bool != true else { return }
            let children = node["children"] as? [[String: Any]] ?? []
            let type = node["type"] as? String ?? ""
            let nodeLabel = node["contextLabel"] as? String ?? node["AXLabel"] as? String ?? ""
            let nextContext = !children.isEmpty && !nodeLabel.isEmpty && context.last != nodeLabel && type != "Application"
                ? Array((context + [String(nodeLabel.prefix(160))]).suffix(2)) : context
            defer { for child in children { walk(child, context: nextContext) } }
            guard let rect = frame(node), !rect.isEmpty,
                  let label = (node["AXLabel"] as? String) ?? (node["title"] as? String),
                  !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard type != "Application", type != "ScrollArea" else { return }
            // Nested links represent one clickable region several times. A
            // container centre can hit a child with a different label; expose
            // concrete leaf links so the guest freshness assertion is meaningful.
            func containsLink(_ nodes: [[String: Any]]) -> Bool {
                nodes.contains { $0["type"] as? String == "Link" || containsLink($0["children"] as? [[String: Any]] ?? []) }
            }
            if type == "Link", containsLink(children) { return }
            // A row often repeats its label on a child switch and static text.
            // Offer the actual switch, never the enclosing row's guessed centre.
            if type == "Group", hasControl(label: label, in: children) { return }
            var role: String
            switch type.lowercased() {
            case "checkbox", "switch", "toggle": role = "switch"
            case "group", "cell": role = "button"
            case "statictext", "heading", "genericelement", "image": role = "statictext"
            default: role = type.isEmpty ? "statictext" : type.lowercased()
            }
            if node["enabled"] as? Bool == false { role = "statictext" }
            var value = stringValue(node["AXValue"])
            if role == "switch" {
                if value == "1" { value = "on" }
                if value == "0" { value = "off" }
            }
            if !bounds.contains(CGPoint(x: rect.midX, y: rect.midY)) {
                // Nearby native controls are context, not executable targets.
                // Limit distance and count instead of sending an entire web page.
                if nearby.count < 24, role != "statictext",
                   rect.midX >= bounds.minX, rect.midX <= bounds.maxX,
                   rect.midY > bounds.minY - bounds.height,
                   rect.midY < bounds.maxY + bounds.height {
                    nearby.append(JevElement.Described(id: "context\(nearby.count + 1)", role: role,
                        label: label, value: value, context: context.isEmpty ? nil : context.joined(separator: " > "),
                        visibility: rect.midY < bounds.minY ? "above viewport; not actionable" : "below viewport; not actionable"))
                }
                return
            }
            let key = "\(role)|\(label)|\(value ?? "")|\(Int(rect.midX))|\(Int(rect.midY))"
            guard seen.insert(key).inserted else { return }
            let controlContext = context + ((node["controlContext"] as? String).map { [$0] } ?? [])
            elements.append(JevElement(id: "e\(elements.count + 1)", role: role, label: label,
                                       value: value, point: CGPoint(x: rect.midX, y: rect.midY),
                                       nativePress: node["nativePress"] as? Bool ?? false,
                                       context: controlContext.isEmpty ? nil : controlContext.joined(separator: " > "),
                                       placeholder: node["placeholder"] as? String,
                                       pickerOptions: node["pickerOptions"] as? [String]))
        }
        for root in roots { walk(root) }
        guard !elements.isEmpty else {
            throw VPhoneJevSimulator.SimulatorError(description: "The simulator accessibility tree has no visible labelled elements; OCR is disabled.")
        }
        return JevObservation(foregroundApp: root["AXLabel"] as? String ?? "iOS Simulator",
                              elements: elements, bounds: bounds, source: .accessibility,
                              nearbyElements: nearby)
    }

    private static func hasControl(label: String, in children: [[String: Any]]) -> Bool {
        children.contains { child in
            let type = (child["type"] as? String ?? "").lowercased()
            return (child["AXLabel"] as? String == label
                && ["checkbox", "switch", "toggle", "button", "textfield", "slider", "picker"].contains(type))
                || hasControl(label: label, in: child["children"] as? [[String: Any]] ?? [])
        }
    }

    private static func frame(_ node: [String: Any]) -> CGRect? {
        guard let f = node["frame"] as? [String: Double],
              let x = f["x"], let y = f["y"], let width = f["width"], let height = f["height"],
              [x, y, width, height].allSatisfy({ $0.isFinite }) else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func stringValue(_ raw: Any?) -> String? {
        if let string = raw as? String { return string.isEmpty ? nil : string }
        if let number = raw as? NSNumber { return number.stringValue }
        return nil
    }

    func installedApps() -> [(bundleId: String, name: String)] {
        guard let raw = try? VPhoneJevSimulator.simctl(["listapps", bridge.udid]),
              let plist = try? PropertyListSerialization.propertyList(
                from: Data(raw.utf8), options: [], format: nil) as? [String: [String: Any]] else { return [] }
        return plist.compactMap { bundleId, info in
            let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? bundleId
            guard !name.isEmpty, !bundleId.hasPrefix("com.apple.Bridge") else { return nil }
            return (bundleId: bundleId, name: name)
        }.sorted { $0.name < $1.name }
    }
}

// MARK: - Input

@MainActor
struct JevSimulatorActuator: JevSemanticActuator {
    let bridge: JevSimulatorBridge

    func fill(_ text: String, on element: JevElement) async throws {
        guard element.isTextInput, let services = bridge.services else {
            throw VPhoneJevSimulator.SimulatorError(description: "Editable target unavailable")
        }
        let before = try await JevSimulatorObserver(bridge: bridge).observeForValidation(of: element)
        let matches = before.elements.filter { $0.signature == element.signature }
        guard matches.count == 1, let current = matches.first else {
            throw JevStaleTargetError(reason: "Editable target changed or is ambiguous")
        }
        // The guest checks the live target and reads its value back through
        // the same native handle. No second whole-screen traversal is needed.
        try services.perform("replace-text", on: current, text: text)
    }

    func press(_ element: JevElement) async throws {
        guard let services = bridge.services else {
            throw VPhoneJevSimulator.SimulatorError(description: "Native input service unavailable")
        }
        // Use the guest translator for both ordinary and named actions. The
        // reader's AXUIElementPerformAction path rejects some iOS 26 dialogs.
        // The service checks the live target before input; uncertain failures
        // stop the loop instead of trying a second input mechanism.
        if element.customAction != nil {
            try services.performCustom(on: element)
        } else {
            try services.perform("press", on: element)
        }
    }

    func adjust(_ element: JevElement, up: Bool) async throws {
        guard element.role == "picker" else { return try await drag(at: element.point, up: up) }
        guard let services = bridge.services else { throw VPhoneJevSimulator.SimulatorError(description: "Native input service unavailable.") }
        try services.perform(up ? "increment" : "decrement", on: element)
    }

    func select(_ value: String, on element: JevElement) async throws {
        // Jev chooses the wheel and a literal from the goal. Code performs the
        // bounded adjustment, checking the actual value after every change.
        var current = element
        var visited = Set<String>()
        for _ in 0..<64 {
            guard let direction = try JevPickerValues.direction(from: current.value, to: value, options: current.pickerOptions) else { return }
            if let observed = current.value, !visited.insert(observed).inserted {
                throw VPhoneJevSimulator.SimulatorError(description: "Picker repeated an observed value before reaching the target; stopped without another adjustment.")
            }
            try await adjust(current, up: direction)
            let deadline = ProcessInfo.processInfo.systemUptime + 0.5
            var changed: JevElement?
            repeat {
                let observation = try await JevSimulatorObserver(bridge: bridge).observe()
                changed = observation.elements.first { candidate in
                    candidate.role == "picker" && abs(candidate.point.x - current.point.x) < 2
                        && abs(candidate.point.y - current.point.y) < 2 && candidate.value != current.value
                        && candidate.pickerOptions == element.pickerOptions
                }
                if changed != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            } while ProcessInfo.processInfo.systemUptime < deadline
            guard let changed else { throw VPhoneJevSimulator.SimulatorError(description: "Picker did not change; stopped without repeating the action.") }
            current = changed
        }
        throw VPhoneJevSimulator.SimulatorError(description: "Picker target not reached within 64 verified adjustments.")
    }

    func tap(at point: CGPoint) async throws {
        try bridge.command(["tap", "-x", String(Double(point.x)), "-y", String(Double(point.y)), "--tap-style", "physical"])
    }

    func scroll(reveal direction: JevScrollDirection) async throws {
        guard let services = bridge.services, let reader = bridge.accessibility else {
            throw VPhoneJevSimulator.SimulatorError(description: "Native scrolling unavailable")
        }
        // Let iOS scroll the enclosing native container by one page. Resolve
        // and assert the live anchor before dispatch, just like a native press.
        // Never replay an unacknowledged action as a physical gesture.
        let point = CGPoint(x: bridge.bounds.midX, y: bridge.bounds.midY)
        let hit = try reader.request(["verb": "hittest", "x": point.x, "y": point.y])
        var anchor = bridge.scrollAnchor
        if let node = hit["tree"] as? [String: Any], let label = node["XC_kAXXCAttributeLabel"] as? String, !label.isEmpty {
            anchor = JevElement(id: "scroll-anchor", role: nil, label: label, value: nil, point: point)
        }
        guard let anchor else { throw JevStaleTargetError(reason: "Cannot resolve the scroll container") }
        try services.perform(direction == .below ? "scroll-down" : "scroll-up", on: anchor)
    }

    func drag(at point: CGPoint, up: Bool) async throws {
        let distance = bridge.bounds.height * 0.035
        // A swipe event leaves picker wheels unchanged; explicit touch moves
        // track the wheel. Measured against its native accessibility value.
        try swipe(from: point, to: CGPoint(x: point.x, y: point.y + (up ? -distance : distance)),
                  duration: 0.6, command: "drag")
    }

    private func swipe(from: CGPoint, to: CGPoint, duration: Double, command: String = "swipe") throws {
        try bridge.command([command, "--start-x", String(Double(from.x)), "--start-y", String(Double(from.y)),
                            "--end-x", String(Double(to.x)), "--end-y", String(Double(to.y)), "--duration", String(duration)])
    }

    func type(_ text: String) async throws {
        // AXe supports the printable US keyboard, not arbitrary Unicode.
        guard text.unicodeScalars.allSatisfy({ (32...126).contains($0.value) }) else {
            throw VPhoneJevSimulator.SimulatorError(description: "Simulator typing currently supports printable ASCII only.")
        }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("jev-type-\(UUID().uuidString).txt")
        try Data(text.utf8).write(to: path, options: .atomic)
        defer { try? FileManager.default.removeItem(at: path) }
        try bridge.command(["type", "--file", path.path])
    }

    func pressHome() async throws {
        try bridge.command(["button", "home"])
    }

    func launch(bundleId: String) async throws {
        guard let services = bridge.services else { throw VPhoneJevSimulator.SimulatorError(description: "Native input service unavailable.") }
        try services.launch(bundleId: bundleId)
    }
}
