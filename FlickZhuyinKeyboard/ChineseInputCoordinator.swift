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

    private(set) var state: ChineseInputPipelineState = .idle
    private(set) var candidates: [InputCandidate] = []

    var onChange: (() -> Void)?

    init(makePipeline: @escaping () throws -> any ChineseInputPipeline) {
        self.makePipeline = makePipeline
    }

    deinit {
        task?.cancel()
    }

    func requestCandidates(for tokens: [ZhuyinInputToken]) {
        revision += 1
        let requestRevision = revision
        task?.cancel()
        task = nil

        guard !tokens.isEmpty else {
            pendingSnapshot = []
            candidates = []
            state = .idle
            notify()
            return
        }

        pendingSnapshot = tokens
        candidates = [
            InputCandidate.rawFallback(tokens: tokens, score: .greatestFiniteMagnitude)
        ].compactMap { $0 }
        state = .loading
        notify()

        guard !pipelineUnavailable else {
            state = .fallback(.pipelineUnavailable)
            notify()
            return
        }

        let pipeline: any ChineseInputPipeline
        do {
            pipeline = try resolvedPipeline()
        } catch {
            pipelineUnavailable = true
            state = .fallback(.pipelineUnavailable)
            logFailure(.pipelineUnavailable)
            notify()
            return
        }

        task = Task { [weak self] in
            do {
                let result = try await pipeline.candidates(for: tokens)
                guard !Task.isCancelled else { return }
                self?.apply(result, requestRevision: requestRevision, tokens: tokens)
            } catch {
                guard !Task.isCancelled else { return }
                self?.applyFailure(.queryFailed, requestRevision: requestRevision, tokens: tokens)
            }
        }
    }

    func invalidate() {
        revision += 1
        task?.cancel()
        task = nil
        pendingSnapshot = []
        candidates = []
        state = .idle
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
        state = .fallback(failure)
        logFailure(failure)
        notify()
    }

    private func logFailure(_ failure: ChineseInputFailure) {
        Logger(subsystem: "com.wirelesseye.FlickZhuyin", category: "ChineseInput")
            .debug("candidate request failed: \(String(describing: failure), privacy: .public)")
    }

    private func notify() {
        onChange?()
    }
}
