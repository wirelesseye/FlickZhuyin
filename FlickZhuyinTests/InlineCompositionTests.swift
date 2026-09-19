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
        var composition = ZhuyinComposition(selectedChunks: [chunk])
        XCTAssertEqual(composition.markedText, "注")
        XCTAssertEqual(composition.pendingText, "")
        XCTAssertFalse(composition.isEmpty)

        composition.pendingTokens = [.symbol("ㄧ"), .symbol("ㄣ"), .tone(.first)]
        XCTAssertEqual(composition.pendingText, "ㄧㄣˉ")
        XCTAssertEqual(composition.markedText, "注ㄧㄣˉ")
    }

    func testEmptyCompositionIsEmpty() {
        let composition = ZhuyinComposition()
        XCTAssertTrue(composition.isEmpty)
        XCTAssertEqual(composition.markedText, "")
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
        XCTAssertEqual(update.documentEffects, [.setMarkedText("注")])
        XCTAssertTrue(update.invalidatesCandidates)
        XCTAssertNil(update.candidateRequest)
        XCTAssertEqual(engine.composition.selectedChunks.map(\.text), ["注"])
        XCTAssertTrue(engine.composition.pendingTokens.isEmpty)
        XCTAssertFalse(engine.hasPendingTokens)
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
        XCTAssertTrue(engine.composition.pendingTokens.isEmpty)
    }

    func testDeleteUndoesSelectedChunkAndRestoresTokens() {
        var engine = KeyboardEngine()
        selectZhuyin(&engine)
        let undo = engine.update(for: .delete)
        XCTAssertEqual(undo.documentEffects, [.setMarkedText("ㄓㄨˋ")])
        XCTAssertEqual(
            undo.candidateRequest?.tokens,
            [.symbol("ㄓ"), .symbol("ㄨ"), .tone(.fourth)]
        )
        XCTAssertFalse(undo.invalidatesCandidates)
        XCTAssertTrue(engine.composition.selectedChunks.isEmpty)
        XCTAssertEqual(engine.pendingText, "ㄓㄨˋ")
    }

    func testDeletingLastPendingTokenEndsMarkedText() {
        var engine = KeyboardEngine()
        _ = engine.update(for: .zhuyin("ㄓ"))

        let update = engine.update(for: .delete)

        XCTAssertEqual(update.documentEffects, [.setMarkedText(""), .unmarkText])
        XCTAssertTrue(update.invalidatesCandidates)
        XCTAssertNil(update.candidateRequest)
        XCTAssertTrue(engine.composition.isEmpty)
    }

    func testDeletingPendingTokenKeepsSelectedTextMarked() {
        var engine = KeyboardEngine()
        selectZhuyin(&engine)
        _ = engine.update(for: .zhuyin("ㄧ"))

        let update = engine.update(for: .delete)

        XCTAssertEqual(update.documentEffects, [.setMarkedText("注")])
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
        XCTAssertTrue(engine.hasPendingTokens)
        _ = engine.selectCandidate(makeCandidate("注"))
        XCTAssertFalse(engine.hasPendingTokens)
        XCTAssertFalse(engine.composition.isEmpty)
        _ = engine.update(for: .delete)
        XCTAssertTrue(engine.hasPendingTokens)
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
    func testMarkedTextSelectionUsesUTF16Length() {
        let client = FakeKeyboardDocumentClient()
        let applier = DocumentEffectApplier(client: client)
        applier.apply([.setMarkedText("𠀀ㄓ")])
        XCTAssertEqual(client.events, [.setMarkedText("𠀀ㄓ", NSRange(location: 3, length: 0))])
    }

    func testMarkedTextUpdatesReplaceInsteadOfInserting() {
        let client = FakeKeyboardDocumentClient()
        let applier = DocumentEffectApplier(client: client)
        applier.apply([.setMarkedText("ㄓ")])
        applier.apply([.setMarkedText("ㄓㄨ")])
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
}

@MainActor
private final class FakeKeyboardDocumentClient: KeyboardDocumentClient {
    enum Event: Equatable {
        case setMarkedText(String, NSRange)
        case unmarkText
        case insertText(String)
        case deleteBackward
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
}
