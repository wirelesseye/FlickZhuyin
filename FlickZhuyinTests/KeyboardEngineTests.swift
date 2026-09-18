import XCTest

final class KeyboardEngineTests: XCTestCase {
    func testQWERTYLayout() {
        XCTAssertEqual(KeyboardLayout.letterRows.map(letters), ["qwertyuiop", "asdfghjkl", "zxcvbnm"])
        XCTAssertEqual(KeyboardLayout.thirdRow, [.shift] + KeyboardLayout.letterRows[2] + [.delete])
        XCTAssertEqual(KeyboardLayout.controlRow, [.nextKeyboard, .space, .return])
    }

    func testSingleShiftAppliesToOneLetter() {
        var engine = KeyboardEngine(mode: .abc)
        XCTAssertEqual(engine.command(for: .shift, at: 1), .none)
        XCTAssertEqual(engine.letterCase, .shifted)
        XCTAssertEqual(engine.command(for: .letter("a"), at: 1.1), .insertText("A"))
        XCTAssertEqual(engine.letterCase, .lowercase)
        XCTAssertEqual(engine.command(for: .letter("b"), at: 1.2), .insertText("b"))
    }

    func testDoubleShiftEnablesAndDisablesCapsLock() {
        var engine = KeyboardEngine(mode: .abc)
        _ = engine.command(for: .shift, at: 1)
        _ = engine.command(for: .shift, at: 1.2)
        XCTAssertEqual(engine.letterCase, .capsLocked)
        XCTAssertEqual(engine.command(for: .letter("a"), at: 1.3), .insertText("A"))
        XCTAssertEqual(engine.letterCase, .capsLocked)
        _ = engine.command(for: .shift, at: 2)
        XCTAssertEqual(engine.letterCase, .lowercase)
    }

    func testControlKeyCommands() {
        var engine = KeyboardEngine(mode: .abc)
        XCTAssertEqual(engine.command(for: .space), .insertText(" "))
        XCTAssertEqual(engine.command(for: .return), .insertText("\n"))
        XCTAssertEqual(engine.command(for: .delete), .deleteBackward)
        XCTAssertEqual(engine.command(for: .nextKeyboard), .showInputModeList)
    }

    func testAllZhuyinFlickMappings() {
        let expected = [
            ["ㄅ", "ㄆ", "ㄇ", "ㄈ"], ["ㄉ", "ㄊ", "ㄋ", "ㄌ"],
            ["ㄍ", "ㄎ", "ㄏ", "ㄐ", "ㄑ"], ["ㄓ", "ㄔ", "ㄕ", "ㄖ", "ㄒ"],
            ["ㄗ", "ㄘ", "ㄙ"], ["ㄧ", "ㄨ", "ㄩ", "ㄦ"],
            ["ㄚ", "ㄛ", "ㄜ", "ㄝ"], ["ㄞ", "ㄟ", "ㄠ", "ㄡ"],
            ["ㄢ", "ㄣ", "ㄤ", "ㄥ"]
        ]
        let directions = FlickDirection.allCases
        for (mapping, symbols) in zip(ZhuyinLayout.groups, expected) {
            XCTAssertEqual(directions.compactMap { mapping[$0] }, symbols)
        }
        XCTAssertNil(ZhuyinLayout.groups[0][.down])
        XCTAssertNil(ZhuyinLayout.groups[4][.right])
    }

    func testFlickDirectionResolution() {
        XCTAssertEqual(FlickGestureResolver.direction(deltaX: 5, deltaY: 5), .center)
        XCTAssertEqual(FlickGestureResolver.direction(deltaX: -30, deltaY: 2), .left)
        XCTAssertEqual(FlickGestureResolver.direction(deltaX: 2, deltaY: -30), .up)
        XCTAssertEqual(FlickGestureResolver.direction(deltaX: 30, deltaY: 2), .right)
        XCTAssertEqual(FlickGestureResolver.direction(deltaX: 2, deltaY: 30), .down)
    }

    func testZhuyinCandidateWaitsForExplicitCommit() {
        var engine = KeyboardEngine()
        XCTAssertEqual(engine.command(for: .zhuyin("ㄓ")), .none)
        XCTAssertEqual(engine.command(for: .zhuyin("ㄨ")), .none)
        XCTAssertEqual(engine.command(for: .tone(.fourth)), .none)
        XCTAssertEqual(engine.candidate, "ㄓㄨˋ")
        XCTAssertEqual(engine.command(for: .commitCandidate), .insertText("ㄓㄨˋ"))
        XCTAssertNil(engine.candidate)
    }

    func testFirstToneIsVisibleAndToneCanBeReplaced() {
        var engine = KeyboardEngine()
        _ = engine.command(for: .zhuyin("ㄇ"))
        _ = engine.command(for: .tone(.first))
        XCTAssertEqual(engine.candidate, "ㄇˉ")
        _ = engine.command(for: .tone(.second))
        XCTAssertEqual(engine.candidate, "ㄇˊ")
    }

    func testZhuyinDeleteRemovesToneThenSymbolsThenDocumentText() {
        var engine = KeyboardEngine()
        _ = engine.command(for: .zhuyin("ㄓ"))
        _ = engine.command(for: .zhuyin("ㄨ"))
        _ = engine.command(for: .tone(.fourth))
        XCTAssertEqual(engine.command(for: .delete), .none)
        XCTAssertEqual(engine.candidate, "ㄓㄨ")
        XCTAssertEqual(engine.command(for: .delete), .none)
        XCTAssertEqual(engine.candidate, "ㄓ")
        XCTAssertEqual(engine.command(for: .delete), .none)
        XCTAssertNil(engine.candidate)
        XCTAssertEqual(engine.command(for: .delete), .deleteBackward)
    }

    func testModeSwitchAndReturnCommitPendingCandidate() {
        var switchEngine = KeyboardEngine()
        _ = switchEngine.command(for: .zhuyin("ㄅ"))
        XCTAssertEqual(switchEngine.command(for: .modeSwitch), .insertText("ㄅ"))
        XCTAssertEqual(switchEngine.mode, .abc)

        var returnEngine = KeyboardEngine()
        _ = returnEngine.command(for: .zhuyin("ㄆ"))
        XCTAssertEqual(returnEngine.command(for: .return), .insertText("ㄆ\n"))
        XCTAssertNil(returnEngine.candidate)
    }

    private func letters(in row: [KeyboardKey]) -> String {
        String(row.compactMap { key in
            guard case let .letter(character) = key else { return nil }
            return character
        })
    }
}
