import Foundation

struct WordEdge: Equatable, Sendable {
    let tokenRange: Range<Int>
    let text: String
    let pronunciation: [CanonicalSyllable]
    let sourceWeight: Double?
    let pronunciationWeight: Double?
    let syllableEdges: [SyllableEdge]

    init(
        tokenRange: Range<Int>,
        text: String,
        pronunciation: [CanonicalSyllable],
        sourceWeight: Double?,
        pronunciationWeight: Double? = nil,
        syllableEdges: [SyllableEdge]
    ) {
        self.tokenRange = tokenRange
        self.text = text
        self.pronunciation = pronunciation
        self.sourceWeight = sourceWeight
        self.pronunciationWeight = pronunciationWeight
        self.syllableEdges = syllableEdges
    }
}

struct WordLattice: Sendable {
    let tokenCount: Int
    let outgoingEdges: [[WordEdge]]
}
