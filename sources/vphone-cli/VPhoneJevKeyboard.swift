import CoreGraphics
import Foundation

// MARK: - On-screen Keyboard

/// Types by tapping the on-screen keyboard, one key at a time.
///
/// Text entry needs three separate things, and only one of them is a
/// judgment: *deciding to type* (Jev), *choosing the words* (a language
/// model, or a span lifted from the goal), and *getting the characters in*
/// (this). The third is a deterministic lookup from a string that is already
/// known — character to key position — so it costs no model calls at all.
///
/// It exists because synthetic key events do not reach the iOS Simulator:
/// neither `cghidEventTap` nor `postToPid` delivers, with Accessibility
/// granted and the hardware keyboard connected. Taps do work, and OCR reads
/// the keycaps cleanly, so the keyboard is driven the way a person drives it.
///
/// The vphone VM does not need this — `VPhoneKeyHelper.typeString` sends real
/// key events into the guest — so this is wired only where it is required.
@MainActor
struct JevKeyboardTypist {
    /// Re-read the screen. Needed after every plane switch, because the
    /// layout changes underneath.
    let observe: () async throws -> JevObservation
    let tap: (CGPoint) async throws -> Void

    /// Pause after each keystroke. The keyboard animates and swallows taps
    /// that arrive mid-transition.
    var keyDelayMilliseconds = 90

    enum TypingError: Error, CustomStringConvertible {
        case noKeyboard
        case unavailable(Character)
        case verificationFailed(expected: String)

        var description: String {
            switch self {
            case .noKeyboard:
                "No on-screen keyboard is visible — tap a text field first"
            case let .unavailable(character):
                "No key found for \"\(character)\" on any keyboard plane"
            case let .verificationFailed(expected):
                "Typed text does not match \"\(expected)\""
            }
        }
    }

    // MARK: Layout

    /// Where each key is, in the observation's coordinate space.
    struct Layout {
        var characters: [Character: CGPoint] = [:]
        var shift: CGPoint?
        /// The key that switches between letters and numbers/symbols.
        var planeSwitch: CGPoint?
        var space: CGPoint?
        var delete: CGPoint?

        /// Filled in only when the layout could be located at all.
        var isKeyboard: Bool { characters.count >= 20 }
    }

    /// The iOS QWERTY letter plane. Fixed, which is the whole point: the
    /// layout does not need to be read, only located.
    static let letterRows: [[Character]] = [
        Array("qwertyuiop"),
        Array("asdfghjkl"),
        Array("zxcvbnm"),
    ]

