import Foundation

enum SyllableCompleteness: Hashable, Sendable {
    case complete
    case incomplete
    case fallback
}

struct SyllableEdge: Hashable, Sendable {
    let tokenRange: Range<Int>
    let constraint: SyllableConstraint
    let completeness: SyllableCompleteness
    let parserCost: Double
}

struct SyllableLattice: Sendable {
    let tokenCount: Int
    let outgoingEdges: [[SyllableEdge]]
}
