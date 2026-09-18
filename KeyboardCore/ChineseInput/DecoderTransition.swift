import Foundation

struct DecoderTransition: Equatable, Sendable {
    enum Payload: Equatable, Sendable {
        case word(WordEdge)
        case raw(SyllableEdge)
    }

    let tokenRange: Range<Int>
    let text: String
    let pronunciation: [SyllableConstraint]
    let cost: Double
    let payload: Payload

    var segment: DecodedSegment {
        switch payload {
        case let .word(edge): .word(edge)
        case let .raw(edge): .raw(edge)
        }
    }

    var isRaw: Bool {
        if case .raw = payload {
            return true
        }
        return false
    }
}
