import XCTest

final class KeyboardEngineTests: XCTestCase {
    func testQWERTYLayout() {
        XCTAssertEqual(KeyboardLayout.letterRows.map(letters), ["qwertyuiop", "asdfghjkl", "zxcvbnm"])
        XCTAssertEqual(KeyboardLayout.thirdRow, [.shift] + KeyboardLayout.letterRows[2] + [.delete])
        XCTAssertEqual(KeyboardLayout.controlRow, [.nextKeyboard, .space, .return])
    }

    func testSingleShiftAppliesToOneLetter() {
        var engine = KeyboardEngine(mode: .abc)
        XCTAssertEqual(engine.update(for: .shift, at: 1), .none)
        XCTAssertEqual(engine.letterCase, .shifted)
        XCTAssertEqual(engine.update(for: .letter("a"), at: 1.1), KeyboardUpdate(documentEffects: [.insertText("A")]))
        XCTAssertEqual(engine.letterCase, .lowercase)
        XCTAssertEqual(engine.update(for: .letter("b"), at: 1.2), KeyboardUpdate(documentEffects: [.insertText("b")]))
    }

    func testDoubleShiftEnablesAndDisablesCapsLock() {
        var engine = KeyboardEngine(mode: .abc)
        _ = engine.update(for: .shift, at: 1)
        _ = engine.update(for: .shift, at: 1.2)
        XCTAssertEqual(engine.letterCase, .capsLocked)
        XCTAssertEqual(engine.update(for: .letter("a"), at: 1.3), KeyboardUpdate(documentEffects: [.insertText("A")]))
        XCTAssertEqual(engine.letterCase, .capsLocked)
        _ = engine.update(for: .shift, at: 2)
        XCTAssertEqual(engine.letterCase, .lowercase)
    }

    func testControlKeyCommands() {
        var engine = KeyboardEngine(mode: .abc)
        XCTAssertEqual(engine.update(for: .space), KeyboardUpdate(documentEffects: [.insertText(" ")]))
        XCTAssertEqual(engine.update(for: .return), KeyboardUpdate(documentEffects: [.insertText("\n")]))
        XCTAssertEqual(engine.update(for: .delete), KeyboardUpdate(documentEffects: [.deleteBackward]))
        XCTAssertEqual(engine.update(for: .nextKeyboard), KeyboardUpdate(documentEffects: [.showInputModeList]))
    }

    func testCursorKeysMoveWithoutComposition() {
        var engine = KeyboardEngine()
        XCTAssertEqual(
            engine.update(for: .cursorLeft),
            KeyboardUpdate(documentEffects: [.moveCursor(by: -1)])
        )
        XCTAssertEqual(
            engine.update(for: .cursorRight),
            KeyboardUpdate(documentEffects: [.moveCursor(by: 1)])
        )
    }

    func testCursorKeyMovesWithinMarkedText() {
        var engine = KeyboardEngine()
        _ = engine.update(for: .zhuyin("ㄓ"))
        XCTAssertEqual(
            engine.update(for: .cursorLeft),
            KeyboardUpdate(
                documentEffects: [.setMarkedText("ㄓ", caret: 0)],
                invalidatesCandidates: true
            )
        )
        XCTAssertTrue(engine.hasMarkedText)
        XCTAssertEqual(engine.update(for: .cursorLeft), .none)
    }

    func testAllZhuyinFlickMappings() {
        let expected = [
            ["ㄅ", "ㄆ", "ㄇ", "ㄈ"], ["ㄉ", "ㄊ", "ㄋ", "ㄌ"],
            ["ㄍ", "ㄎ", "ㄏ"], ["ㄐ", "ㄑ", "ㄒ"],
            ["ㄓ", "ㄔ", "ㄕ", "ㄖ"], ["ㄗ", "ㄘ", "ㄙ"],
            ["ㄧ", "ㄨ", "ㄩ", "ㄦ"], ["ㄚ", "ㄛ", "ㄜ", "ㄝ"],
            ["ㄞ", "ㄟ", "ㄠ", "ㄡ"]
        ]
        let directions = FlickDirection.allCases
        for (mapping, symbols) in zip(ZhuyinLayout.groups, expected) {
            XCTAssertEqual(directions.compactMap { mapping[$0] }, symbols)
        }
        XCTAssertEqual(
            directions.compactMap { ZhuyinLayout.nasalFinals[$0] },
            ["ㄢ", "ㄣ", "ㄤ", "ㄥ"]
        )
        XCTAssertNil(ZhuyinLayout.groups[0][.down])
        XCTAssertNil(ZhuyinLayout.groups[5][.right])
    }

