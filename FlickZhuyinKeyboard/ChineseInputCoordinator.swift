import Foundation
import os

enum ChineseInputFailure: Equatable, Sendable {
    case pipelineUnavailable
    case queryFailed
}

enum ChineseInputPipelineState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case fallback(ChineseInputFailure)
}

@MainActor
final class ChineseInputCoordinator {
    private let makePipeline: () throws -> any ChineseInputPipeline
    private var pipeline: (any ChineseInputPipeline)?
    private var pipelineUnavailable = false
    private var task: Task<Void, Never>?
    private var revision = 0
    private var pendingSnapshot: [ZhuyinInputToken] = []
    private var pendingSuggestionContext = ""

    private(set) var state: ChineseInputPipelineState = .idle
    private(set) var candidates: [InputCandidate] = []
    private(set) var suggestions: [String] = []

    var items: [CandidateItem] {
        if !suggestions.isEmpty { return suggestions.map(CandidateItem.suggestion) }
        return candidates.map(CandidateItem.input)
    }

    var onChange: (() -> Void)?

    init(makePipeline: @escaping () throws -> any ChineseInputPipeline) {
        self.makePipeline = makePipeline
    }

    deinit {
        task?.cancel()
    }

    func requestCandidates(for tokens: [ZhuyinInputToken], precedingText: String = "") {
        revision += 1
        let requestRevision = revision
        task?.cancel()
        task = nil
        suggestions = []
        pendingSuggestionContext = ""

        guard !tokens.isEmpty else {
            pendingSnapshot = []
            candidates = []
            state = .idle
            notify()
            return
        }

        pendingSnapshot = tokens
        state = .loading

        guard !pipelineUnavailable else {
            candidates = rawCandidates(for: tokens)
            state = .fallback(.pipelineUnavailable)
            notify()
            return
        }

        let pipeline: any ChineseInputPipeline
        do {
            pipeline = try resolvedPipeline()
        } catch {
            pipelineUnavailable = true
            candidates = rawCandidates(for: tokens)
            state = .fallback(.pipelineUnavailable)
            logFailure(.pipelineUnavailable)
            notify()
            return
        }

        task = Task { [weak self] in
            do {
                let result = try await pipeline.candidates(for: tokens, precedingText: precedingText)
                guard !Task.isCancelled else { return }
                self?.apply(result, requestRevision: requestRevision, tokens: tokens)
            } catch {
                guard !Task.isCancelled else { return }
                self?.applyFailure(.queryFailed, requestRevision: requestRevision, tokens: tokens)
            }
        }
    }

    func requestSuggestions(after precedingText: String) {
        revision += 1
        let requestRevision = revision
        task?.cancel()
        task = nil
        pendingSnapshot = []
        candidates = []
        suggestions = []
        let context = GrammarContext.tail(of: precedingText)
        pendingSuggestionContext = context
        guard !context.isEmpty, context.unicodeScalars.last.map({
            switch $0.value {
            case 0x3400...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: true
            default: false
            }
        }) == true else {
            state = .idle
            notify()
            return
        }
        guard !pipelineUnavailable else {
            state = .idle
            notify()
            return
        }
        let pipeline: any ChineseInputPipeline
        do {
            pipeline = try resolvedPipeline()
        } catch {
            pipelineUnavailable = true
            state = .idle
            logFailure(.pipelineUnavailable)
            notify()
            return
        }
        state = .loading
        notify()
        task = Task { [weak self] in
            let result = (try? await pipeline.suggestions(after: context)) ?? []
            guard !Task.isCancelled else { return }
            self?.applySuggestions(result, requestRevision: requestRevision, context: context)
        }
    }

    func invalidate() {
        revision += 1
        task?.cancel()
        task = nil
        pendingSnapshot = []
        pendingSuggestionContext = ""
        candidates = []
        suggestions = []
        state = .idle
        notify()
    }

    private func applySuggestions(_ result: [String], requestRevision: Int, context: String) {
        guard requestRevision == revision, pendingSuggestionContext == context else { return }
        suggestions = result
        state = .ready
        notify()
    }

    private func resolvedPipeline() throws -> any ChineseInputPipeline {
        if let pipeline {
            return pipeline
        }
        let created = try makePipeline()
        pipeline = created
        return created
    }

    private func apply(
        _ result: [InputCandidate],
        requestRevision: Int,
        tokens: [ZhuyinInputToken]
    ) {
        guard requestRevision == revision, pendingSnapshot == tokens else { return }
        candidates = result
        state = .ready
        notify()
    }

    private func applyFailure(
        _ failure: ChineseInputFailure,
        requestRevision: Int,
        tokens: [ZhuyinInputToken]
    ) {
        guard requestRevision == revision, pendingSnapshot == tokens else { return }
        candidates = rawCandidates(for: tokens)
        state = .fallback(failure)
        logFailure(failure)
        notify()
    }

    private func rawCandidates(for tokens: [ZhuyinInputToken]) -> [InputCandidate] {
        [InputCandidate.rawFallback(tokens: tokens, score: .greatestFiniteMagnitude)]
            .compactMap { $0 }
    }

    private func logFailure(_ failure: ChineseInputFailure) {
        Logger(subsystem: "com.wirelesseye.FlickZhuyin", category: "ChineseInput")
            .debug("candidate request failed: \(String(describing: failure), privacy: .public)")
    }

    private func notify() {
        onChange?()
    }
}
