import CoreGraphics
import Foundation
import Vision

// MARK: - Observation Model

/// One addressable thing on the phone screen.
///
/// Coordinates are deliberately **not** part of what Jev sees: the model
/// selects an element by id, and code resolves that id back to a tap point.
/// Pixels never enter the judgment.
struct JevElement: Equatable {
    let id: String
    let role: String?
    let label: String
    let value: String?
    /// Tap point in screenshot pixel space (top-left origin).
    let point: CGPoint

    /// The projection sent to Jev.
    struct Described: Encodable {
        let id: String
        let role: String?
        let label: String
        let value: String?
    }

    var described: Described {
        Described(id: id, role: role, label: label, value: value)
    }

    /// Identity for stuck-detection: what the screen *is*, ignoring ids and
    /// sub-pixel jitter, so a redraw does not read as progress.
    var signature: String {
        "\(role ?? "-")|\(label)|\(value ?? "-")"
    }
}

/// A single reading of the phone's current screen.
struct JevObservation {
    enum Source: String {
        /// Semantic tree from the guest — roles, values, offscreen elements.
        case accessibility
        /// Host-side OCR of the framebuffer — visible text only.
        case ocr
    }

    let foregroundApp: String
    let elements: [JevElement]
    let screen: CGSize
    let source: Source

    func element(id: String) -> JevElement? {
        elements.first { $0.id == id }
    }

    /// Order-independent fingerprint of the screen, used to detect a loop.
    var signature: String {
        elements.map(\.signature).sorted().joined(separator: "\n")
    }
}

/// Anything that can turn the current screen into text.
///
/// Two implementations exist so the agent is independent of which one is
/// available: the guest accessibility tree when `vphoned` can produce it,
/// and host-side OCR otherwise. Swapping providers changes no agent code.
@MainActor
protocol JevObservationProvider {
    var source: JevObservation.Source { get }
    func observe() async throws -> JevObservation
}

// MARK: - Accessibility Provider

/// Reads the guest's semantic accessibility tree over vsock.
///
/// The host client (`VPhoneControl.accessibilityTree`) and the wire dispatch
/// in `vphoned.m` already exist; the guest-side handler is the open piece.
/// Until it lands this provider throws, and callers fall back to OCR.
@MainActor
struct JevAccessibilityProvider: JevObservationProvider {
    let control: VPhoneControl
    let screen: CGSize

    var source: JevObservation.Source { .accessibility }

    /// The accessibility server is off by default and returns nothing until
    /// enabled; enabling is idempotent, so it is attempted once per process
    /// rather than checked.
    private static var didEnableServer = false

    func observe() async throws -> JevObservation {
        if !Self.didEnableServer {
            Self.didEnableServer = true
            try? await control.accessibilityEnable()
        }

        // The guest describes one process, so find out which one is in front.
        let foreground = try? await control.appForeground()
        let response = try await control.accessibilityTree(pid: foreground?.pid)

        var elements: [JevElement] = []
        var counter = 0
        if let tree = response["tree"] as? [String: Any] {
            Self.flatten(tree, into: &elements, counter: &counter)
        }

        return JevObservation(
            foregroundApp: Self.describe(foreground),
            elements: elements,
            screen: screen,
            source: .accessibility
        )
    }

    /// Depth-first flatten of the guest tree into a flat, id-addressable list.
    ///
    /// Tolerant about key naming because the guest format is still being
    /// settled: any of `label`/`title`/`name`/`text` may carry the label.
    /// Nodes with no usable label are skipped but still recursed into.
    static func flatten(_ node: [String: Any], into out: inout [JevElement], counter: inout Int) {
        let label = ["label", "title", "name", "text"]
            .compactMap { node[$0] as? String }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        if let label {
            let frame = node["frame"] as? [Double] ?? []
            let point: CGPoint = if frame.count == 4 {
                CGPoint(x: frame[0] + frame[2] / 2, y: frame[1] + frame[3] / 2)
            } else {
                .zero
            }

            counter += 1
            out.append(
                JevElement(
                    id: "e\(counter)",
                    role: node["role"] as? String ?? node["type"] as? String,
                    label: label,
                    value: Self.stringValue(node["value"]),
                    point: point
                )
            )
        }

        for child in node["children"] as? [[String: Any]] ?? [] {
            flatten(child, into: &out, counter: &counter)
        }
    }

    /// Values arrive as strings, numbers or bools depending on the control.
    private static func stringValue(_ raw: Any?) -> String? {
        switch raw {
        case let s as String: s.isEmpty ? nil : s
        case let b as Bool: b ? "on" : "off"
        case let n as NSNumber: n.stringValue
        default: nil
        }
    }

    private static func describe(_ app: (bundleId: String, name: String, pid: Int)?) -> String {
        guard let app else { return "unknown" }
        return "\(app.name) (\(app.bundleId))"
    }
}

// MARK: - OCR Provider

/// Turns the VM framebuffer into text with the Vision framework.
///
/// This is the fallback path. It sees rendered text and nothing else — an
/// icon-only control is invisible to it, and it cannot report a toggle's
/// on/off state. Good enough to drive text-heavy UI; not a substitute for a
/// real accessibility tree.
@MainActor
struct JevOCRProvider: JevObservationProvider {
    /// Supplies the current framebuffer. Kept as a closure so this provider
    /// does not need to know how capture works.
    let capture: @MainActor () async -> CGImage?
    let control: VPhoneControl?
    let screen: CGSize
    /// Discard recognitions below this confidence before Jev ever sees them.
    var minimumTextConfidence: Float = 0.3

    var source: JevObservation.Source { .ocr }

    enum ObserverError: Error, CustomStringConvertible {
        case captureFailed

        var description: String {
            switch self {
            case .captureFailed: "Could not capture the VM screen for OCR"
            }
        }
    }

    func observe() async throws -> JevObservation {
        guard let image = await capture() else { throw ObserverError.captureFailed }

        let foreground = try? await control?.appForeground()
        let elements = Self.recognize(
            in: image,
            minimumConfidence: minimumTextConfidence
        )

        return JevObservation(
            foregroundApp: foreground.map { "\($0.name) (\($0.bundleId))" } ?? "unknown",
            elements: elements,
            screen: screen,
            source: .ocr
        )
    }

    /// Run OCR and map each recognized line to a tap point.
    ///
    /// Performed inline rather than hopped to a background actor: `CGImage`
    /// is not `Sendable`, and a single recognition pass is short enough that
    /// the hop would cost more than it saves.
    static func recognize(in image: CGImage, minimumConfidence: Float) -> [JevElement] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        let width = Double(image.width)
        let height = Double(image.height)

        return (request.results ?? [])
            .compactMap { observation -> JevElement? in
                guard let candidate = observation.topCandidates(1).first,
                      candidate.confidence >= minimumConfidence
                else { return nil }

                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }

                // Vision reports a normalized, bottom-left-origin box; tap
                // points are top-left-origin pixels.
                let box = observation.boundingBox
                return JevElement(
                    id: "",
                    role: nil,
                    label: text,
                    value: nil,
                    point: CGPoint(x: box.midX * width, y: (1 - box.midY) * height)
                )
            }
            // Reading order: top to bottom, then left to right.
            .sorted { ($0.point.y, $0.point.x) < ($1.point.y, $1.point.x) }
            .enumerated()
            .map { index, element in
                JevElement(
                    id: "e\(index + 1)",
                    role: element.role,
                    label: element.label,
                    value: element.value,
                    point: element.point
                )
            }
    }
}