    func testFlickDirectionResolution() {
        XCTAssertEqual(FlickGestureResolver.direction(deltaX: 5, deltaY: 5), .center)
        XCTAssertEqual(FlickGestureResolver.direction(deltaX: -30, deltaY: 2), .left)
        XCTAssertEqual(FlickGestureResolver.direction(deltaX: 2, deltaY: -30), .up)
        XCTAssertEqual(FlickGestureResolver.direction(deltaX: 30, deltaY: 2), .right)
        XCTAssertEqual(FlickGestureResolver.direction(deltaX: 2, deltaY: 30), .down)
    }

    func testToneFlickExcludesNeutralTone() {
        XCTAssertEqual(ZhuyinLayout.tones[.center], "ˉ")
        XCTAssertEqual(ZhuyinLayout.tones[.left], "ˊ")
        XCTAssertEqual(ZhuyinLayout.tones[.up], "ˇ")
        XCTAssertEqual(ZhuyinLayout.tones[.right], "ˋ")
        XCTAssertNil(ZhuyinLayout.tones[.down])
        XCTAssertNil(ZhuyinLayout.tone(for: .down))
    }

    func testPunctuationFlickMapping() {
        XCTAssertEqual(ZhuyinLayout.punctuation[.center], "，")
        XCTAssertEqual(ZhuyinLayout.punctuation[.left], "。")
        XCTAssertEqual(ZhuyinLayout.punctuation[.up], "？")
        XCTAssertEqual(ZhuyinLayout.punctuation[.right], "！")
        XCTAssertNil(ZhuyinLayout.punctuation[.down])
    }

    func testZhuyinInputMarksTextAndRequestsCandidates() {
        var engine = KeyboardEngine()
        XCTAssertEqual(
            engine.update(for: .zhuyin("ㄓ")),
            KeyboardUpdate(
                documentEffects: [.setMarkedText("ㄓ", caret: 1)],
                candidateRequest: CandidateRequest(tokens: [.symbol("ㄓ")])
            )
        )
        XCTAssertEqual(
            engine.update(for: .tone(.fourth)),
            KeyboardUpdate(
                documentEffects: [.setMarkedText("ㄓˋ", caret: 2)],
                candidateRequest: CandidateRequest(tokens: [.symbol("ㄓ"), .tone(.fourth)])
            )
        )
        XCTAssertEqual(engine.markedText, "ㄓˋ")
    }

    func testFirstToneIsVisibleAndToneCanBeReplaced() {
        var engine = KeyboardEngine()
        _ = engine.update(for: .zhuyin("ㄇ"))
        _ = engine.update(for: .tone(.first))
        XCTAssertEqual(engine.activeTokenText, "ㄇˉ")
        _ = engine.update(for: .tone(.second))
        XCTAssertEqual(engine.activeTokenText, "ㄇˊ")
    }

    func testToneStaysInPlaceWhenMoreZhuyinIsEntered() {
        var engine = KeyboardEngine()
        for key in [
            KeyboardKey.zhuyin("ㄓ"), .zhuyin("ㄨ"), .tone(.fourth),
            .zhuyin("ㄧ"), .zhuyin("ㄣ"), .tone(.first)
        ] {
            XCTAssertEqual(
                engine.update(for: key).documentEffects,
                [.setMarkedText(engine.markedText, caret: engine.composition.caretOffset)]
            )
        }
        XCTAssertEqual(engine.markedText, "ㄓㄨˋㄧㄣˉ")
    }

    func testToneOnlyReplacesImmediatelyPreviousTone() {
        var engine = KeyboardEngine()
        _ = engine.update(for: .zhuyin("ㄅ"))
        _ = engine.update(for: .tone(.second))
        _ = engine.update(for: .zhuyin("ㄆ"))
        _ = engine.update(for: .tone(.third))
        XCTAssertEqual(engine.activeTokenText, "ㄅˊㄆˇ")
        _ = engine.update(for: .tone(.fourth))
        XCTAssertEqual(engine.activeTokenText, "ㄅˊㄆˋ")
    }

    func testToneWithoutPendingIsIgnored() {
        var engine = KeyboardEngine()
        XCTAssertEqual(engine.update(for: .tone(.fourth)), .none)
        XCTAssertTrue(engine.composition.isEmpty)
    }

    func testZhuyinDeleteRemovesToneThenSymbolsThenDocumentText() {
        var engine = KeyboardEngine()
        _ = engine.update(for: .zhuyin("ㄓ"))
        _ = engine.update(for: .zhuyin("ㄨ"))
        _ = engine.update(for: .tone(.fourth))
        let toneDelete = engine.update(for: .delete)
        XCTAssertEqual(toneDelete.documentEffects, [.setMarkedText("ㄓㄨ", caret: 2)])
        XCTAssertEqual(toneDelete.candidateRequest?.tokens, [.symbol("ㄓ"), .symbol("ㄨ")])
        XCTAssertEqual(engine.activeTokenText, "ㄓㄨ")
        _ = engine.update(for: .delete)
        XCTAssertEqual(engine.activeTokenText, "ㄓ")
        let finalDelete = engine.update(for: .delete)
        XCTAssertEqual(finalDelete.documentEffects, [.setMarkedText("", caret: 0), .unmarkText])
        XCTAssertTrue(finalDelete.invalidatesCandidates)
        XCTAssertTrue(engine.composition.isEmpty)
        XCTAssertEqual(engine.update(for: .delete), KeyboardUpdate(documentEffects: [.deleteBackward]))
    }