    /// Locate the keyboard from however few keycaps OCR managed to read.
    ///
    /// Reading every key is not realistic — iOS keycaps are low-contrast and
    /// Vision recognises isolated characters unreliably; a real capture here
    /// yielded three of twenty-six. But the layout is *known*, so the
    /// recognised keys are used as anchors to solve for the origin and key
    /// pitch, and every remaining key is computed from the standard
    /// arrangement. Two anchors in one row are enough; one anchor plus the
    /// usual row insets will do.
    static func layout(from observation: JevObservation) -> Layout {
        var layout = Layout()

        // Where each recognised keycap sits in the standard layout.
        struct Anchor {
            let row: Int
            let index: Int
            let point: CGPoint
        }
        var anchors: [Anchor] = []
        for element in observation.elements where element.label.count == 1 {
            guard let character = element.label.lowercased().first else { continue }
            for (row, keys) in letterRows.enumerated() {
                if let index = keys.firstIndex(of: character) {
                    anchors.append(Anchor(row: row, index: index, point: element.point))
                }
            }
        }
        guard !anchors.isEmpty else { return layout }

        // Key pitch: from two anchors sharing a row if possible, since that
        // measures it directly.
        var pitch: Double?
        for row in 0 ..< letterRows.count {
            let inRow = anchors.filter { $0.row == row }.sorted { $0.index < $1.index }
            guard let first = inRow.first, let last = inRow.last, first.index != last.index
            else { continue }
            pitch = (last.point.x - first.point.x) / Double(last.index - first.index)
            break
        }
        // Otherwise infer it from the screen: ten keys span the full width.
        let keyPitch = pitch ?? (observation.bounds.width / 10)

        // Row 0 spans the full width; each lower row is inset by half a key.
        let rowInset: [Double] = [0, 0.5, 1.5]
        func originX(row: Int) -> Double {
            if let anchor = anchors.first(where: { $0.row == row }) {
                return anchor.point.x - Double(anchor.index) * keyPitch
            }
            return observation.bounds.minX + keyPitch * (0.5 + rowInset[row])
        }

        // Row spacing: measured between two anchored rows, else proportional.
        var rowGap = keyPitch * 1.25
        let rowsSeen = Set(anchors.map(\.row)).sorted()
        if rowsSeen.count >= 2, let low = rowsSeen.first, let high = rowsSeen.last,
           let a = anchors.first(where: { $0.row == low }),
           let b = anchors.first(where: { $0.row == high })
        {
            rowGap = (b.point.y - a.point.y) / Double(high - low)
        }
        func originY(row: Int) -> Double {
            if let anchor = anchors.first(where: { $0.row == row }) { return anchor.point.y }
            let known = anchors[0]
            return known.point.y + Double(row - known.row) * rowGap
        }

        for (row, keys) in letterRows.enumerated() {
            let x0 = originX(row: row)
            let y = originY(row: row)
            for (index, key) in keys.enumerated() {
                layout.characters[key] = CGPoint(x: x0 + Double(index) * keyPitch, y: y)
            }
        }

        // Shift and delete bracket the bottom letter row; the space row sits
        // one gap below it with the plane switch at its left.
        let bottomY = originY(row: 2)
        let bottomX0 = originX(row: 2)
        let bottomEnd = bottomX0 + Double(letterRows[2].count - 1) * keyPitch
        layout.shift = CGPoint(x: bottomX0 - keyPitch * 1.5, y: bottomY)
        layout.delete = CGPoint(x: bottomEnd + keyPitch * 1.5, y: bottomY)
        layout.space = CGPoint(x: observation.bounds.midX, y: bottomY + rowGap)
        layout.planeSwitch = CGPoint(x: bottomX0 - keyPitch * 1.5, y: bottomY + rowGap)

        return layout
    }

    // MARK: Typing

    /// Type `text`, then check it actually arrived.
    ///
    /// Keystrokes land imperfectly — a first tap can arrive while the
    /// keyboard is still animating in, and autocorrect rewrites things. A
    /// real run produced "cweather" for "weather". So the field is read back
    /// and, if it does not contain what was intended, cleared and retyped
    /// once. Same principle as the tap retry: don't assume it worked, look.
    func type(_ text: String) async throws {
        for attempt in 1 ... 2 {
            try await enter(text)

            let after = try await observe()
            if Self.fieldContains(text, in: after) { return }
            guard attempt == 1 else { break }

            // Clear generously: there may be more in the field than we put
            // there, and delete is a no-op on an empty field.
            if let delete = Self.layout(from: after).delete {
                for _ in 0 ..< (text.count + 6) { try await press(delete) }
            }
        }
        throw TypingError.verificationFailed(expected: text)
    }

    /// Whether the intended text shows up anywhere on screen, which for a
    /// focused field means it was entered.
    static func fieldContains(_ text: String, in observation: JevObservation) -> Bool {
        let wanted = text.lowercased()
        return observation.elements.contains { element in
            element.label.lowercased().contains(wanted)
        }
    }

    /// One pass of key tapping, no verification.
    private func enter(_ text: String) async throws {
        var observation = try await observe()
        var layout = Self.layout(from: observation)
        guard layout.isKeyboard else { throw TypingError.noKeyboard }

        for character in text {
            if character == " " {
                if let space = layout.space { try await press(space) }
                continue
            }

            let lowered = Character(character.lowercased())

            // Not on this plane: switch, re-read, and look again. The layout
            // is entirely different afterwards, so it must be rebuilt.
            if layout.characters[lowered] == nil, let planeSwitch = layout.planeSwitch {
                try await press(planeSwitch)
                observation = try await observe()
                layout = Self.layout(from: observation)
            }

            guard let point = layout.characters[lowered] else {
                throw TypingError.unavailable(character)
            }

            // iOS releases shift after one character, so it is pressed per
            // capital rather than held.
            if character.isUppercase, let shift = layout.shift {
                try await press(shift)
            }
            try await press(point)
        }
    }

    private func press(_ point: CGPoint) async throws {
        try await tap(point)
        try? await Task.sleep(nanoseconds: UInt64(keyDelayMilliseconds) * 1_000_000)
    }
}
