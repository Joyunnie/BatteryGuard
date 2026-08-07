// TopUpAndLED.swift
// Generation-ordered MagSafe LED ownership with one worker task.

import Foundation

enum MagSafeLEDIntent: Equatable, Sendable {
    case solid(MagSafeLEDState)
    case blink
    case restore
}

actor MagSafeLEDController {
    typealias ErrorHandler = @Sendable (Error) async -> Void

    private struct Request: Sendable {
        let intent: MagSafeLEDIntent
        let generation: UInt64
        let onError: ErrorHandler
    }

    private let backend: MagSafeLEDBackend
    private var latestGeneration: UInt64 = 0
    private var pendingRequest: Request?
    private var workerTask: Task<Void, Never>?
    private var blinkingGeneration: UInt64?
    private var blinkingErrorHandler: ErrorHandler?
    private var blinkState = MagSafeLEDState.orange
    private var hasControl = false

    init(backend: MagSafeLEDBackend) {
        self.backend = backend
    }

    @discardableResult
    func apply(
        _ intent: MagSafeLEDIntent,
        generation: UInt64,
        onError: @escaping ErrorHandler
    ) -> Bool {
        guard generation >= latestGeneration else { return false }
        latestGeneration = generation
        pendingRequest = Request(intent: intent, generation: generation, onError: onError)
        if workerTask == nil {
            workerTask = Task { [weak self] in await self?.runWorker() }
        }
        return true
    }

    func shutdown(generation: UInt64) async throws {
        guard generation >= latestGeneration else { return }
        latestGeneration = generation
        pendingRequest = nil
        blinkingGeneration = nil
        blinkingErrorHandler = nil
        let existingWorker = workerTask
        workerTask = nil
        existingWorker?.cancel()
        await existingWorker?.value
        guard hasControl else { return }
        try await backend.restoreMagSafeLED()
        hasControl = false
    }

    private func runWorker() async {
        while !Task.isCancelled {
            if let request = pendingRequest {
                pendingRequest = nil
                await perform(request)
                continue
            }

            if let generation = blinkingGeneration, generation == latestGeneration {
                let state = blinkState
                blinkState = state == .orange ? .green : .orange
                do {
                    try await backend.setMagSafeLED(state)
                } catch {
                    guard generation == latestGeneration, !Task.isCancelled else { continue }
                    if let blinkingErrorHandler { await blinkingErrorHandler(error) }
                }
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    break
                }
                continue
            }

            workerTask = nil
            return
        }
        workerTask = nil
    }

    private func perform(_ request: Request) async {
        guard request.generation == latestGeneration else { return }
        blinkingGeneration = nil
        blinkingErrorHandler = nil

        do {
            switch request.intent {
            case .solid(let state):
                hasControl = true
                try await backend.setMagSafeLED(state)
            case .blink:
                hasControl = true
                blinkingGeneration = request.generation
                blinkingErrorHandler = request.onError
                blinkState = .orange
            case .restore:
                guard hasControl else { return }
                try await backend.restoreMagSafeLED()
                if request.generation == latestGeneration { hasControl = false }
            }
        } catch {
            guard request.generation == latestGeneration, !Task.isCancelled else { return }
            await request.onError(error)
        }
    }
}
