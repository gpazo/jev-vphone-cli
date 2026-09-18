import CoreGraphics
import Foundation

// MARK: - Host Control Socket Client

/// Talks to a running `vphone-cli boot` process over its automation socket.
///
/// The agent can run either in-process (menu bar) or as a separate `jev`
/// command against an already-booted VM. This is the out-of-process path:
/// one JSON line in, one JSON line out, connection closed.
struct VPhoneJevSocketClient: Sendable {
    let socketPath: String

    enum SocketError: Error, CustomStringConvertible {
        case cannotConnect(String)
        case pathTooLong
        case writeFailed
        case noResponse
        case malformed(String)
        case remote(String)

        var description: String {
            switch self {
            case let .cannotConnect(path):
                """
                Could not connect to \(path). Is the VM running? \
                Start it with `make boot`, which creates the socket next to the VM config.
                """
            case .pathTooLong: "Socket path is too long for sockaddr_un"
            case .writeFailed: "Failed to write command to socket"
            case .noResponse: "No response from vphone-cli"
            case let .malformed(detail): "Malformed response: \(detail)"
            case let .remote(message): message
            }
        }
    }

    /// Send one command and decode the JSON reply.
    @discardableResult
    func send(_ command: [String: Any]) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.cannotConnect(socketPath) }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw SocketError.pathTooLong
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { dest in
            dest.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { raw in
                for (index, byte) in pathBytes.enumerated() { raw[index] = byte }
            }
        }

        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                connect(fd, raw, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw SocketError.cannotConnect(socketPath) }

        var payload = try JSONSerialization.data(withJSONObject: command)
        payload.append(0x0A)
        try payload.withUnsafeBytes { buffer in
            var remaining = buffer.count
            var offset = 0
            while remaining > 0 {
                let written = write(fd, buffer.baseAddress!.advanced(by: offset), remaining)
                guard written > 0 else { throw SocketError.writeFailed }
                offset += written
                remaining -= written
            }
        }

        var accumulated = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { break }
            accumulated.append(contentsOf: chunk[..<n])
            if accumulated.last == 0x0A { break }
        }
        guard !accumulated.isEmpty else { throw SocketError.noResponse }

        guard let json = try JSONSerialization.jsonObject(with: accumulated) as? [String: Any] else {
            throw SocketError.malformed(String(data: accumulated, encoding: .utf8) ?? "<non-UTF8>")
        }
        guard json["ok"] as? Bool == true else {
            throw SocketError.remote(json["error"] as? String ?? "command failed")
        }
        return json
    }
}

// MARK: - Socket-backed Observation

/// Observes through a running VM's automation socket.
///
/// Which provider actually ran — accessibility tree or OCR — is decided
/// host-side and reported back in `source`.
@MainActor
struct JevSocketObserver: JevObservationProvider {
    let client: VPhoneJevSocketClient

    func observe() async throws -> JevObservation {
        let response = try client.send(["t": "observe", "screen": false])

        let rawElements = response["elements"] as? [[String: Any]] ?? []
        let elements = rawElements.compactMap { raw -> JevElement? in
            guard let id = raw["id"] as? String, let label = raw["label"] as? String else { return nil }
            return JevElement(
                id: id,
                role: raw["role"] as? String,
                label: label,
                value: raw["value"] as? String,
                point: CGPoint(
                    x: raw["x"] as? Double ?? Double(raw["x"] as? Int ?? 0),
                    y: raw["y"] as? Double ?? Double(raw["y"] as? Int ?? 0)
                )
            )
        }

        let screenInfo = response["screen"] as? [String: Any] ?? [:]
        return JevObservation(
            foregroundApp: response["foreground"] as? String ?? "unknown",
            elements: elements,
            bounds: CGRect(
                x: 0, y: 0,
                width: screenInfo["width"] as? Int ?? 0,
                height: screenInfo["height"] as? Int ?? 0
            ),
            source: JevObservation.Source(rawValue: response["source"] as? String ?? "") ?? .ocr
        )
    }

    /// Installed apps, offered to Jev as `open_app` options.
    func installedApps() -> [(bundleId: String, name: String)] {
        guard let response = try? client.send(["t": "apps", "filter": "user", "screen": false]),
              let raw = response["apps"] as? [[String: Any]]
        else { return [] }

        return raw.compactMap { entry in
            guard let bundleId = entry["bundle_id"] as? String,
                  let name = entry["name"] as? String
            else { return nil }
            return (bundleId: bundleId, name: name)
        }
    }
}

// MARK: - Socket-backed Actuation

/// Executes agent actions through a running VM's automation socket.
@MainActor
struct JevSocketActuator: JevActuator {
    let client: VPhoneJevSocketClient
    let screen: CGSize

    func tap(at point: CGPoint) async throws {
        try client.send(["t": "tap", "x": point.x, "y": point.y, "screen": false])
    }

    func scroll(reveal direction: JevScrollDirection) async throws {
        // Revealing content *below* means dragging the content upward.
        let midX = screen.width / 2
        let near = screen.height * 0.70
        let far = screen.height * 0.30
        let (fromY, toY) = direction == .below ? (near, far) : (far, near)

        try client.send([
            "t": "swipe",
            "x1": midX, "y1": fromY,
            "x2": midX, "y2": toY,
            "ms": 350,
            "screen": false,
        ])
    }

    func type(_ text: String) async throws {
        // "typetext", not "type": the latter only sets the guest clipboard,
        // so nothing would ever appear in the focused field.
        try client.send(["t": "typetext", "text": text, "screen": false])
    }

    func pressHome() async throws {
        try client.send(["t": "key", "name": "home", "screen": false])
    }

    func launch(bundleId: String) async throws {
        try client.send(["t": "launch", "bundle": bundleId, "screen": false])
    }
}

// MARK: - Dry Run

/// Records what would have happened without touching the phone.
@MainActor
final class JevDryRunActuator: JevActuator {
    private(set) var performed: [String] = []

    func tap(at point: CGPoint) async throws {
        performed.append("tap(\(Int(point.x)), \(Int(point.y)))")
    }

    func scroll(reveal direction: JevScrollDirection) async throws {
        performed.append("scroll(\(direction == .below ? "down" : "up"))")
    }

    func type(_ text: String) async throws { performed.append("type(\(text))") }
    func pressHome() async throws { performed.append("home") }
    func launch(bundleId: String) async throws { performed.append("launch(\(bundleId))") }
}
