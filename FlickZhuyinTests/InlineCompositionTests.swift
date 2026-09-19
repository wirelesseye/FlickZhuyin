import XCTest

private let zhuyinConstraint = SyllableConstraint(base: "ㄓㄨ", tone: .fourth)

private func makeCandidate(
    _ text: String,
    base: String = "ㄓㄨ",
    tone: MandarinTone = .fourth,
    isRawFallback: Bool = false
) -> InputCandidate {
    let constraint = SyllableConstraint(base: base, tone: tone)
    return InputCandidate(
        id: CandidateID(text: text, pronunciation: [constraint], tokenRange: 0..<2),
        text: text,
        pronunciation: [constraint],
        score: 1,
        isRawFallback: isRawFallback
    )
}

final class ZhuyinCompositionTests: XCTestCase {
    func testMarkedTextCombinesSelectedChunksAndPendingTokens() {
        let chunk = SelectedChunk(
            text: "注",
            sourceTokens: [.symbol("ㄓ"), .symbol("ㄨ"), .tone(.fourth)],
            pronunciation: [zhuyinConstraint]
        )
        var composition = ZhuyinComposition(pieces: [.selected(chunk)], caretIndex: 1)
        XCTAssertEqual(composition.markedText, "注")
        XCTAssertEqual(composition.activeTokenText, "")
        XCTAssertFalse(composition.isEmpty)

        composition.pieces.append(contentsOf: [
            .token(.symbol("ㄧ")), .token(.symbol("ㄣ")), .token(.tone(.first))
        ])
        composition.caretIndex = composition.pieces.count
        XCTAssertEqual(composition.activeTokenText, "ㄧㄣˉ")
        XCTAssertEqual(composition.markedText, "注ㄧㄣˉ")
    }

    func testEmptyCompositionIsEmpty() {
        let composition = ZhuyinComposition()
        XCTAssertTrue(composition.isEmpty)
        XCTAssertEqual(composition.markedText, "")
    }

    func testCaretOffsetCountsUTF16Units() {
        let chunk = SelectedChunk(
            text: "𠀀",
            sourceTokens: [.symbol("ㄓ")],
            pronunciation: [zhuyinConstraint]
        )
        let composition = ZhuyinComposition(
            pieces: [.selected(chunk), .token(.symbol("ㄓ"))],
            caretIndex: 2
        )
        XCTAssertEqual(composition.caretOffset, 3)
    }

    func testTokenDisplayText() {
        XCTAssertEqual(ZhuyinInputToken.symbol("ㄓ").displayText, "ㄓ")
        XCTAssertEqual(ZhuyinInputToken.tone(.neutral).displayText, "˙")
        XCTAssertEqual(ZhuyinInputToken.tone(.first).displayText, "ˉ")
    }
}

final class KeyboardCompositionTests: XCTestCase {
    private func selectZhuyin(_ engine: inout KeyboardEngine) {
        _ = engine.update(for: .zhuyin("ㄓ"))
        _ = engine.update(for: .zhuyin("ㄨ"))
        _ = engine.update(for: .tone(.fourth))
        _ = engine.selectCandidate(makeCandidate("注"))
    }

    func testSelectingCandidateKeepsCompositionMarked() {
        var engine = KeyboardEngine()
        _ = engine.update(for: .zhuyin("ㄓ"))
        let update = engine.selectCandidate(makeCandidate("注"))
        XCTAssertEqual(update.documentEffects, [.setMarkedText("注", caret: 1)])
        XCTAssertTrue(update.invalidatesCandidates)
        XCTAssertNil(update.candidateRequest)
        XCTAssertEqual(engine.composition.selectedChunks.map(\.text), ["注"])
        XCTAssertTrue(engine.composition.activeTokens.isEmpty)
        XCTAssertFalse(engine.hasActiveTokens)
    }

    func testSelectedChunkKeepsSourceTokens() {
        var engine = KeyboardEngine()
        selectZhuyin(&engine)
        XCTAssertEqual(
            engine.composition.selectedChunks.first?.sourceTokens,
            [.symbol("ㄓ"), .symbol("ㄨ"), .tone(.fourth)]
        )
        XCTAssertEqual(engine.composition.selectedChunks.first?.pronunciation, [zhuyinConstraint])
    }

