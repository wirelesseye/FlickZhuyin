import Foundation

enum FlickDirection: CaseIterable, Equatable, Sendable {
    case center
    case left
    case up
    case right
    case down
}

struct FlickKeyMapping: Equatable, Sendable {
    let center: String
    let left: String?
    let up: String?
    let right: String?
    let down: String?

    init(_ symbols: [String]) {
        precondition((1...5).contains(symbols.count))
        center = symbols[0]
        left = symbols[safe: 1]
        up = symbols[safe: 2]
        right = symbols[safe: 3]
        down = symbols[safe: 4]
    }

    subscript(direction: FlickDirection) -> String? {
        switch direction {
        case .center: center
        case .left: left
        case .up: up
        case .right: right
        case .down: down
        }
    }
}

enum FlickGestureResolver {
    static func direction(deltaX: Double, deltaY: Double, threshold: Double = 24) -> FlickDirection {
        guard max(abs(deltaX), abs(deltaY)) >= threshold else { return .center }
        if abs(deltaX) > abs(deltaY) {
            return deltaX < 0 ? .left : .right
        }
        return deltaY < 0 ? .up : .down
    }
}

enum ZhuyinLayout {
    static let groups: [FlickKeyMapping] = [
        FlickKeyMapping(["ㄅ", "ㄆ", "ㄇ", "ㄈ"]),
        FlickKeyMapping(["ㄉ", "ㄊ", "ㄋ", "ㄌ"]),
        FlickKeyMapping(["ㄍ", "ㄎ", "ㄏ", "ㄐ", "ㄑ"]),
        FlickKeyMapping(["ㄓ", "ㄔ", "ㄕ", "ㄖ", "ㄒ"]),
        FlickKeyMapping(["ㄗ", "ㄘ", "ㄙ"]),
        FlickKeyMapping(["ㄧ", "ㄨ", "ㄩ", "ㄦ"]),
        FlickKeyMapping(["ㄚ", "ㄛ", "ㄜ", "ㄝ"]),
        FlickKeyMapping(["ㄞ", "ㄟ", "ㄠ", "ㄡ"]),
        FlickKeyMapping(["ㄢ", "ㄣ", "ㄤ", "ㄥ"])
    ]

    static let tones = FlickKeyMapping([
        MandarinTone.first.symbol,
        MandarinTone.second.symbol,
        MandarinTone.third.symbol,
        MandarinTone.fourth.symbol
    ])

    static let punctuation = FlickKeyMapping(["，", "。", "？", "！"])

    static let secondaryPunctuation = FlickKeyMapping(["…", "「", "：", "」"])

    static func tone(for direction: FlickDirection) -> MandarinTone? {
        switch direction {
        case .center: .first
        case .left: .second
        case .up: .third
        case .right: .fourth
        case .down: nil
        }
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
