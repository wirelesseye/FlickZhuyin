import Foundation

enum KeyboardKey: Equatable, Sendable {
    case letter(Character)
    case zhuyin(Character)
    case digit(Character)
    case tone(MandarinTone)
    case shift
    case delete
    case cursorLeft
    case cursorRight
    case space
    case `return`
    case nextKeyboard
    case modeSwitch
    case numberSwitch
}

enum DocumentEffect: Equatable, Sendable {
    case setMarkedText(String, caret: Int)
    case unmarkText
    case insertText(String)
    case deleteBackward
    case moveCursor(by: Int)
    case showInputModeList
}

struct CandidateRequest: Equatable, Sendable {
    let tokens: [ZhuyinInputToken]
    /// Selected text immediately before `tokens`, for grammar context.
    var precedingText = ""
    /// Whether the document text before the composition also precedes `tokens`.
    var continuesDocument = true
}

struct KeyboardUpdate: Equatable, Sendable {
    var documentEffects: [DocumentEffect] = []
    var candidateRequest: CandidateRequest?
    var invalidatesCandidates: Bool = false

    static let none = KeyboardUpdate()
}

enum LetterCaseState: Equatable, Sendable {
    case lowercase
    case shifted
    case capsLocked
}

enum KeyboardMode: Equatable, Sendable {
    case zhuyin
    case number
    case abc
}
