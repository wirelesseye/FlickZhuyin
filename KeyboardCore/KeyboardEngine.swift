import Foundation

struct KeyboardEngine: Sendable {
    private(set) var mode: KeyboardMode
    private(set) var letterCase: LetterCaseState = .lowercase
    private(set) var composition = ZhuyinComposition()
    private var lastShiftTap: TimeInterval?

    init(mode: KeyboardMode = .zhuyin) {
        self.mode = mode
    }

    var markedText: String {
        composition.markedText
    }

    var activeTokenText: String {
        composition.activeTokenText
    }

    var hasActiveTokens: Bool {
        !composition.activeTokens.isEmpty
    }

    var hasMarkedText: Bool {
        !composition.isEmpty
    }

    var hasPendingTokens: Bool {
        composition.hasPendingTokens
    }

    mutating func update(
        for key: KeyboardKey,
        at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> KeyboardUpdate {
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
            return KeyboardUpdate(documentEffects: [.insertText(text)])
        case let .zhuyin(character):
            guard mode == .zhuyin else { return .none }
            composition.insertSymbol(character)
            return activeRunUpdate()
        case let .digit(character):
            guard mode == .number else { return .none }
            return KeyboardUpdate(documentEffects: [.insertText(String(character))])
        case let .tone(tone):
            guard mode == .zhuyin, composition.applyTone(tone) else { return .none }
            return activeRunUpdate()
        case .shift:
            guard mode == .abc else { return .none }
            updateShift(at: timestamp)
            return .none
        case .delete:
            guard mode == .zhuyin, !composition.isEmpty else {
                return KeyboardUpdate(documentEffects: [.deleteBackward])
            }
            guard composition.deletePieceBeforeCaret() else { return .none }
            if composition.isEmpty {
                return KeyboardUpdate(
                    documentEffects: [.setMarkedText("", caret: 0), .unmarkText],
                    invalidatesCandidates: true
                )
            }
            return activeRunUpdate()
        case .cursorLeft:
            return cursorUpdate(by: -1)
        case .cursorRight:
            return cursorUpdate(by: 1)
        case .space:
            guard mode == .zhuyin, !composition.isEmpty else {
                return KeyboardUpdate(documentEffects: [.insertText(" ")])
            }
            return .none
        case .return:
            guard mode == .zhuyin, !composition.isEmpty else {
                return KeyboardUpdate(documentEffects: [.insertText("\n")])
            }
            let committedText = composition.markedText
            composition = ZhuyinComposition()
            return KeyboardUpdate(
                documentEffects: [.insertText(committedText)],
                invalidatesCandidates: true
            )
        case .nextKeyboard:
            guard mode == .zhuyin, !composition.isEmpty else {
                return KeyboardUpdate(documentEffects: [.showInputModeList])
            }
            composition = ZhuyinComposition()
            return KeyboardUpdate(
                documentEffects: [.unmarkText, .showInputModeList],
                invalidatesCandidates: true
            )
        case .modeSwitch:
            switch mode {
            case .zhuyin:
                let hadComposition = !composition.isEmpty
                composition = ZhuyinComposition()
                mode = .abc
                return KeyboardUpdate(
                    documentEffects: hadComposition ? [.unmarkText] : [],
                    invalidatesCandidates: hadComposition
                )
            case .number:
                mode = .abc
                return .none
            case .abc:
                mode = .zhuyin
                return .none
            }
        case .numberSwitch:
            switch mode {
            case .zhuyin:
                let hadComposition = !composition.isEmpty
                composition = ZhuyinComposition()
                mode = .number
                return KeyboardUpdate(
                    documentEffects: hadComposition ? [.unmarkText] : [],
                    invalidatesCandidates: hadComposition
                )
            case .number:
                mode = .zhuyin
                return .none
            case .abc:
                return .none
            }
        }
    }

    mutating func selectCandidate(_ candidate: InputCandidate, autoCommit: Bool = false) -> KeyboardUpdate {
        let tokens = composition.activeTokens
        guard mode == .zhuyin, !tokens.isEmpty else { return .none }
        composition.replaceActiveTokens(
            with: SelectedChunk(
                text: candidate.text,
                sourceTokens: tokens,
                pronunciation: candidate.pronunciation
            )
        )
        if autoCommit, !composition.hasPendingTokens {
            let committedText = composition.markedText
            composition = ZhuyinComposition()
            return KeyboardUpdate(
                documentEffects: [.insertText(committedText)],
                invalidatesCandidates: true
            )
        }
        let remainingTokens = composition.activeTokens
        var update = KeyboardUpdate(
            documentEffects: [.setMarkedText(composition.markedText, caret: composition.caretOffset)],
            invalidatesCandidates: remainingTokens.isEmpty
        )
        if !remainingTokens.isEmpty {
            update.candidateRequest = candidateRequest(for: remainingTokens)
        }
        return update
    }

    mutating func resetComposition() -> KeyboardUpdate {
        guard !composition.isEmpty else { return .none }
        composition = ZhuyinComposition()
        return KeyboardUpdate(invalidatesCandidates: true)
    }

    private func activeRunUpdate() -> KeyboardUpdate {
        let effects: [DocumentEffect] = [
            .setMarkedText(composition.markedText, caret: composition.caretOffset)
        ]
        let tokens = composition.activeTokens
        guard !tokens.isEmpty else {
            return KeyboardUpdate(documentEffects: effects, invalidatesCandidates: true)
        }
        return KeyboardUpdate(
            documentEffects: effects,
            candidateRequest: candidateRequest(for: tokens)
        )
    }

    private func candidateRequest(for tokens: [ZhuyinInputToken]) -> CandidateRequest {
        let context = composition.precedingContext
        return CandidateRequest(
            tokens: tokens,
            precedingText: context.text,
            continuesDocument: context.reachesStart
        )
    }

    private mutating func cursorUpdate(by offset: Int) -> KeyboardUpdate {
        guard !composition.isEmpty else {
            return KeyboardUpdate(documentEffects: [.moveCursor(by: offset)])
        }
        guard composition.moveCaret(by: offset) else { return .none }
        return activeRunUpdate()
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
