//
//  ObservedValues.swift
//  OpenHikes
//
//  A main-actor read of `@Observable` state as an async sequence, on every
//  release the app supports.
//
//  The poll loops that wake on a change rather than on a timer — the weather
//  loop, the hike detail's auto-follow, the recorder's energy profile — are
//  written against `Observations`, which is iOS 26's. Below 26 there is only
//  `withObservationTracking`, and ``EarlierObservations`` builds the same
//  contract on it: the current value when iteration starts, then the latest
//  value after each change, with changes that land before the consumer gets
//  to run arriving as one element, the newest.
//
//  Its `onChange` fires *inside* the mutation, before the new value can be
//  read, so the next read is deferred to the next main-actor turn — the rule
//  every other `withObservationTracking` in this app follows. That deferral
//  is also what coalesces a burst: the registration is spent by the first
//  change, and the read that renews it sees all of them.
//

import Observation

/// The values `read` produces as the `@Observable` state it reads changes:
/// `Observations` on iOS 26 and later, ``EarlierObservations`` below.
func observedValues<Element: Sendable>(
    _ read: @escaping @MainActor @Sendable () -> Element
) -> some AsyncSequence<Element, Never> & Sendable {
    if #available(iOS 26.0, *) {
        return Observations(read)
    } else {
        return EarlierObservations(read)
    }
}

/// `Observations`, for the releases before it, built on
/// `withObservationTracking` — see the file header for the contract.
///
/// Its own type rather than private to ``observedValues(_:)``, so a suite can
/// hold it to that contract on a release that would otherwise never run it.
nonisolated struct EarlierObservations<Element: Sendable>: AsyncSequence, Sendable {
    typealias Failure = Never

    private let read: @MainActor @Sendable () -> Element

    init(_ read: @escaping @MainActor @Sendable () -> Element) {
        self.read = read
    }

    func makeAsyncIterator() -> AsyncStream<Element>.Iterator {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Element.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let tracker = ObservationTracker(read: read, continuation: continuation)
        // Held by the stream, and so for exactly as long as it is iterated:
        // the tracker's own `onChange` holds it weakly.
        continuation.onTermination = { _ in onMainActor { tracker.stop() } }
        onMainActor { tracker.track() }
        return stream.makeAsyncIterator()
    }
}

/// One iteration's tracking: reads, yields, and renews itself after each
/// change until its stream ends.
///
/// Made wherever the iteration starts, which need not be the main actor, and
/// used only on it.
private final class ObservationTracker<Element: Sendable> {
    private let read: @MainActor @Sendable () -> Element
    private let continuation: AsyncStream<Element>.Continuation
    private var isStopped = false

    nonisolated init(
        read: @escaping @MainActor @Sendable () -> Element,
        continuation: AsyncStream<Element>.Continuation
    ) {
        self.read = read
        self.continuation = continuation
    }

    func track() {
        guard !isStopped else { return }
        let value = withObservationTracking {
            read()
        } onChange: { [weak self] in
            // Mid-mutation: the value can only be read once it has landed.
            Task { @MainActor in self?.track() }
        }
        continuation.yield(value)
    }

    func stop() {
        isStopped = true
    }
}
