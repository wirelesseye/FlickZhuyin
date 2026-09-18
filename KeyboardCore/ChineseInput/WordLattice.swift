import Foundation

struct WordEdge: Equatable, Sendable {
    let tokenRange: Range<Int>
    let text: String
    let pronunciation: [CanonicalSyllable]
    let sourceWeight: Double?
    let syllableEdges: [SyllableEdge]
}

struct WordLattice: Sendable {
    let tokenCount: Int
    let outgoingEdges: [[WordEdge]]
}
