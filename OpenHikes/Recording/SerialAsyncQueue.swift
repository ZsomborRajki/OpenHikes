//
//  SerialAsyncQueue.swift
//  OpenHikes
//
//  Ordered background work with a real barrier, for the recording journal and
//  the shared state the widget reads.
//

import Foundation

/// Runs submitted operations one at a time, in submission order, off the
/// caller's task.
///
/// Recording has two sinks that must stay ordered — the crash-safe journal and
/// the App Group snapshot — and both are fed from the main actor by callbacks
/// that can't wait for a disk write. Chaining each new operation onto the
/// previous one's `Task` orders them, but leaves no way to ask *"is the queue
/// empty yet?"*: awaiting the tail races with whatever was appended while that
/// await was suspended.
///
/// A stream gives that question an answer. ``drain()`` submits a barrier and
/// waits for it, and because the consumer takes operations in order, every
/// operation submitted beforehand has finished by the time it returns.
///
/// The buffer is unbounded deliberately. Back pressure is the wrong trade
/// here — suspending the sender is exactly what a location callback on the
/// main actor must not do — and keeping submission synchronous is also what
/// keeps it ordered, since two concurrent suspending sends could arrive in
/// either order.
nonisolated final class SerialAsyncQueue: Sendable {
    typealias Operation = @Sendable () async -> Void

    private let continuation: AsyncStream<Operation>.Continuation

    init() {
        let (stream, streamContinuation) = AsyncStream<Operation>.makeStream(
            bufferingPolicy: .unbounded
        )
        continuation = streamContinuation
        Task {
            for await operation in stream {
                await operation()
            }
        }
    }

    deinit {
        // Finish rather than cancel: anything already queued is a durable
        // write the walker is owed, and the consumer exits once it has
        // drained.
        continuation.finish()
    }

    /// Submits `operation` and returns without waiting for it.
    func enqueue(_ operation: @escaping Operation) {
        continuation.yield(operation)
    }

    /// Waits until everything submitted before this call has finished.
    ///
    /// Work submitted *after* it may or may not have run; anything that has to
    /// be ordered against the barrier belongs on the queue itself.
    func drain() async {
        await withCheckedContinuation { checkedContinuation in
            enqueue {
                checkedContinuation.resume()
            }
        }
    }
}