    func testModeSwitchAndReturnCommitPendingComposition() {
        var switchEngine = KeyboardEngine()
        _ = switchEngine.update(for: .zhuyin("ㄅ"))
        let switchUpdate = switchEngine.update(for: .modeSwitch)
        XCTAssertEqual(switchUpdate.documentEffects, [.unmarkText])
        XCTAssertTrue(switchUpdate.invalidatesCandidates)
        XCTAssertEqual(switchEngine.mode, .abc)
        XCTAssertTrue(switchEngine.composition.isEmpty)

        var returnEngine = KeyboardEngine()
        _ = returnEngine.update(for: .zhuyin("ㄆ"))
        let returnUpdate = returnEngine.update(for: .return)
        XCTAssertEqual(returnUpdate.documentEffects, [.insertText("ㄆ")])
        XCTAssertTrue(returnUpdate.invalidatesCandidates)
        XCTAssertTrue(returnEngine.composition.isEmpty)
    }

    func testModeSwitchFromABCProducesNoEffects() {
        var engine = KeyboardEngine(mode: .abc)
        XCTAssertEqual(engine.update(for: .modeSwitch), .none)
        XCTAssertEqual(engine.mode, .zhuyin)
    }

    func testNumberLayout() {
        XCTAssertEqual(NumberLayout.rows, [Array("123"), Array("456"), Array("789")])
        XCTAssertEqual(NumberLayout.zero, "0")
    }

    func testNumberModeInsertsDigits() {
        var engine = KeyboardEngine(mode: .number)
        XCTAssertEqual(
            engine.update(for: .digit("5")),
            KeyboardUpdate(documentEffects: [.insertText("5")])
        )
        XCTAssertEqual(
            engine.update(for: .digit("0")),
            KeyboardUpdate(documentEffects: [.insertText("0")])
        )
        XCTAssertTrue(engine.composition.isEmpty)
    }

    func testDigitIsIgnoredOutsideNumberMode() {
        var zhuyinEngine = KeyboardEngine()
        XCTAssertEqual(zhuyinEngine.update(for: .digit("1")), .none)
        var abcEngine = KeyboardEngine(mode: .abc)
        XCTAssertEqual(abcEngine.update(for: .digit("1")), .none)
    }

    func testZhuyinToNumberSwitchCommitsComposition() {
        var engine = KeyboardEngine()
        _ = engine.update(for: .zhuyin("ㄅ"))
        let update = engine.update(for: .numberSwitch)
        XCTAssertEqual(update.documentEffects, [.unmarkText])
        XCTAssertTrue(update.invalidatesCandidates)
        XCTAssertEqual(engine.mode, .number)
        XCTAssertTrue(engine.composition.isEmpty)
    }

    func testNumberToZhuyinSwitchProducesNoEffects() {
        var engine = KeyboardEngine(mode: .number)
        XCTAssertEqual(engine.update(for: .numberSwitch), .none)
        XCTAssertEqual(engine.mode, .zhuyin)
    }

    func testNumberSwitchFromABCProducesNoEffects() {
        var engine = KeyboardEngine(mode: .abc)
        XCTAssertEqual(engine.update(for: .numberSwitch), .none)
        XCTAssertEqual(engine.mode, .abc)
    }

    func testModeSwitchFromNumberGoesToABC() {
        var engine = KeyboardEngine(mode: .number)
        XCTAssertEqual(engine.update(for: .modeSwitch), .none)
        XCTAssertEqual(engine.mode, .abc)
    }

    func testNumberModeControlKeys() {
        var engine = KeyboardEngine(mode: .number)
        XCTAssertEqual(engine.update(for: .space), KeyboardUpdate(documentEffects: [.insertText(" ")]))
        XCTAssertEqual(engine.update(for: .return), KeyboardUpdate(documentEffects: [.insertText("\n")]))
        XCTAssertEqual(engine.update(for: .delete), KeyboardUpdate(documentEffects: [.deleteBackward]))
        XCTAssertEqual(engine.update(for: .nextKeyboard), KeyboardUpdate(documentEffects: [.showInputModeList]))
    }

    private func letters(in row: [KeyboardKey]) -> String {
        String(row.compactMap { key in
            guard case let .letter(character) = key else { return nil }
            return character
        })
    }
}
