import Foundation

enum DecodedSegment: Equatable, Sendable {
    case word(WordEdge)
    case raw(SyllableEdge)

    var tokenRange: Range<Int> {
        switch self {
        case let .word(edge): edge.tokenRange
        case let .raw(edge): edge.tokenRange
        }
    }

    var text: String {
        switch self {
        case let .word(edge): edge.text
        case let .raw(edge): Self.rawText(for: edge.constraint)
        }
    }

    var pronunciation: [SyllableConstraint] {
        switch self {
        case let .word(edge):
            edge.pronunciation.map { SyllableConstraint(base: $0.base, tone: $0.tone) }
        case let .raw(edge):
            [edge.constraint]
        }
    }

    static func rawText(for constraint: SyllableConstraint) -> String {
        constraint.base + (constraint.tone?.symbol ?? "")
    }
}

struct DecodedCandidate: Equatable, Sendable {
    let text: String
    let pronunciation: [SyllableConstraint]
    let tokenRange: Range<Int>
    let score: Double
    let segments: [DecodedSegment]
}
