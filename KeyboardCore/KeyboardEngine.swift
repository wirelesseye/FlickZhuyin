import Foundation

struct KeyboardEngine: Sendable {
    private(set) var mode: KeyboardMode
    private(set) var letterCase: LetterCaseState = .lowercase
    private(set) var zhuyinSymbols: [Character] = []
    private(set) var zhuyinTone: ZhuyinTone?
    private var lastShiftTap: TimeInterval?

    init(mode: KeyboardMode = .zhuyin) {
        self.mode = mode
    }

    var candidate: String? {
        guard !zhuyinSymbols.isEmpty else { return nil }
        return String(zhuyinSymbols) + (zhuyinTone?.symbol ?? "")
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
            zhuyinSymbols.append(character)
            return .none
        case let .tone(tone):
            guard mode == .zhuyin, !zhuyinSymbols.isEmpty else { return .none }
            zhuyinTone = tone
            return .none
        case .shift:
            guard mode == .abc else { return .none }
            updateShift(at: timestamp)
            return .none
        case .delete:
            if mode == .zhuyin {
                if zhuyinTone != nil {
                    zhuyinTone = nil
                    return .none
                }
                if !zhuyinSymbols.isEmpty {
                    zhuyinSymbols.removeLast()
                    return .none
                }
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
        zhuyinSymbols.removeAll(keepingCapacity: true)
        zhuyinTone = nil
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
