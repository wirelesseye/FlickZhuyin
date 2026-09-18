import Foundation

struct CanonicalSyllable: Hashable, Codable, Sendable {
    let base: String
    let tone: MandarinTone
}
