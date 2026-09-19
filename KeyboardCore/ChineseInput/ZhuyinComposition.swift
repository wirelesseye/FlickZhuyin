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

struct ZhuyinComposition: Equatable, Sendable {
    var selectedChunks: [SelectedChunk] = []
    var pendingTokens: [ZhuyinInputToken] = []

    var pendingText: String {
        pendingTokens.map(\.displayText).joined()
    }

    var markedText: String {
        selectedChunks.map(\.text).joined() + pendingText
    }

    var isEmpty: Bool {
        selectedChunks.isEmpty && pendingTokens.isEmpty
    }
}
