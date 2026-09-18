import Foundation

struct KeyboardEngine: Sendable {
    private(set) var letterCase: LetterCaseState = .lowercase
    private var lastShiftTap: TimeInterval?

    mutating func command(for key: KeyboardKey, at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) -> KeyboardCommand {
        switch key {
        case let .letter(character):
            let text = letterCase == .lowercase
                ? String(character).lowercased()
                : String(character).uppercased()
            if letterCase == .shifted {
                letterCase = .lowercase
            }
            lastShiftTap = nil
            return .insertText(text)
        case .shift:
            updateShift(at: timestamp)
            return .none
        case .delete:
            return .deleteBackward
        case .space:
            return .insertText(" ")
        case .return:
            return .insertText("\n")
        case .nextKeyboard:
            return .showInputModeList
        }
    }

    private mutating func updateShift(at timestamp: TimeInterval) {
        if letterCase == .capsLocked {
            letterCase = .lowercase
            lastShiftTap = nil
            return
        }

        if let lastShiftTap, timestamp - lastShiftTap <= 0.3 {
            letterCase = .capsLocked
            self.lastShiftTap = nil
        } else {
            letterCase = letterCase == .shifted ? .lowercase : .shifted
            lastShiftTap = timestamp
        }
    }
}
