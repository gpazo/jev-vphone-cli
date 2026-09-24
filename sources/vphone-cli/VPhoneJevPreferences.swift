import Darwin
import Foundation

/// Persistent guest services: preference reads and bounded accessibility input.
/// Process startup happens once per run. EOF tears down the guest.
@MainActor
final class JevSimulatorPreferences {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()

    init(udid: String, helper: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw VPhoneJevSimulator.SimulatorError(description: "Missing simulator preference reader. Run make setup_jev.")
        }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "spawn", udid, helper.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Parent must release the child's endpoints so an exited child gives EOF.
        try input.fileHandleForReading.close()
        try output.fileHandleForWriting.close()
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func stop() {
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        if process.isRunning { process.terminate() }
    }

    func read(domains: [String]) throws -> [String: [String: String]] {
        let data = try request(JSONEncoder().encode(domains))
        return try JSONDecoder().decode([String: [String: String]].self, from: data)
    }

    func prepareActions() throws {
        let response = try JSONSerialization.jsonObject(with: request(Data(#"{"action":"prepare"}"#.utf8))) as? [String: Any]
        guard response?["ok"] as? Bool == true else { throw failure() }
    }

    func launch(bundleId: String) throws {
        let command = ["action": "launch", "bundleId": bundleId]
        let response = try JSONSerialization.jsonObject(with: request(JSONEncoder().encode(command))) as? [String: Any]
        guard response?["ok"] as? Bool == true else {
            throw VPhoneJevSimulator.SimulatorError(description: response?["error"] as? String ?? "Native app launch failed")
        }
    }

    func perform(_ action: String, on element: JevElement, text: String? = nil) throws {
        var command: [String: Any] = ["action": action, "x": element.point.x, "y": element.point.y]
        command["expectedToken"] = element.nativeTargetToken
        if let text {
            command["text"] = text
            command["expectedValue"] = element.value
        }
        if element.role == "picker" {
            command["expectedAutomationType"] = 39
            command["expectedValue"] = element.value
        } else if let placeholder = element.placeholder {
            command["expectedPlaceholderValue"] = placeholder
        } else { command["expectedLabel"] = element.label }
        let result = try JSONSerialization.jsonObject(with: request(JSONSerialization.data(withJSONObject: command))) as? [String: Any]
        guard result?["ok"] as? Bool == true else {
            let reason = result?["error"] as? String ?? "invalid response"
            if reason == "Target changed since observation" { throw JevStaleTargetError(reason: reason) }
            throw VPhoneJevSimulator.SimulatorError(description: "Accessibility input: \(reason)")
        }
        if let text, result?["value"] as? String != text {
            throw VPhoneJevSimulator.SimulatorError(description: "Text replacement was not observed; inspect before retrying")
        }
    }

    func captureTargets(_ elements: [JevElement]) throws -> [[String: Any]] {
        let command: [String: Any] = ["action": "capture-targets", "points": elements.map {
            ["x": $0.point.x, "y": $0.point.y]
        }]
        let result = try JSONSerialization.jsonObject(with: request(JSONSerialization.data(withJSONObject: command))) as? [String: Any]
        guard result?["ok"] as? Bool == true, let targets = result?["targets"] as? [[String: Any]],
              targets.count == elements.count else { throw failure() }
        return targets
    }

    func validateTarget(_ token: String) throws -> CGPoint {
        let command = ["action": "validate-target", "token": token]
        let result = try JSONSerialization.jsonObject(with: request(JSONEncoder().encode(command))) as? [String: Any]
        guard result?["ok"] as? Bool == true, let frame = result?["frame"] as? [String: NSNumber],
              let x = frame["X"]?.doubleValue, let y = frame["Y"]?.doubleValue,
              let w = frame["Width"]?.doubleValue, let h = frame["Height"]?.doubleValue,
              [x, y, w, h].allSatisfy(\.isFinite), w > 0, h > 0 else {
            throw JevStaleTargetError(reason: "Native target changed or is unavailable")
        }
        return CGPoint(x: x + w / 2, y: y + h / 2)
    }

    func customActions(on element: JevElement) throws -> [String] {
        var command: [String: Any] = ["action": "custom-actions", "x": element.point.x, "y": element.point.y,
                                      "expectedLabel": element.label]
        command["expectedValue"] = element.value
        let result = try JSONSerialization.jsonObject(with: request(JSONSerialization.data(withJSONObject: command))) as? [String: Any]
        guard result?["ok"] as? Bool == true, let names = result?["actions"] as? [String] else {
            throw JevStaleTargetError(reason: result?["error"] as? String ?? "Cannot read named accessibility actions")
        }
        return names
    }

    func performCustom(on element: JevElement) throws {
        guard let action = element.customAction else { throw failure() }
        var command: [String: Any] = ["action": "custom", "x": element.point.x, "y": element.point.y,
            "expectedLabel": action.ownerLabel, "name": action.name]
        command["expectedValue"] = action.ownerValue
        let result = try JSONSerialization.jsonObject(with: request(JSONSerialization.data(withJSONObject: command))) as? [String: Any]
        guard result?["ok"] as? Bool == true else {
            let reason = result?["error"] as? String ?? "Invalid named action response"
            if reason == "Target changed since observation" || reason == "Custom action disappeared or is ambiguous" {
                throw JevStaleTargetError(reason: reason)
            }
            throw VPhoneJevSimulator.SimulatorError(description: "Named accessibility action: \(reason)")
        }
    }

    func readData(domain: String, container: URL, key: String) throws -> Data? {
        let command = ["operation": "read-data", "domain": domain, "container": container.path, "key": key]
        let response = try JSONSerialization.jsonObject(with: request(JSONEncoder().encode(command))) as? [String: Any]
        guard response?["ok"] as? Bool == true else { throw failure() }
        guard let encoded = response?["data"] as? String else { return nil }
        guard let data = Data(base64Encoded: encoded) else { throw failure() }
        return data
    }

    private func request(_ data: Data) throws -> Data {
        do { return try readResponse(data) }
        catch {
            // Do not reuse a stream after a timeout or malformed response:
            // a late response could otherwise be mistaken for the next read.
            stop()
            throw error
        }
    }

    private func readResponse(_ data: Data) throws -> Data {
        guard process.isRunning else { throw failure() }
        var request = data
        request.append(10)
        try input.fileHandleForWriting.write(contentsOf: request)
        var response = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while response.count < 1024 * 1024 {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw failure() }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, Int32(remaining * 1000))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { throw failure() }
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { throw failure() }
            response.append(chunk)
            if response.last == 10 {
                return response
            }
        }
        throw failure()
    }

    private func failure() -> VPhoneJevSimulator.SimulatorError {
        .init(description: "Simulator preference reader disconnected, timed out or returned too much data.")
    }
}
