import Foundation

extension ZhuyinInputToken {
    var displayText: String {
        switch self {
        case let .symbol(character): String(character)
        case let .tone(tone): tone.symbol
        }
    }
}

struct SelectedChunk: Equatable, Sendable {
    let id: UUID
    let text: String
    let sourceTokens: [ZhuyinInputToken]
    let pronunciation: [SyllableConstraint]

    init(
        id: UUID = UUID(),
        text: String,
        sourceTokens: [ZhuyinInputToken],
        pronunciation: [SyllableConstraint]
    ) {
        self.id = id
        self.text = text
        self.sourceTokens = sourceTokens
        self.pronunciation = pronunciation
    }
}

enum ZhuyinCompositionPiece: Equatable, Sendable {
    case selected(SelectedChunk)
    case token(ZhuyinInputToken)

    var displayText: String {
        switch self {
        case let .selected(chunk): chunk.text
        case let .token(token): token.displayText
        }
    }

    var token: ZhuyinInputToken? {
        guard case let .token(token) = self else { return nil }
        return token
    }
}

struct ZhuyinComposition: Equatable, Sendable {
    var pieces: [ZhuyinCompositionPiece] = []
    var caretIndex: Int = 0

    var markedText: String {
        pieces.map(\.displayText).joined()
    }

    var caretOffset: Int {
        pieces[..<caretIndex].reduce(0) { $0 + $1.displayText.utf16.count }
    }

    var isEmpty: Bool {
        pieces.isEmpty
    }

    var selectedChunks: [SelectedChunk] {
        pieces.compactMap {
            guard case let .selected(chunk) = $0 else { return nil }
            return chunk
        }
    }

    var activeTokenRange: Range<Int> {
        var lower = caretIndex
        var upper = caretIndex
        while lower > 0, pieces[lower - 1].token != nil { lower -= 1 }
        while upper < pieces.count, pieces[upper].token != nil { upper += 1 }
        return lower..<upper
    }

    var activeTokens: [ZhuyinInputToken] {
        pieces[activeTokenRange].compactMap(\.token)
    }

    var activeTokenText: String {
        activeTokens.map(\.displayText).joined()
    }

    mutating func insertSymbol(_ character: Character) {
        pieces.insert(.token(.symbol(character)), at: caretIndex)
        caretIndex += 1
    }

    mutating func applyTone(_ tone: MandarinTone) -> Bool {
        let range = activeTokenRange
        guard !range.isEmpty else { return false }
        let lastIndex = range.upperBound - 1
        if case .token(.tone) = pieces[lastIndex] {
            pieces[lastIndex] = .token(.tone(tone))
            caretIndex = range.upperBound
        } else {
            pieces.insert(.token(.tone(tone)), at: range.upperBound)
            caretIndex = range.upperBound + 1
        }
        return true
    }

    @discardableResult
    mutating func deletePieceBeforeCaret() -> Bool {
        guard caretIndex > 0 else { return false }
        switch pieces[caretIndex - 1] {
        case .token:
            pieces.remove(at: caretIndex - 1)
            caretIndex -= 1
        case let .selected(chunk):
            let restored = chunk.sourceTokens.map(ZhuyinCompositionPiece.token)
            pieces.replaceSubrange((caretIndex - 1)..<caretIndex, with: restored)
            caretIndex = caretIndex - 1 + restored.count
        }
        return true
    }

    mutating func moveCaret(by offset: Int) -> Bool {
        let target = caretIndex + offset
        guard target >= 0, target <= pieces.count else { return false }
        caretIndex = target
        return true
    }

    mutating func replaceActiveTokens(with chunk: SelectedChunk) {
        let range = activeTokenRange
        pieces.replaceSubrange(range, with: [.selected(chunk)])
        caretIndex = range.lowerBound + 1
    }
}