    func testContinueTypingAfterSelection() {
        var engine = KeyboardEngine()
        selectZhuyin(&engine)
        for key in [KeyboardKey.zhuyin("ㄧ"), .zhuyin("ㄣ"), .tone(.first)] {
            _ = engine.update(for: key)
        }
        XCTAssertEqual(engine.markedText, "注ㄧㄣˉ")
        _ = engine.selectCandidate(makeCandidate("音", base: "ㄧㄣ", tone: .first))
        XCTAssertEqual(engine.markedText, "注音")
        XCTAssertEqual(engine.composition.selectedChunks.count, 2)
        XCTAssertTrue(engine.composition.activeTokens.isEmpty)
    }

    func testDeleteUndoesSelectedChunkAndRestoresTokens() {
        var engine = KeyboardEngine()
        selectZhuyin(&engine)
        let undo = engine.update(for: .delete)
        XCTAssertEqual(undo.documentEffects, [.setMarkedText("ㄓㄨˋ", caret: 3)])
        XCTAssertEqual(
            undo.candidateRequest?.tokens,
            [.symbol("ㄓ"), .symbol("ㄨ"), .tone(.fourth)]
        )
        XCTAssertFalse(undo.invalidatesCandidates)
        XCTAssertTrue(engine.composition.selectedChunks.isEmpty)
        XCTAssertEqual(engine.activeTokenText, "ㄓㄨˋ")
    }

    func testDeleteUndoesInitialAbbreviationCandidateAndRestoresTokens() {
        var engine = KeyboardEngine()
        _ = engine.update(for: .zhuyin("ㄅ"))
        _ = engine.update(for: .zhuyin("ㄅ"))
        let baba = InputCandidate(
            id: CandidateID(
                text: "爸爸",
                pronunciation: [
                    SyllableConstraint(base: "ㄅㄚ", tone: .fourth),
                    SyllableConstraint(base: "ㄅㄚ", tone: .neutral),
                ],
                tokenRange: 0..<2
            ),
            text: "爸爸",
            pronunciation: [
                SyllableConstraint(base: "ㄅㄚ", tone: .fourth),
                SyllableConstraint(base: "ㄅㄚ", tone: .neutral),
            ],
            score: 1,
            isRawFallback: false
        )
        let selection = engine.selectCandidate(baba)
        XCTAssertEqual(selection.documentEffects, [.setMarkedText("爸爸", caret: 2)])
        XCTAssertEqual(
            engine.composition.selectedChunks.first?.sourceTokens,
            [.symbol("ㄅ"), .symbol("ㄅ")]
        )

        let undo = engine.update(for: .delete)
        XCTAssertEqual(undo.documentEffects, [.setMarkedText("ㄅㄅ", caret: 2)])
        XCTAssertEqual(undo.candidateRequest?.tokens, [.symbol("ㄅ"), .symbol("ㄅ")])
        XCTAssertEqual(engine.activeTokenText, "ㄅㄅ")
        XCTAssertTrue(engine.composition.selectedChunks.isEmpty)
    }

    func testDeletingLastPendingTokenEndsMarkedText() {
        var engine = KeyboardEngine()
        _ = engine.update(for: .zhuyin("ㄓ"))

        let update = engine.update(for: .delete)

        XCTAssertEqual(update.documentEffects, [.setMarkedText("", caret: 0), .unmarkText])
        XCTAssertTrue(update.invalidatesCandidates)
        XCTAssertNil(update.candidateRequest)
        XCTAssertTrue(engine.composition.isEmpty)
    }

    func testDeletingPendingTokenKeepsSelectedTextMarked() {
        var engine = KeyboardEngine()
        selectZhuyin(&engine)
        _ = engine.update(for: .zhuyin("ㄧ"))

        let update = engine.update(for: .delete)

        XCTAssertEqual(update.documentEffects, [.setMarkedText("注", caret: 1)])
        XCTAssertTrue(update.invalidatesCandidates)
        XCTAssertNil(update.candidateRequest)
        XCTAssertEqual(engine.markedText, "注")
    }

    func testSpaceDoesNotCommitComposition() {
        var engine = KeyboardEngine()
        selectZhuyin(&engine)
        let update = engine.update(for: .space)
        XCTAssertEqual(update, .none)
        XCTAssertFalse(engine.composition.isEmpty)
    }

