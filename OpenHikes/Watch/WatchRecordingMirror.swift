//
//  WatchRecordingMirror.swift
//  OpenHikes
//
//  Keeping a watch's picture of *this phone's* recording up to date, and
//  turning a button on the watch into a call on the recorder.
//
//  ## Why this reads through `HikeIntentCoordinator`
//
//  Because that is already the whole of what a surface outside the view tree
//  may do to a recording. The Control Center toggle goes through it, every
//  Siri phrase goes through it, and the Live Activity's controls go through
//  it; a watch reaching past it to `HikeRecorder` would be a fifth spelling of
//  four rules that are written down once — settling automatic recovery before
//  reading a phase, reporting a refusal as a sentence rather than as a phase
//  nobody reads, and hedging a trail match that newer fixes have overtaken.
//
//  It also means the watch shows exactly what Siri says. There is one
//  description of a live recording on this phone, and both read it.
//
//  ## Why the publisher is a loop rather than an observer
//
//  `withObservationTracking` on the recorder's stats would fire on every GPS
//  fix, and the answer to most of them is "nothing a watch screen would
//  redraw" — the same argument render isolation makes about a SwiftUI body,
//  one process further out. A loop on ``WatchPhoneRecording/updateFloorSeconds``
//  publishes at the rate a hiker reads rather than at the rate a receiver
//  reports, and the *state changes* that must not wait for it do not: they
//  arrive as the reply to the command that caused them.
//
//  The loop runs only while the watch app is **reachable**, which on iOS means
//  it is in the foreground — in other words, only while somebody is looking at
//  it. A paired watch in a pocket costs nothing, and an unpaired one costs
//  nothing at all.
//

import Foundation
import OpenHikesShared
import os

@MainActor
final class WatchRecordingMirror {
    nonisolated private static let logger = Logger(subsystem: "OpenHikes", category: "WatchMirror")

    /// The seam every read and every command goes through. Weak because the
    /// coordinator is registered with `AppDependencyManager` and outlives
    /// nothing here; a mirror holding it strongly would be a retain cycle
    /// through the link that owns this.
    private weak var coordinator: HikeIntentCoordinator?
    /// What to do with a fresh reading. Handed in rather than reached for, so
    /// this type can be driven without a `WCSession` behind it.
    private let publish: @MainActor (WatchPhoneRecording) -> Void

    private var pump: Task<Void, Never>?
    /// The last reading sent, so an unchanged one is not sent again. A hiker
    /// standing still for ten minutes is the ordinary case, and it should cost
    /// nothing.
    private var lastPublished: WatchPhoneRecording?

    init(
        coordinator: HikeIntentCoordinator?,
        publish: @escaping @MainActor (WatchPhoneRecording) -> Void
    ) {
        self.coordinator = coordinator
        self.publish = publish
    }

    deinit { pump?.cancel() }

    /// Starts or stops the loop as the watch app comes and goes.
    func reachabilityChanged(to isReachable: Bool) {
        guard isReachable else {
            pump?.cancel()
            pump = nil
            return
        }
        guard pump == nil else { return }
        pump = Task { [weak self] in
            // Published once immediately, because the watch app has just come
            // to the foreground and its screen is empty until something
            // arrives; waiting a floor for the first reading would make every
            // glance start blank.
            await self?.publishCurrentState()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(WatchPhoneRecording.updateFloorSeconds))
                guard !Task.isCancelled else { return }
                await self?.publishCurrentState()
            }
        }
    }

    /// Reads the recorder and sends the result if it has moved.
    func publishCurrentState() async {
        let reading = await currentState()
        // `updatedAt` moves on every read by construction, so the comparison
        // deliberately ignores it: what is being asked is whether anything a
        // hiker would *see* has changed.
        guard !reading.matchesFigures(of: lastPublished) else { return }
        lastPublished = reading
        publish(reading)
    }

    /// Performs a command and answers with what happened.
    ///
    /// The resulting state is read back afterwards rather than assumed from
    /// the command, which is the same thing `HikeIntentCoordinator` does for
    /// its own callers and for the same reason: the recorder reports refusals
    /// by moving to a phase rather than by throwing, so a caller that merely
    /// awaited `start()` would confirm a hike that never began.
    func perform(_ command: WatchRecordingCommand) async -> WatchCommandOutcome {
        guard let coordinator else {
            return WatchCommandOutcome(
                commandID: command.id,
                recording: .idle(),
                refusal: "OpenHikes isn't ready on your iPhone yet."
            )
        }
        var refusal: String?
        do {
            switch command.action {
            case .pause: _ = try await coordinator.pauseRecording()
            case .resume: _ = try await coordinator.resumeRecording()
            case .start: _ = try await coordinator.startRecording()
            case .stop: _ = try await coordinator.stopRecording()
            }
        } catch {
            // `HikeIntentFailure`'s own sentence, which is written to be read
            // out loud and is therefore already short enough for a watch.
            refusal = error.errorDescription
            Self.logger.debug(
                """
                A watch \(command.action.rawValue, privacy: .public) was refused: \
                \(error.localizedDescription, privacy: .public)
                """
            )
        }
        let reading = await currentState()
        lastPublished = reading
        return WatchCommandOutcome(
            commandID: command.id,
            recording: reading,
            refusal: refusal
        )
    }

    /// What the phone's recorder is doing, as the watch's payload.
    ///
    /// `noActiveRecording` is not a failure here: it is the ordinary answer
    /// for a hiker who is not recording, and it is exactly what the watch's
    /// idle screen draws. Every *other* refusal is also reported as idle,
    /// because from the watch's side "busy finishing" and "waiting for a route
    /// review" are both states in which there is no running hike to show — and
    /// the one place those sentences matter is the reply to a button, which
    /// carries them.
    private func currentState() async -> WatchPhoneRecording {
        guard let coordinator else { return .idle() }
        do {
            let report = try await coordinator.currentRecording()
            return WatchPhoneRecording(
                state: report.isPaused ? .paused : .recording,
                elapsedSeconds: report.elapsed,
                distanceMeters: report.distance.converted(to: .meters).value,
                trailName: report.trailName,
                isTrailNameStale: report.isTrailNameStale
            )
        } catch {
            return .idle()
        }
    }
}

private extension WatchPhoneRecording {
    /// Whether this reading says the same thing as `other` about everything a
    /// hiker can see.
    ///
    /// Deliberately not `==`: `updatedAt` moves on every read, so equality
    /// would answer "no" to every comparison and the floor would publish on
    /// every tick. The clock is excluded for the same reason and can be —
    /// the watch runs it forward itself from ``clockAnchor``.
    func matchesFigures(of other: WatchPhoneRecording?) -> Bool {
        guard let other else { return false }
        return state == other.state
            && Int(distanceMeters) == Int(other.distanceMeters)
            && trailName == other.trailName
            && isTrailNameStale == other.isTrailNameStale
    }
}
