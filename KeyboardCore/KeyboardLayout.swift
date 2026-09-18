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
