import Foundation

struct SyllableConstraint: Hashable, Sendable {
    let base: String
    let tone: MandarinTone?

    init(base: String, tone: MandarinTone? = nil) {
        self.base = base
        self.tone = tone
    }
}

struct LexiconMatch: Equatable, Sendable {
    let text: String
    let pronunciation: [CanonicalSyllable]
    let sourceWeight: Double?
}

protocol LexiconStore: Sendable {
    func exactMatches(for syllables: [SyllableConstraint]) throws -> [LexiconMatch]
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
