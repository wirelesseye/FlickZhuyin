import XCTest

final class KeyboardEngineTests: XCTestCase {
    func testQWERTYLayout() {
        XCTAssertEqual(KeyboardLayout.letterRows.map(letters), ["qwertyuiop", "asdfghjkl", "zxcvbnm"])
        XCTAssertEqual(KeyboardLayout.controlRow, [.shift, .nextKeyboard, .space, .delete, .return])
    }

    func testSingleShiftAppliesToOneLetter() {
        var engine = KeyboardEngine()
        XCTAssertEqual(engine.command(for: .shift, at: 1), .none)
        XCTAssertEqual(engine.letterCase, .shifted)
        XCTAssertEqual(engine.command(for: .letter("a"), at: 1.1), .insertText("A"))
        XCTAssertEqual(engine.letterCase, .lowercase)
        XCTAssertEqual(engine.command(for: .letter("b"), at: 1.2), .insertText("b"))
    }

    func testDoubleShiftEnablesAndDisablesCapsLock() {
        var engine = KeyboardEngine()
        _ = engine.command(for: .shift, at: 1)
        _ = engine.command(for: .shift, at: 1.2)
        XCTAssertEqual(engine.letterCase, .capsLocked)
        XCTAssertEqual(engine.command(for: .letter("a"), at: 1.3), .insertText("A"))
        XCTAssertEqual(engine.letterCase, .capsLocked)
        _ = engine.command(for: .shift, at: 2)
        XCTAssertEqual(engine.letterCase, .lowercase)
    }

    func testControlKeyCommands() {
        var engine = KeyboardEngine()
        XCTAssertEqual(engine.command(for: .space), .insertText(" "))
        XCTAssertEqual(engine.command(for: .return), .insertText("\n"))
        XCTAssertEqual(engine.command(for: .delete), .deleteBackward)
        XCTAssertEqual(engine.command(for: .nextKeyboard), .showInputModeList)
    }

    private func letters(in row: [KeyboardKey]) -> String {
        String(row.compactMap { key in
            guard case let .letter(character) = key else { return nil }
            return character
        })
    }
}
