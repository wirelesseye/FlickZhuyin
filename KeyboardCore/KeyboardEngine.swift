import Foundation

struct KeyboardEngine: Sendable {
    private(set) var mode: KeyboardMode
    private(set) var letterCase: LetterCaseState = .lowercase
    private var zhuyinTokens: [ZhuyinToken] = []
    private var lastShiftTap: TimeInterval?

    init(mode: KeyboardMode = .zhuyin) {
        self.mode = mode
    }

    var candidate: String? {
        guard !zhuyinTokens.isEmpty else { return nil }
        return zhuyinTokens.map(\.text).joined()
    }

    mutating func command(for key: KeyboardKey, at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) -> KeyboardCommand {
        switch key {
        case let .letter(character):
            guard mode == .abc else { return .none }
            let text = letterCase == .lowercase
                ? String(character).lowercased()
                : String(character).uppercased()
            if letterCase == .shifted {
                letterCase = .lowercase
            }
            lastShiftTap = nil
            return .insertText(text)
        case let .zhuyin(character):
            guard mode == .zhuyin else { return .none }
            zhuyinTokens.append(.symbol(character))
            return .none
        case let .tone(tone):
            guard mode == .zhuyin, !zhuyinTokens.isEmpty else { return .none }
            if case .some(.tone) = zhuyinTokens.last {
                zhuyinTokens[zhuyinTokens.count - 1] = .tone(tone)
            } else {
                zhuyinTokens.append(.tone(tone))
            }
            return .none
        case .shift:
            guard mode == .abc else { return .none }
            updateShift(at: timestamp)
            return .none
        case .delete:
            if mode == .zhuyin, !zhuyinTokens.isEmpty {
                zhuyinTokens.removeLast()
                return .none
            }
            return .deleteBackward
        case .space:
            return .insertText(" ")
        case .return:
            if mode == .zhuyin, let text = takeCandidate() {
                return .insertText(text + "\n")
            }
            return .insertText("\n")
        case .nextKeyboard:
            return .showInputModeList
        case .modeSwitch:
            let pendingText = mode == .zhuyin ? takeCandidate() : nil
            mode = mode == .zhuyin ? .abc : .zhuyin
            return pendingText.map(KeyboardCommand.insertText) ?? .none
        case .commitCandidate:
            guard let text = takeCandidate() else { return .none }
            return .insertText(text)
        }
    }

    private mutating func takeCandidate() -> String? {
        guard let candidate else { return nil }
        zhuyinTokens.removeAll(keepingCapacity: true)
        return candidate
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

private enum ZhuyinToken: Equatable, Sendable {
    case symbol(Character)
    case tone(ZhuyinTone)

    var text: String {
        switch self {
        case let .symbol(character): String(character)
        case let .tone(tone): tone.symbol
        }
    }
}
