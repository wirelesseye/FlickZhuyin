import Foundation

protocol DecoderScorer: Sendable {
    func cost(for word: WordEdge) throws -> Double
    func cost(forRaw edge: SyllableEdge) throws -> Double
}

struct BaselineDecoderScorer: DecoderScorer, Sendable {
    let configuration: DecoderConfiguration

    init(configuration: DecoderConfiguration = DecoderConfiguration()) {
        self.configuration = configuration
    }

    func cost(for word: WordEdge) throws -> Double {
        var cost = configuration.wordBoundaryCost
        for edge in word.syllableEdges {
            guard edge.parserCost.isFinite, edge.parserCost >= 0 else {
                throw DecoderError.scoringFailed("word parser cost \(edge.parserCost) is not finite and non-negative")
            }
            cost += edge.parserCost
        }
        if let weight = word.sourceWeight {
            guard weight.isFinite, weight >= 0, weight <= 1 else {
                throw DecoderError.scoringFailed("source weight \(weight) is outside 0...1")
            }
            cost += -log(max(weight, configuration.weightedEntryFloor))
        } else if word.pronunciationWeight == nil {
            cost += configuration.unweightedWordCost
        }
        if let prior = word.pronunciationWeight {
            guard prior.isFinite, prior >= 0, prior <= 1 else {
                throw DecoderError.scoringFailed("pronunciation weight \(prior) is outside 0...1")
            }
            cost += -log(max(prior, configuration.weightedEntryFloor))
        }
        return cost
    }

    func cost(forRaw edge: SyllableEdge) throws -> Double {
        guard edge.parserCost.isFinite, edge.parserCost >= 0 else {
            throw DecoderError.scoringFailed("raw parser cost \(edge.parserCost) is not finite and non-negative")
        }
        let penalty: Double
        switch edge.completeness {
        case .complete: penalty = configuration.completeRawCost
        case .incomplete: penalty = configuration.incompleteRawCost
        case .fallback: penalty = configuration.fallbackRawCost
        }
        return edge.parserCost + penalty
    }
}
