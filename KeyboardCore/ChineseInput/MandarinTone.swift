import Foundation

enum MandarinTone: UInt8, Codable, CaseIterable, Sendable {
    case first = 1
    case second = 2
    case third = 3
    case fourth = 4
    case neutral = 5

    init?(digit: Character) {
        guard let value = digit.wholeNumberValue, let tone = MandarinTone(rawValue: UInt8(value)) else {
            return nil
        }
        self = tone
    }

    var digit: Character {
        Character(String(rawValue))
    }

    var symbol: String {
        switch self {
        case .first: "ˉ"
        case .second: "ˊ"
        case .third: "ˇ"
        case .fourth: "ˋ"
        case .neutral: "˙"
        }
    }
}
