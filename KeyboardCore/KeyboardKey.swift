import Foundation

enum KeyboardKey: Equatable, Sendable {
    case letter(Character)
    case zhuyin(Character)
    case tone(MandarinTone)
    case shift
    case delete
    case space
    case `return`
    case nextKeyboard
    case modeSwitch
}

enum DocumentEffect: Equatable, Sendable {
    case setMarkedText(String)
    case unmarkText
    case insertText(String)
    case deleteBackward
    case showInputModeList
}

struct CandidateRequest: Equatable, Sendable {
    let tokens: [ZhuyinInputToken]
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
    case abc
}