    func testReturnCommitsPendingRawZhuyin() {
        var engine = KeyboardEngine()
        _ = engine.update(for: .zhuyin("ㄓ"))
        let update = engine.update(for: .return)
        XCTAssertEqual(update.documentEffects, [.insertText("ㄓ")])
        XCTAssertTrue(update.invalidatesCandidates)
        XCTAssertTrue(engine.composition.isEmpty)
    }

    func testNextKeyboardCommitsBeforeShowingInputModeList() {
        var engine = KeyboardEngine()
        _ = engine.update(for: .zhuyin("ㄓ"))
        let update = engine.update(for: .nextKeyboard)
        XCTAssertEqual(update.documentEffects, [.unmarkText, .showInputModeList])
        XCTAssertTrue(update.invalidatesCandidates)
        XCTAssertTrue(engine.composition.isEmpty)
    }

    func testResetCompositionClearsWithoutDocumentEffects() {
        var engine = KeyboardEngine()
        _ = engine.update(for: .zhuyin("ㄓ"))
        let update = engine.resetComposition()
        XCTAssertEqual(update, KeyboardUpdate(invalidatesCandidates: true))
        XCTAssertTrue(engine.composition.isEmpty)
        XCTAssertEqual(engine.resetComposition(), .none)
    }

    func testToneControlVisibilityDependsOnlyOnPendingTokens() {
        var engine = KeyboardEngine()
        _ = engine.update(for: .zhuyin("ㄓ"))
        XCTAssertTrue(engine.hasActiveTokens)
        _ = engine.selectCandidate(makeCandidate("注"))
        XCTAssertFalse(engine.hasActiveTokens)
        XCTAssertFalse(engine.composition.isEmpty)
        _ = engine.update(for: .delete)
        XCTAssertTrue(engine.hasActiveTokens)
    }

    func testCursorMovesWithinMarkedTextWithoutCommitting() {
        var engine = KeyboardEngine()
        _ = engine.update(for: .zhuyin("ㄓ"))
        _ = engine.update(for: .zhuyin("ㄨ"))
        let update = engine.update(for: .cursorLeft)
        XCTAssertEqual(update.documentEffects, [.setMarkedText("ㄓㄨ", caret: 1)])
        XCTAssertEqual(update.candidateRequest?.tokens, [.symbol("ㄓ"), .symbol("ㄨ")])
        XCTAssertEqual(engine.markedText, "ㄓㄨ")
    }

    func testCursorStopsAtMarkedTextBoundaries() {
        var engine = KeyboardEngine()
        _ = engine.update(for: .zhuyin("ㄓ"))
        _ = engine.update(for: .cursorLeft)
        XCTAssertEqual(engine.update(for: .cursorLeft), .none)
        _ = engine.update(for: .cursorRight)
        XCTAssertEqual(engine.update(for: .cursorRight), .none)
        XCTAssertEqual(engine.markedText, "ㄓ")
    }

    func testZhuyinInputInsertsAtCaret() {
        var engine = KeyboardEngine()
        _ = engine.update(for: .zhuyin("ㄓ"))
        _ = engine.update(for: .zhuyin("ㄨ"))
        _ = engine.update(for: .cursorLeft)
        _ = engine.update(for: .zhuyin("ㄅ"))
        XCTAssertEqual(engine.markedText, "ㄓㄅㄨ")
    }

    func testDeleteRemovesPieceBeforeCaret() {
        var engine = KeyboardEngine()
        _ = engine.update(for: .zhuyin("ㄓ"))
        _ = engine.update(for: .zhuyin("ㄨ"))
        _ = engine.update(for: .cursorLeft)
        let update = engine.update(for: .delete)
        XCTAssertEqual(update.documentEffects, [.setMarkedText("ㄨ", caret: 0)])
        XCTAssertEqual(engine.markedText, "ㄨ")
    }
}

