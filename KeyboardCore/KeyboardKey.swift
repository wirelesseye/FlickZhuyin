import Foundation

enum KeyboardKey: Equatable, Sendable {
    case letter(Character)
    case shift
    case delete
    case space
    case `return`
    case nextKeyboard
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
