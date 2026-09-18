import Foundation

enum KeyboardLayout {
    static let letterRows: [[KeyboardKey]] = [
        Array("qwertyuiop").map(KeyboardKey.letter),
        Array("asdfghjkl").map(KeyboardKey.letter),
        Array("zxcvbnm").map(KeyboardKey.letter)
    ]

    static let controlRow: [KeyboardKey] = [
        .shift, .nextKeyboard, .space, .delete, .return
    ]
}