final class ChineseInputPipelineTests: ChineseInputTestCase {
    private var productionDatabaseURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Generated/flickzhuyin.sqlite3")
    }

    private func tonedTokens() -> [ZhuyinInputToken] {
        [.symbol("ㄓ"), .symbol("ㄨ"), .tone(.fourth), .symbol("ㄧ"), .symbol("ㄣ"), .tone(.first)]
    }

    func testFixturePipelineFindsZhuyinWordAndRawFallback() async throws {
        let pipeline = try LexiconChineseInputPipeline(store: try makeFixtureStore())
        let candidates = try await pipeline.candidates(for: tonedTokens())
        XCTAssertTrue(candidates.contains { $0.text == "注音" && !$0.isRawFallback })
        let raw = try XCTUnwrap(candidates.first { $0.isRawFallback })
        XCTAssertEqual(raw.text, "ㄓㄨˋㄧㄣˉ")
        XCTAssertEqual(raw.pronunciation, [
            SyllableConstraint(base: "ㄓㄨ", tone: .fourth),
            SyllableConstraint(base: "ㄧㄣ", tone: .first),
        ])
        XCTAssertLessThanOrEqual(candidates.count, Decoder().configuration.maximumCandidates)
        XCTAssertEqual(Set(candidates.map(\.id)).count, candidates.count)
    }

    func testFixtureExactCandidateOutranksInitialAbbreviationCandidate() async throws {
        let pipeline = try LexiconChineseInputPipeline(store: try makeFixtureStore())
        let candidates = try await pipeline.candidates(for: [.symbol("ㄓ")])
        let exact = try XCTUnwrap(candidates.first { $0.text == "知" })
        let abbreviated = try XCTUnwrap(candidates.first { $0.text == "中" })
        XCTAssertEqual(candidates.first?.text, "知")
        XCTAssertLessThan(exact.score, abbreviated.score)
        XCTAssertTrue(candidates.contains { $0.isRawFallback && $0.text == "ㄓ" })
    }

    func testProductionPipelineProducesInitialAbbreviationCandidates() async throws {
        let pipeline = try LexiconChineseInputPipeline(
            store: try SQLiteLexiconStore(url: productionDatabaseURL)
        )
        let single = try await pipeline.candidates(for: [.symbol("ㄅ")])
        XCTAssertTrue(single.contains { $0.text == "不" && !$0.isRawFallback })
        XCTAssertTrue(single.contains { $0.isRawFallback && $0.text == "ㄅ" })
        XCTAssertEqual(single.filter { $0.text == "不" }.count, 1)

        let double = try await pipeline.candidates(for: [.symbol("ㄅ"), .symbol("ㄅ")])
        XCTAssertTrue(double.contains { $0.text == "爸爸" || $0.text == "寶寶" })
        XCTAssertTrue(double.contains { $0.isRawFallback && $0.text == "ㄅㄅ" })
        XCTAssertLessThanOrEqual(double.filter { $0.text == "爸爸" }.count, 1)
        XCTAssertLessThanOrEqual(double.filter { $0.text == "寶寶" }.count, 1)
        XCTAssertLessThanOrEqual(double.count, Decoder().configuration.maximumCandidates)
    }

    func testMixedCompleteWordAndInitialCandidateCombine() async throws {
        let pipeline = try LexiconChineseInputPipeline(
            store: try SQLiteLexiconStore(url: productionDatabaseURL)
        )
        let tokens: [ZhuyinInputToken] = [
            .symbol("ㄋ"), .symbol("ㄧ"), .tone(.third), .symbol("ㄅ"),
        ]
        let candidates = try await pipeline.candidates(for: tokens)
        XCTAssertTrue(candidates.contains { $0.text == "你不" })
        XCTAssertTrue(candidates.contains { $0.isRawFallback })
        XCTAssertLessThanOrEqual(candidates.count, Decoder().configuration.maximumCandidates)
    }

    func testProductionPipelineFindsZhuyinWithAndWithoutTones() async throws {
        let pipeline = try LexiconChineseInputPipeline(
            store: try SQLiteLexiconStore(url: productionDatabaseURL)
        )
        let inputs: [[ZhuyinInputToken]] = [
            tonedTokens(),
            [.symbol("ㄓ"), .symbol("ㄨ"), .symbol("ㄧ"), .symbol("ㄣ")],
        ]
        for tokens in inputs {
            let candidates = try await pipeline.candidates(for: tokens)
            XCTAssertTrue(candidates.contains { $0.text == "注音" })
            XCTAssertTrue(candidates.contains { $0.isRawFallback })
            XCTAssertLessThanOrEqual(candidates.count, Decoder().configuration.maximumCandidates)
        }
    }

    func testTonelessYiMergesRepeatedCandidateText() async throws {
        let pipeline = try LexiconChineseInputPipeline(
            store: try SQLiteLexiconStore(url: productionDatabaseURL)
        )
        let candidates = try await pipeline.candidates(for: [.symbol("ㄧ")])
        XCTAssertEqual(candidates.filter { $0.text == "一" }.count, 1)
        XCTAssertEqual(candidates.first?.text, "一")
    }

    func testExplicitYiTonesStillMatchYi() async throws {
        let pipeline = try LexiconChineseInputPipeline(
            store: try SQLiteLexiconStore(url: productionDatabaseURL)
        )
        for tone in [MandarinTone.first, .second, .fourth] {
            let candidates = try await pipeline.candidates(for: [.symbol("ㄧ"), .tone(tone)])
            XCTAssertTrue(candidates.contains { $0.text == "一" }, "tone \(tone)")
        }
    }

    func testTonelessYiKeepsRawFallback() async throws {
        let pipeline = try LexiconChineseInputPipeline(
            store: try SQLiteLexiconStore(url: productionDatabaseURL)
        )
        let candidates = try await pipeline.candidates(for: [.symbol("ㄧ")])
        let fallback = try XCTUnwrap(candidates.first { $0.isRawFallback })
        XCTAssertEqual(fallback.text, "ㄧ")
        XCTAssertEqual(fallback.pronunciation, [SyllableConstraint(base: "ㄧ")])
    }

    func testMergedCandidateKeepsLowestScore() async throws {
        let yi = SyllableConstraint(base: "ㄧ")
        let store = StubLexiconStore(
            inventory: ["ㄧ"],
            responses: [
                [yi]: [
                    LexiconMatch(
                        text: "一",
                        pronunciation: [CanonicalSyllable(base: "ㄧ", tone: .first)],
                        sourceWeight: 0.5
                    ),
                    LexiconMatch(
                        text: "一",
                        pronunciation: [CanonicalSyllable(base: "ㄧ", tone: .fourth)],
                        sourceWeight: 0.9
                    ),
                    LexiconMatch(
                        text: "以",
                        pronunciation: [CanonicalSyllable(base: "ㄧ", tone: .third)],
                        sourceWeight: 0.8
                    ),
                ]
            ]
        )
        let pipeline = try LexiconChineseInputPipeline(store: store)
        let candidates = try await pipeline.candidates(for: [.symbol("ㄧ")])
        let merged = candidates.filter { $0.text == "一" }
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.pronunciation, [SyllableConstraint(base: "ㄧ", tone: .fourth)])
        XCTAssertTrue(candidates.contains { $0.isRawFallback })
    }

    func testEmptyTokensReturnNoCandidatesWithoutQuerying() async throws {
        let pipeline = try LexiconChineseInputPipeline(store: FailingLexiconStore())
        let candidates = try await pipeline.candidates(for: [])
        XCTAssertTrue(candidates.isEmpty)
    }

    func testQueryRunsOffTheMainThread() async throws {
        let store = ThreadRecordingLexiconStore()
        let pipeline = try LexiconChineseInputPipeline(store: store)
        _ = try await pipeline.candidates(for: [.symbol("ㄓ")])
        XCTAssertFalse(store.queriedOnMainThread)
    }

    func testPipelinePropagatesQueryFailures() async throws {
        let pipeline = try LexiconChineseInputPipeline(store: FailingLexiconStore())
        do {
            _ = try await pipeline.candidates(for: [.symbol("ㄓ")])
            XCTFail("expected query failure")
        } catch let error as LexiconStoreError {
            guard case .queryFailed = error else {
                return XCTFail("unexpected lexicon error \(error)")
            }
        }
    }
}

