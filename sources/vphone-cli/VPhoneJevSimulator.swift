import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - iOS Simulator Target

/// Drives Apple's iOS Simulator instead of the vphone VM.
///
/// The vphone VM needs SIP and AMFI disabled, so it cannot run on an ordinary
/// Mac. The Simulator runs real iOS — real Settings, real Safari — with no
/// boot-args changes, which makes it the target that can actually be
/// exercised.
///
/// **The Simulator does not expose iOS UI to the host accessibility tree.**
/// Probing `Simulator.app` returns its own macOS chrome — Volume, Sleep/Wake,
/// Home, Rotate, and 239 menu items — while the device screen is a single
/// `AXGroup` with no children. So there is no semantic tree to read here, and
/// observation is OCR over `simctl io screenshot`.
///
/// What the accessibility tree *is* good for is that opaque group's frame:
/// it gives the device screen's exact rectangle in host coordinates, which is
/// what turns an OCR hit in device pixels into a point worth clicking.
///
/// Accessibility permission is still required — not to read the UI, but
/// because synthetic `CGEvent`s are discarded without it, and because the
/// screen rectangle comes from the AX API.
@MainActor
enum VPhoneJevSimulator {
    enum SimulatorError: Error, CustomStringConvertible {
        case notTrusted
        case notRunning
        case noDeviceScreen
        case screenshotFailed(String)

        var description: String {
            switch self {
            case .notTrusted:
                """
                Accessibility permission is not granted, so synthetic taps would be \
                silently discarded. Enable the host terminal in System Settings → \
                Privacy & Security → Accessibility, then try again.
                """
            case .notRunning:
                "Simulator.app is not running. Start it with `open -a Simulator`."
            case .noDeviceScreen:
                """
                Simulator.app is running but its window has no device screen. Make sure a \
                device is booted and its window is open.
                """
            case let .screenshotFailed(detail):
                "Could not capture the simulator screen: \(detail)"
            }
        }
    }

    static func app() -> NSRunningApplication? {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.iphonesimulator")
            .first
    }

    /// Check the two things that otherwise fail silently.
    static func preflight() throws {
        guard AXIsProcessTrusted() else { throw SimulatorError.notTrusted }
        guard app() != nil else { throw SimulatorError.notRunning }
    }

    // MARK: AX access

    static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
        else { return nil }
        return value
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute as String),
              let size = attribute(element, kAXSizeAttribute as String)
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent)
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    /// The device screen's rectangle in host screen coordinates.
    ///
    /// It is the largest `AXGroup` directly inside the Simulator window — the
    /// opaque view iOS renders into.
    static func deviceScreenRect() throws -> CGRect {
        try preflight()
        guard let app = app() else { throw SimulatorError.notRunning }

        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let windows = attribute(root, kAXWindowsAttribute as String) as? [AXUIElement],
              let window = windows.first
        else { throw SimulatorError.noDeviceScreen }

        let groups = (attribute(window, kAXChildrenAttribute as String) as? [AXUIElement] ?? [])
            .filter { (attribute($0, kAXRoleAttribute as String) as? String) == "AXGroup" }
            .compactMap { frame($0) }

        guard let screen = groups.max(by: { $0.width * $0.height < $1.width * $1.height })
        else { throw SimulatorError.noDeviceScreen }
        return screen
    }

    // MARK: simctl

    @discardableResult
    static func simctl(_ arguments: [String], input: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        if input != nil {
            let stdin = Pipe()
            process.standardInput = stdin
            try process.run()
            stdin.fileHandleForWriting.write(Data(input!.utf8))
            stdin.fileHandleForWriting.closeFile()
        } else {
            try process.run()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Capture the device screen. Needs no permissions of any kind.
    static func screenshot(udid: String) throws -> CGImage {
        let path = NSTemporaryDirectory() + "jev-sim-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: path) }

        try simctl(["io", udid, "screenshot", path])

        // Read the bytes before the file goes away. A CGImage made from a URL
        // is lazily backed by that file, so deleting it on the way out leaves
        // an image that decodes to nothing — silently, with no error, which
        // reads downstream as "the screen has no text on it".
        guard let data = FileManager.default.contents(atPath: path) else {
            throw SimulatorError.screenshotFailed("simctl wrote no file at \(path)")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw SimulatorError.screenshotFailed("could not decode \(data.count) bytes") }
        return image
    }
}

// MARK: - Observation

/// Observes the Simulator by OCR over a `simctl` screenshot.
///
/// Element points are emitted already converted into **host screen
/// coordinates**, so the actuator can click them directly and the mapping
/// lives in exactly one place.
@MainActor
struct JevSimulatorObserver: JevObservationProvider {
    let udid: String
    var minimumTextConfidence: Float = 0.3

    func observe() async throws -> JevObservation {
        let screenRect = try VPhoneJevSimulator.deviceScreenRect()
        let image = try VPhoneJevSimulator.screenshot(udid: udid)

        // The screenshot is in device pixels; the window is in host points.
        let scaleX = screenRect.width / Double(image.width)
        let scaleY = screenRect.height / Double(image.height)

        let elements = JevOCRProvider
            .recognize(in: image, minimumConfidence: minimumTextConfidence)
            .map { element in
                JevElement(
                    id: element.id,
                    role: element.role,
                    label: element.label,
                    value: element.value,
                    point: CGPoint(
                        x: screenRect.minX + element.point.x * scaleX,
                        y: screenRect.minY + element.point.y * scaleY
                    )
                )
            }

        return JevObservation(
            foregroundApp: "iOS Simulator",
            elements: elements,
            bounds: screenRect,
            // OCR, not a semantic tree: the Simulator does not publish one.
            source: .ocr
        )
    }

    /// Installed apps, so the agent can launch by bundle id instead of
    /// hunting for an icon.
    ///
    /// This matters more here than on the VM: with OCR there are no roles, so
    /// an app's *title* inside the app looks exactly like its *icon* on the
    /// home screen. Launching by identifier sidesteps that entirely.
    func installedApps() -> [(bundleId: String, name: String)] {
        guard let raw = try? VPhoneJevSimulator.simctl(["listapps", udid]),
              let data = raw.data(using: .utf8)
        else { return [] }

        // `listapps` emits an old-style plist; let Foundation parse it.
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: [String: Any]] else { return [] }

        return plist.compactMap { bundleId, info in
            let name = info["CFBundleDisplayName"] as? String
                ?? info["CFBundleName"] as? String
                ?? bundleId
            // Hidden system services have no display name worth offering.
            guard !name.isEmpty, !bundleId.hasPrefix("com.apple.Bridge") else { return nil }
            return (bundleId: bundleId, name: name)
        }
        .sorted { $0.name < $1.name }
    }
}

