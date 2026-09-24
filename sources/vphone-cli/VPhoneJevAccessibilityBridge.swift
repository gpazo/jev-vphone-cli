import Darwin
import Foundation

/// Keeps idb's in-simulator accessibility reader warm. Each read is a single
/// native tree snapshot, carried as length-prefixed JSON over a local socket.
/// Wire format: facebook/idb v1.6.1, SimulatorFrameworkBridge/AccessibilityServiceServer.m.
@MainActor
final class JevSimulatorAccessibilityBridge {
    private let process = Process()
    private let socketPath = "/tmp/jev-ax-\(UUID().uuidString).sock"
    private var fd: Int32 = -1

    init(udid: String, helper: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw VPhoneJevSimulator.SimulatorError(description: "Missing simulator accessibility reader. Run make setup_jev.")
        }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "spawn", udid, helper.path, "accessibility", "serve",
                             socketPath, "--idle-timeout", "120", "--exit-on-disconnect", "true"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            let deadline = Date().addingTimeInterval(10)
            while !FileManager.default.fileExists(atPath: socketPath), Date() < deadline, process.isRunning {
                Thread.sleep(forTimeInterval: 0.02)
            }
            fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw failure("could not create socket") }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = socketPath.utf8CString
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { destination in
                    for (index, byte) in bytes.enumerated() { destination[index] = byte }
                }
            }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw failure("reader did not start") }
            var timeout = timeval(tv_sec: 15, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        // --exit-on-disconnect shuts down the guest, avoiding orphan readers.
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    func foreground() throws -> [String: Any] {
        // This is explicitly an application-root query, not a screen observation.
        // Children are deliberately omitted, so the reader marks it truncated.
        try request(["verb": "describe", "method": "window-server", "x": 0, "y": 0,
                     "snapshotTree": false, "automationMode": true, "maxDepth": 0,
                     "attributes": ["XC_kAXXCAttributeLabel", "XC_kAXXCAttributeFrame"]], rootOnly: true)
    }

    func request(_ request: [String: Any], rootOnly: Bool = false) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: request)
        var count = UInt32(data.count).bigEndian
        var payload = withUnsafeBytes(of: &count) { Data($0) }
        payload.append(data)
        try payload.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw failure("write failed") }
                offset += written
            }
        }
        let header = try read(4)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= 16 * 1024 * 1024 else { throw failure("invalid response length") }
        guard let response = try JSONSerialization.jsonObject(with: read(Int(length))) as? [String: Any] else { throw failure("invalid response") }
        guard response["ok"] as? Bool == true else {
            let reason = response["error"] as? String ?? "request failed"
            if response["error_kind"] as? String == "assertion_failed" || reason.contains("expected ") {
                throw JevStaleTargetError(reason: reason)
            }
            throw failure(reason)
        }
        if response["truncated"] as? Bool == true && !rootOnly {
            throw failure("tree exceeded the reader budget")
        }
        return response
    }

    private func read(_ count: Int) throws -> Data {
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let received = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), count - offset)
                if received < 0, errno == EINTR { continue }
                guard received > 0 else { throw failure("reader disconnected or timed out") }
                offset += received
            }
        }
        return result
    }

    private func failure(_ detail: String) -> VPhoneJevSimulator.SimulatorError {
        .init(description: "Simulator accessibility: \(detail). OCR is disabled.")
    }
}