private final class FailingLexiconStore: LexiconStore, @unchecked Sendable {
    func exactMatches(for syllables: [SyllableConstraint]) throws -> [LexiconMatch] {
        throw LexiconStoreError.queryFailed("unexpected query")
    }

    func initialMatches(for initials: [Character], limit: Int) throws -> [LexiconMatch] {
        throw LexiconStoreError.queryFailed("unexpected initial query")
    }

    func syllableInventory() throws -> [String] {
        ["ㄓ"]
    }
}

private final class ThreadRecordingLexiconStore: LexiconStore, @unchecked Sendable {
    private let lock = NSLock()
    private var mainThreadQuery = false

    var queriedOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mainThreadQuery
    }

    func exactMatches(for syllables: [SyllableConstraint]) throws -> [LexiconMatch] {
        lock.lock()
        mainThreadQuery = Thread.isMainThread
        lock.unlock()
        return []
    }

    func initialMatches(for initials: [Character], limit: Int) throws -> [LexiconMatch] {
        lock.lock()
        mainThreadQuery = Thread.isMainThread
        lock.unlock()
        return []
    }

    func syllableInventory() throws -> [String] {
        ["ㄓ"]
    }
}

private actor ControlledPipeline: ChineseInputPipeline {
    private var continuations: [CheckedContinuation<[InputCandidate], Error>] = []
    private var requested: [[ZhuyinInputToken]] = []

    func candidates(for tokens: [ZhuyinInputToken]) async throws -> [InputCandidate] {
        requested.append(tokens)
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func requestedCount() -> Int {
        requested.count
    }

    func resolveNext(with candidates: [InputCandidate]) {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(returning: candidates)
    }

    func failNext(with error: Error) {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(throwing: error)
    }
}

@MainActor
final class ChineseInputCoordinatorTests: XCTestCase {
    func testStaleResultDoesNotOverrideNewerRequest() async {
        let pipeline = ControlledPipeline()
        let coordinator = ChineseInputCoordinator { pipeline }
        let first: [ZhuyinInputToken] = [.symbol("ㄓ")]
        let second: [ZhuyinInputToken] = [.symbol("ㄓ"), .symbol("ㄨ")]
        coordinator.requestCandidates(for: first)
        coordinator.requestCandidates(for: second)
        await waitUntil { await pipeline.requestedCount() == 2 }
        XCTAssertEqual(coordinator.state, .loading)
        XCTAssertEqual(coordinator.candidates.map(\.text), ["ㄓㄨ"])
        XCTAssertTrue(coordinator.candidates.allSatisfy(\.isRawFallback))

        await pipeline.resolveNext(with: [makeCandidate("舊")])
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(coordinator.state, .loading)
        XCTAssertEqual(coordinator.candidates.map(\.text), ["ㄓㄨ"])

        await pipeline.resolveNext(with: [makeCandidate("新")])
        await waitUntil { coordinator.state == .ready }
        XCTAssertEqual(coordinator.candidates.map(\.text), ["新"])
    }

    func testInvalidateDropsInFlightResult() async {
        let pipeline = ControlledPipeline()
        let coordinator = ChineseInputCoordinator { pipeline }
        coordinator.requestCandidates(for: [.symbol("ㄓ")])
        await waitUntil { await pipeline.requestedCount() == 1 }
        coordinator.invalidate()
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertTrue(coordinator.candidates.isEmpty)

        await pipeline.resolveNext(with: [makeCandidate("舊")])
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertTrue(coordinator.candidates.isEmpty)
    }

    func testPipelineInitializationFailureKeepsRawCandidates() {
        let coordinator = ChineseInputCoordinator {
            throw LexiconStoreError.databaseMissing(URL(fileURLWithPath: "/missing"))
        }
        coordinator.requestCandidates(for: [.symbol("ㄓ")])
        XCTAssertEqual(coordinator.state, .fallback(.pipelineUnavailable))
        XCTAssertEqual(coordinator.candidates.map(\.text), ["ㄓ"])
        XCTAssertTrue(coordinator.candidates.allSatisfy(\.isRawFallback))

        coordinator.requestCandidates(for: [.symbol("ㄓ"), .symbol("ㄨ")])
        XCTAssertEqual(coordinator.state, .fallback(.pipelineUnavailable))
        XCTAssertEqual(coordinator.candidates.map(\.text), ["ㄓㄨ"])
    }

    func testQueryFailureKeepsRawCandidates() async {
        let pipeline = ControlledPipeline()
        let coordinator = ChineseInputCoordinator { pipeline }
        coordinator.requestCandidates(for: [.symbol("ㄓ")])
        await waitUntil { await pipeline.requestedCount() == 1 }
        await pipeline.failNext(with: LexiconStoreError.queryFailed("boom"))
        await waitUntil { coordinator.state == .fallback(.queryFailed) }
        XCTAssertEqual(coordinator.candidates.map(\.text), ["ㄓ"])
        XCTAssertTrue(coordinator.candidates.allSatisfy(\.isRawFallback))
    }

    func testEmptyTokensClearCandidatesWithoutPipeline() {
        let flag = CreationFlag()
        let coordinator = ChineseInputCoordinator {
            flag.value = true
            return ControlledPipeline()
        }
        coordinator.requestCandidates(for: [])
        XCTAssertFalse(flag.value)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertTrue(coordinator.candidates.isEmpty)
    }

    func testCoordinatorDoesNotRetainItselfWhileRequestIsInFlight() async {
        let pipeline = ControlledPipeline()
        weak var weakCoordinator: ChineseInputCoordinator?
        autoreleasepool {
            let coordinator = ChineseInputCoordinator { pipeline }
            weakCoordinator = coordinator
            coordinator.requestCandidates(for: [.symbol("ㄓ")])
        }
        await waitUntil { await pipeline.requestedCount() == 1 }
        XCTAssertNil(weakCoordinator)
        await pipeline.resolveNext(with: [makeCandidate("舊")])
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @MainActor @escaping () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        var satisfied = await condition()
        while !satisfied && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
            satisfied = await condition()
        }
        XCTAssertTrue(satisfied)
    }
}

