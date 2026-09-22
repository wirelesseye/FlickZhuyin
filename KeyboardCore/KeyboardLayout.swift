import Foundation

enum KeyboardLayout {
    static let letterRows: [[KeyboardKey]] = [
        Array("qwertyuiop").map(KeyboardKey.letter),
        Array("asdfghjkl").map(KeyboardKey.letter),
        Array("zxcvbnm").map(KeyboardKey.letter)
    ]

    static var thirdRow: [KeyboardKey] {
        [.shift] + letterRows[2] + [.delete]
    }

    static let controlRow: [KeyboardKey] = [
        .nextKeyboard, .space, .return
    ]
}

enum NumberLayout {
    static let rows: [[Character]] = [
        Array("123"),
        Array("456"),
        Array("789")
    ]

    static let zero: Character = "0"
}
