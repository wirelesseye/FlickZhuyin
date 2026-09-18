import Foundation

enum KeyboardKey: Equatable, Sendable {
    case letter(Character)
    case zhuyin(Character)
    case tone(ZhuyinTone)
    case shift
    case delete
    case space
    case `return`
    case nextKeyboard
    case modeSwitch
    case commitCandidate
}

enum KeyboardCommand: Equatable, Sendable {
    case insertText(String)
    case deleteBackward
    case showInputModeList
    case none
}

enum LetterCaseState: Equatable, Sendable {
    case lowercase
    case shifted
    case capsLocked
}

enum KeyboardMode: Equatable, Sendable {
    case zhuyin
    case abc
}

enum ZhuyinTone: Equatable, Sendable {
    case first
    case second
    case third
    case fourth
    case neutral

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
