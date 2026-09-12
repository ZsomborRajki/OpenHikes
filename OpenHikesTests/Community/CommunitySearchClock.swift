import Foundation
import Synchronization

/// A manually advanced clock whose registered waits are observable barriers.
nonisolated final class CommunitySearchClock: Clock, Sendable {
    typealias Instant = ContinuousClock.Instant

    private struct Waiter {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = ContinuousClock.now
        var waiters: [UUID: Waiter] = [:]
    }

    private let state = Mutex(State())
    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .nanoseconds(1) }
    var pendingWaits: Int { state.withLock { $0.waiters.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let identifier = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                state.withLock { state in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if deadline <= state.now {
                        continuation.resume()
                    } else {
                        state.waiters[identifier] = Waiter(deadline: deadline, continuation: continuation)
                    }
                }
            }
        } onCancel: {
            let waiter = self.state.withLock { $0.waiters.removeValue(forKey: identifier) }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let ready = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let ready = state.waiters.filter { $0.value.deadline <= state.now }
            for identifier in ready.keys { state.waiters.removeValue(forKey: identifier) }
            return ready.values.map(\.continuation)
        }
        for continuation in ready { continuation.resume() }
    }
}