// MARK: - Actuation

/// Clicks the Simulator window with synthetic events, and uses `simctl` for
/// the things it does better.
@MainActor
struct JevSimulatorActuator: JevActuator {
    let udid: String

    func tap(at point: CGPoint) async throws {
        try VPhoneJevSimulator.preflight()
        VPhoneJevSimulator.app()?.activate()
        try? await Task.sleep(nanoseconds: 120_000_000)

        post(.leftMouseDown, at: point)
        try? await Task.sleep(nanoseconds: 60_000_000)
        post(.leftMouseUp, at: point)
    }

    func scroll(reveal direction: JevScrollDirection) async throws {
        let screen = try VPhoneJevSimulator.deviceScreenRect()
        VPhoneJevSimulator.app()?.activate()
        try? await Task.sleep(nanoseconds: 120_000_000)

        let x = screen.midX
        let near = screen.minY + screen.height * 0.70
        let far = screen.minY + screen.height * 0.30
        let (fromY, toY) = direction == .below ? (near, far) : (far, near)

        post(.leftMouseDown, at: CGPoint(x: x, y: fromY))
        // Stepped drag: one jump reads as a flick and overshoots wildly.
        for step in 1 ... 12 {
            let t = Double(step) / 12
            post(.leftMouseDragged, at: CGPoint(x: x, y: fromY + (toY - fromY) * t))
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        post(.leftMouseUp, at: CGPoint(x: x, y: toY))
    }

    /// Drag vertically on one element. A picker wheel moves by roughly one
    /// value per short drag, so this is deliberately small: the agent
    /// re-observes after each and can repeat until it lands.
    func drag(at point: CGPoint, up: Bool) async throws {
        try VPhoneJevSimulator.preflight()
        let screen = try VPhoneJevSimulator.deviceScreenRect()
        VPhoneJevSimulator.app()?.activate()
        try? await Task.sleep(nanoseconds: 120_000_000)

        // One row, not two. A picker row is about 3.2% of screen height, and
        // a longer drag overshoots a short wheel — AM/PM has only two values,
        // so a two-row pull runs off the end and snaps back to where it was.
        let distance = screen.height * 0.035
        let end = CGPoint(x: point.x, y: point.y + (up ? -distance : distance))

        // Timing matters more than distance here. A picker wheel ignores a
        // fast sweep as a flick and snaps back; it only tracks a drag that
        // settles before it moves and then travels slowly. Measured: a
        // 160ms sweep moved nothing, while a 250ms hold followed by a 600ms
        // sweep moved it two rows.
        post(.leftMouseDown, at: point)
        try? await Task.sleep(nanoseconds: 250_000_000)

        let steps = 30
        for step in 1 ... steps {
            let t = Double(step) / Double(steps)
            post(.leftMouseDragged, at: CGPoint(x: point.x, y: point.y + (end.y - point.y) * t))
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        post(.leftMouseUp, at: end)
    }

    /// Real keystrokes into whatever field has focus.
    ///
    /// Not `simctl pbcopy`, which only loads the device pasteboard and types
    /// nothing — the same trap as the VM's "type" command, which sets the
    /// clipboard and is why "typetext" exists there. The Simulator connects a
    /// hardware keyboard by default, so key events reach the focused field.
    ///
    /// Characters are sent as Unicode rather than mapped to virtual keycodes,
    /// which keeps punctuation and non-ASCII working without a layout table.
    func type(_ text: String) async throws {
        try VPhoneJevSimulator.preflight()
        VPhoneJevSimulator.app()?.activate()
        try? await Task.sleep(nanoseconds: 250_000_000)

        let source = CGEventSource(stateID: .hidSystemState)
        for character in text {
            var utf16 = Array(String(character).utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    func pressHome() async throws {
        try VPhoneJevSimulator.preflight()
        VPhoneJevSimulator.app()?.activate()
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Simulator maps the home button to ⇧⌘H.
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0x04, keyDown: down)
            else { continue }
            event.flags = [.maskCommand, .maskShift]
            event.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    func launch(bundleId: String) async throws {
        try VPhoneJevSimulator.simctl(["launch", udid, bundleId])
    }

    private func post(_ type: CGEventType, at point: CGPoint) {
        CGEvent(
            mouseEventSource: CGEventSource(stateID: .hidSystemState),
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
    }
}
