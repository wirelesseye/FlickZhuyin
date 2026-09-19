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

    var pendingText: String {
        composition.pendingText
    }

    var hasPendingTokens: Bool {
        !composition.pendingTokens.isEmpty
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
            composition.pendingTokens.append(.symbol(character))
            return pendingUpdate()
        case let .tone(tone):
            guard mode == .zhuyin, !composition.pendingTokens.isEmpty else { return .none }
            if case .tone = composition.pendingTokens.last {
                composition.pendingTokens[composition.pendingTokens.count - 1] = .tone(tone)
            } else {
                composition.pendingTokens.append(.tone(tone))
            }
            return pendingUpdate()
        case .shift:
            guard mode == .abc else { return .none }
            updateShift(at: timestamp)
            return .none
        case .delete:
            guard mode == .zhuyin else {
                return KeyboardUpdate(documentEffects: [.deleteBackward])
            }
            if !composition.pendingTokens.isEmpty {
                composition.pendingTokens.removeLast()
                if composition.pendingTokens.isEmpty {
                    if composition.selectedChunks.isEmpty {
                        return KeyboardUpdate(
                            documentEffects: [.setMarkedText(""), .unmarkText],
                            invalidatesCandidates: true
                        )
                    }
                    return KeyboardUpdate(
                        documentEffects: [.setMarkedText(composition.markedText)],
                        invalidatesCandidates: true
                    )
                }
                return pendingUpdate()
            }
            if !composition.selectedChunks.isEmpty {
                let chunk = composition.selectedChunks.removeLast()
                composition.pendingTokens = chunk.sourceTokens
                return pendingUpdate()
            }
            return KeyboardUpdate(documentEffects: [.deleteBackward])
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
            case .abc:
                mode = .zhuyin
                return .none
            }
        }
    }

    mutating func selectCandidate(_ candidate: InputCandidate) -> KeyboardUpdate {
        guard mode == .zhuyin, !composition.pendingTokens.isEmpty else { return .none }
        composition.selectedChunks.append(
            SelectedChunk(
                text: candidate.text,
                sourceTokens: composition.pendingTokens,
                pronunciation: candidate.pronunciation
            )
        )
        composition.pendingTokens.removeAll(keepingCapacity: true)
        return KeyboardUpdate(
            documentEffects: [.setMarkedText(composition.markedText)],
            invalidatesCandidates: true
        )
    }

    mutating func resetComposition() -> KeyboardUpdate {
        guard !composition.isEmpty else { return .none }
        composition = ZhuyinComposition()
        return KeyboardUpdate(invalidatesCandidates: true)
    }

    private func pendingUpdate() -> KeyboardUpdate {
        KeyboardUpdate(
            documentEffects: [.setMarkedText(composition.markedText)],
            candidateRequest: CandidateRequest(tokens: composition.pendingTokens)
        )
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
