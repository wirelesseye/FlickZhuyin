import Foundation

struct CandidateID: Hashable, Sendable {
    let text: String
    let pronunciation: [SyllableConstraint]
    let tokenRange: Range<Int>

    var accessibilityIdentifier: String {
        let pronunciationKey = pronunciation
            .map { "\($0.base)\($0.tone?.rawValue ?? 0)" }
            .joined(separator: "-")
        return "candidate-\(tokenRange.lowerBound)-\(tokenRange.upperBound)-\(pronunciationKey)"
    }
}

struct InputCandidate: Equatable, Identifiable, Sendable {
    let id: CandidateID
    let text: String
    let pronunciation: [SyllableConstraint]
    let score: Double
    let isRawFallback: Bool

    init(
        id: CandidateID,
        text: String,
        pronunciation: [SyllableConstraint],
        score: Double,
        isRawFallback: Bool
    ) {
        self.id = id
        self.text = text
        self.pronunciation = pronunciation
        self.score = score
        self.isRawFallback = isRawFallback
    }

    init(decoded: DecodedCandidate) {
        self.init(
            id: CandidateID(
                text: decoded.text,
                pronunciation: decoded.pronunciation,
                tokenRange: decoded.tokenRange
            ),
            text: decoded.text,
            pronunciation: decoded.pronunciation,
            score: decoded.score,
            isRawFallback: decoded.segments.allSatisfy { segment in
                if case .raw = segment {
                    return true
                }
                return false
            }
        )
    }

    static func rawFallback(
        tokens: [ZhuyinInputToken],
        pronunciation: [SyllableConstraint] = [],
        score: Double
    ) -> InputCandidate? {
        guard !tokens.isEmpty else { return nil }
        let text = tokens.map(\.displayText).joined()
        return InputCandidate(
            id: CandidateID(text: text, pronunciation: pronunciation, tokenRange: 0..<tokens.count),
            text: text,
            pronunciation: pronunciation,
            score: score,
            isRawFallback: true
        )
    }
}