private final class CreationFlag {
    var value = false
}

@MainActor
final class DocumentEffectApplierTests: XCTestCase {
    func testMarkedTextForwardsSelectedRange() {
        let client = FakeKeyboardDocumentClient()
        let applier = DocumentEffectApplier(client: client)
        applier.apply([.setMarkedText("𠀀ㄓ", caret: 3)])
        XCTAssertEqual(client.events, [.setMarkedText("𠀀ㄓ", NSRange(location: 3, length: 0))])
    }

    func testMarkedTextUpdatesReplaceInsteadOfInserting() {
        let client = FakeKeyboardDocumentClient()
        let applier = DocumentEffectApplier(client: client)
        applier.apply([.setMarkedText("ㄓ", caret: 1)])
        applier.apply([.setMarkedText("ㄓㄨ", caret: 2)])
        XCTAssertEqual(
            client.events,
            [
                .setMarkedText("ㄓ", NSRange(location: 1, length: 0)),
                .setMarkedText("ㄓㄨ", NSRange(location: 2, length: 0)),
            ]
        )
    }

    func testSelectionProducesOnlyMarkedText() {
        var engine = KeyboardEngine()
        _ = engine.update(for: .zhuyin("ㄓ"))
        let update = engine.selectCandidate(makeCandidate("注"))
        let client = FakeKeyboardDocumentClient()
        DocumentEffectApplier(client: client).apply(update.documentEffects)
        XCTAssertEqual(client.events, [.setMarkedText("注", NSRange(location: 1, length: 0))])
    }

