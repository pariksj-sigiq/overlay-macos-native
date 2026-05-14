//
//  AudioRingBuffer.swift
//  OverlayOpus
//

import Foundation
import os

/// A small, lock-guarded ring buffer for mono Float PCM samples.
final class AudioRingBuffer {

    // MARK: - Storage

    private struct State {
        var samples: [Float]
        var writeIndex: Int = 0
        var availableCount: Int = 0

        init(capacity: Int) {
            self.samples = Array(repeating: 0, count: max(1, capacity))
        }
    }

    private let lock: OSAllocatedUnfairLock<State>

    var capacity: Int {
        lock.withLock { $0.samples.count }
    }

    var count: Int {
        lock.withLock { $0.availableCount }
    }

    // MARK: - Init

    init(capacity: Int) {
        self.lock = OSAllocatedUnfairLock(initialState: State(capacity: capacity))
    }

    // MARK: - Mutation

    func append(_ newSamples: [Float]) {
        guard !newSamples.isEmpty else { return }

        lock.withLock { state in
            let capacity = state.samples.count
            for sample in newSamples {
                state.samples[state.writeIndex] = sample
                state.writeIndex = (state.writeIndex + 1) % capacity
                state.availableCount = min(capacity, state.availableCount + 1)
            }
        }
    }

    func latestSamples(count requestedCount: Int) -> [Float] {
        guard requestedCount > 0 else { return [] }

        return lock.withLock { state in
            let sampleCount = min(requestedCount, state.availableCount)
            guard sampleCount > 0 else { return [] }

            let capacity = state.samples.count
            let start = (state.writeIndex - sampleCount + capacity) % capacity
            if start + sampleCount <= capacity {
                return Array(state.samples[start..<(start + sampleCount)])
            }

            let first = state.samples[start..<capacity]
            let secondCount = sampleCount - first.count
            return Array(first) + Array(state.samples[0..<secondCount])
        }
    }

    @discardableResult
    func drain(count requestedCount: Int? = nil) -> [Float] {
        lock.withLock { state in
            let sampleCount = min(requestedCount ?? state.availableCount, state.availableCount)
            guard sampleCount > 0 else { return [] }

            let capacity = state.samples.count
            let start = (state.writeIndex - state.availableCount + capacity) % capacity
            let drained: [Float]
            if start + sampleCount <= capacity {
                drained = Array(state.samples[start..<(start + sampleCount)])
            } else {
                let first = state.samples[start..<capacity]
                let secondCount = sampleCount - first.count
                drained = Array(first) + Array(state.samples[0..<secondCount])
            }

            state.availableCount -= sampleCount
            return drained
        }
    }

    func removeAll() {
        lock.withLock { state in
            state.writeIndex = 0
            state.availableCount = 0
        }
    }
}
