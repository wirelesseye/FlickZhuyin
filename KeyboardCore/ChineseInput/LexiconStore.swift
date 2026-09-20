import Foundation

struct SyllableConstraint: Hashable, Sendable {
    let base: String
    let tone: MandarinTone?

    init(base: String, tone: MandarinTone? = nil) {
        self.base = base
        self.tone = tone
    }
}

enum SyllableMatchPattern: Hashable, Sendable {
    case exact(SyllableConstraint)
    case initial(Character)

    var isExact: Bool {
        if case .exact = self {
            return true
        }
        return false
    }

    var exactConstraint: SyllableConstraint? {
        if case let .exact(constraint) = self {
            return constraint
        }
        return nil
    }

    var initialCharacter: Character? {
        switch self {
        case let .exact(constraint):
            return constraint.base.first
        case let .initial(character):
            return character
        }
    }

    func accepts(base: String, tone: MandarinTone) -> Bool {
        switch self {
        case let .exact(constraint):
            guard base == constraint.base else { return false }
            if let expected = constraint.tone, expected != tone {
                return false
            }
            return true
        case let .initial(character):
            return base.first == character
        }
    }
}

struct LexiconMatch: Equatable, Sendable {
    let text: String
    let pronunciation: [CanonicalSyllable]
    let sourceWeight: Double?
}

protocol LexiconStore: Sendable {
    func exactMatches(for syllables: [SyllableConstraint]) throws -> [LexiconMatch]
    func patternMatches(
        for patterns: [SyllableMatchPattern],
        resultLimit: Int,
        scanLimit: Int
    ) throws -> [LexiconMatch]
    func syllableInventory() throws -> [String]
}

enum LexiconStoreError: Error, Equatable {
    case databaseMissing(URL)
    case resourceNotFound(String)
    case openFailed(String)
    case schemaMismatch(String)
    case corruptDatabase(String)
    case queryFailed(String)
}