    func testCommitUnmarksBeforeInserting() {
        let client = FakeKeyboardDocumentClient()
        let applier = DocumentEffectApplier(client: client)
        applier.apply([.unmarkText, .insertText("\n")])
        XCTAssertEqual(client.events, [.unmarkText, .insertText("\n")])
    }

    func testReturnReplacesMarkedRangeWithCommittedText() {
        var engine = KeyboardEngine()
        _ = engine.update(for: .zhuyin("ㄓ"))
        let update = engine.update(for: .return)
        let client = FakeKeyboardDocumentClient()
        DocumentEffectApplier(client: client).apply(update.documentEffects)
        XCTAssertEqual(client.events, [.insertText("ㄓ")])
    }

    func testInputModeListIsNotADocumentEffect() {
        let client = FakeKeyboardDocumentClient()
        let applier = DocumentEffectApplier(client: client)
        applier.apply([.showInputModeList])
        XCTAssertTrue(client.events.isEmpty)
    }

    func testMoveCursorIsForwarded() {
        let client = FakeKeyboardDocumentClient()
        let applier = DocumentEffectApplier(client: client)
        applier.apply([.moveCursor(by: -1), .moveCursor(by: 1)])
        XCTAssertEqual(client.events, [.moveCursor(-1), .moveCursor(1)])
    }
}

@MainActor
private final class FakeKeyboardDocumentClient: KeyboardDocumentClient {
    enum Event: Equatable {
        case setMarkedText(String, NSRange)
        case unmarkText
        case insertText(String)
        case deleteBackward
        case moveCursor(Int)
    }

    private(set) var events: [Event] = []

    func setMarkedText(_ text: String, selectedRange: NSRange) {
        events.append(.setMarkedText(text, selectedRange))
    }

    func unmarkText() {
        events.append(.unmarkText)
    }

    func insertText(_ text: String) {
        events.append(.insertText(text))
    }

    func deleteBackward() {
        events.append(.deleteBackward)
    }

    func moveCursor(by offset: Int) {
        events.append(.moveCursor(offset))
    }
}
