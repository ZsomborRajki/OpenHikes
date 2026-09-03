//
//  HikeIntentCoordinator.swift
//  OpenHikes
//
//  The whole of what an App Intent can do, with none of AppIntents in it.
//
//  Every intent in this folder is a title, a phrase and one call into here.
//  That split is the point: `AppIntent.perform()` can only be exercised by the
//  system, whereas this class takes the same `HikeRecorder` and
//  `ModelContainer` the app runs on and can be handed a stub-sourced recorder
//  by a suite — which is how the start/pause/resume/stop paths are tested with
//  no ActivityKit, no Core Location and no App Group behind them.
//
//  It deliberately owns no state of its own. The recorder is the single
//  authority on whether a hike is being recorded — the widget, the Live
//  Activity and the recording screen all read it — and a second answer kept
//  here would be a fourth surface able to disagree with the other three.
//

import Foundation
import os
import SwiftData

@MainActor
final class HikeIntentCoordinator {
    private let recorder: HikeRecorder
    private let container: ModelContainer
    private let calendar: Calendar
    private let clock: @Sendable () -> Date

    /// Where a store failure's own words go. They are logged rather than
    /// spoken: the underlying text is a SwiftData message written for a
    /// developer, and ``HikeIntentFailure/storage`` is read aloud by Siri.
    private static let logger = Logger(subsystem: "OpenHikes", category: "Intents")

    init(
        recorder: HikeRecorder,
        container: ModelContainer,
        calendar: Calendar = .autoupdatingCurrent,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.recorder = recorder
        self.container = container
        self.calendar = calendar
        self.clock = clock
    }
}

// MARK: - Controlling a recording

extension HikeIntentCoordinator {
    /// What Core Location will do to a recording started right now.
    ///
    /// Read by the intents *before* starting rather than inferred from a
    /// failure afterwards: `HikeRecorder.start()` answers `.notDetermined` by
    /// putting up the system prompt and returning, which from a background
    /// intent is a recording that silently never begins.
    ///
    /// Reduced accuracy is reported separately from `.granted` because it is
    /// the *second* prompt location can put up and the recorder walks into it
    /// on both paths that matter: `activateSessionIfPossible()` and `resume()`
    /// each call `requestTemporaryFullAccuracy()` and then fail with
    /// `.preciseLocationRequired` when it did not land. That request cannot
    /// show its alert from the background either, so treating a
    /// reduced-accuracy walker as authorized turns "start a hike" into "turn
    /// on Precise Location in Settings" for somebody whose phone is in their
    /// pocket.
    var authorization: HikeIntentAuthorization {
        switch recorder.source.authorization {
        case .authorized: recorder.source.hasFullAccuracy ? .granted : .reducedAccuracy
        case .denied: .denied
        case .notDetermined: .undecided
        }
    }

    /// Switched over exhaustively rather than gated on `isActive`, which is
    /// true for a *failed* and a *reviewing* session as well — that is how the
    /// recording screen offers the walker their way back to one. Neither is a
    /// hike underway, and answering "already recording" to either would be the
    /// wrong sentence about the wrong problem. Exhaustive so that a phase
    /// added later fails to compile here rather than falling into a default
    /// that quietly reports success.
    func startRecording() async throws(HikeIntentFailure) -> LiveRecordingReport {
        await settleRecorder()
        switch recorder.phase {
        // `start()` resets a failed session and tries again, so a refusal the
        // walker has since fixed — permission granted in Settings — starts
        // cleanly on the second ask.
        case .idle, .failed: break
        case .waitingForFix, .recording, .paused: throw .alreadyRecording
        case .reviewing: throw .awaitingRouteReview
        case .saving, .recovering: throw .busyFinishing
        }
        await recorder.start()
        try throwIfRecorderFailed()
        // A failed session that kept its id is not reset by `start()`, which
        // then returns having done nothing. Without this the walker is told
        // their hike is being recorded by the very call that declined to.
        guard recorder.isCapturingFixes else { throw .busyFinishing }
        return liveReport()
    }

    func pauseRecording() async throws(HikeIntentFailure) -> LiveRecordingReport {
        await settleRecorder()
        guard recorder.phase == .waitingForFix || recorder.phase == .recording else {
            throw .noActiveRecording
        }
        recorder.pause()
        try throwIfRecorderFailed()
        return liveReport()
    }

    func resumeRecording() async throws(HikeIntentFailure) -> LiveRecordingReport {
        await settleRecorder()
        guard recorder.phase == .paused else { throw .notPaused }
        await recorder.resume()
        try throwIfRecorderFailed()
        return liveReport()
    }

    /// Stops and saves, and reports the hike that was written.
    ///
    /// Throws ``HikeIntentFailure/awaitingRouteReview`` when trail matching
    /// found more than one route the walk could have been. The recording is
    /// safe either way — the journal is closed and the draft is on disk — but
    /// the choice is a map with two lines on it, and there is no voice answer
    /// to that question.
    func stopRecording() async throws(HikeIntentFailure) -> FinishedHikeReport {
        await settleRecorder()
        switch recorder.phase {
        case .waitingForFix, .recording, .paused: break
        case .idle: throw .noActiveRecording
        case .reviewing: throw .awaitingRouteReview
        case .saving, .recovering: throw .busyFinishing
        case .failed(let failure): throw .recording(failure)
        }
        let outcome: RecordingStopOutcome
        do {
            outcome = try await recorder.stop()
        } catch let failure as RecordingFailure {
            throw .recording(failure)
        } catch {
            // Logged rather than spoken, as in `fetch(_:)` below, and its own
            // case rather than `.storage`: nothing was read here, a hike was
            // written, and the two failures have nothing to say to each other.
            Self.logger.error(
                "Stopping a recording for an intent failed: \(error.localizedDescription, privacy: .public)"
            )
            throw .couldNotSave
        }
        switch outcome {
        case .needsReview: throw .awaitingRouteReview
        case .saved(let hike): return Self.report(for: hike)
        }
    }

    /// The recording as it stands.
    ///
    /// A recording still waiting for its first fix counts: the walker started
    /// it, the GPS is on, and "no hike is being recorded" would be a lie told
    /// during the ten seconds that matter most. A *failed* one does not, and
    /// is reported as the failure — its distance is real but it is no longer
    /// being added to, and reading it back as progress is how somebody walks
    /// another hour on a recording that stopped.
    func currentRecording() async throws(HikeIntentFailure) -> LiveRecordingReport {
        await settleRecorder()
        switch recorder.phase {
        case .waitingForFix, .recording, .paused: return liveReport()
        case .failed(let failure): throw .recording(failure)
        case .idle, .saving, .reviewing, .recovering: throw .noActiveRecording
        }
    }

    private func liveReport() -> LiveRecordingReport {
        LiveRecordingReport(
            distance: Measurement(
                value: recorder.stats.distanceMeters,
                unit: .meters
            ),
            elapsed: recorder.elapsedSeconds(),
            isPaused: recorder.phase == .paused,
            trailName: recorder.stats.currentTrail?.name,
            // Carried rather than dropped: the recording screen dims this same
            // card when newer fixes have overtaken the match, and on a densely
            // sampled walk that is routinely true. This surface is the one
            // used when the walker *cannot* look at the screen, so it is the
            // last place to state a stale match flatly.
            isTrailNameStale: recorder.stats.isCurrentTrailStale
        )
    }

    /// Waits out a recovery pass before reading ``HikeRecorder/phase``.
    ///
    /// A launch that recovers automatically is in `.recovering` from the
    /// instant the recorder is constructed, whether or not there is anything
    /// to recover — and the launch this whole design exists for is the one the
    /// system makes *in order to* perform an intent. Without this, every
    /// intent on a cold start answers about the launch: "still finishing your
    /// last recording" to somebody who has none, "not recording" to somebody
    /// who is.
    private func settleRecorder() async {
        await recorder.settleAutomaticRecovery()
    }

    /// Turns the recorder's own `.failed` phase into a thrown error.
    ///
    /// The recorder reports refusals by moving to `.failed` rather than by
    /// throwing — the recording screen watches the phase — so an intent that
    /// only awaited `start()` would report a hike underway that never began.
    private func throwIfRecorderFailed() throws(HikeIntentFailure) {
        guard case .failed(let failure) = recorder.phase else { return }
        throw .recording(failure)
    }
}

// MARK: - Reading what has been walked

extension HikeIntentCoordinator {
    /// The most recent finished hike.
    ///
    /// Drafts are excluded by `isRecording`: a recording in progress owns a
    /// persisted row from the moment it starts, and it is not something to
    /// report as "your last hike" while it is still being walked.
    func lastFinishedHike() throws(HikeIntentFailure) -> FinishedHikeReport {
        var descriptor = FetchDescriptor<Hike>(
            predicate: #Predicate { !$0.isRecording },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let hike = try fetch(descriptor).first else { throw .noHikesYet }
        return Self.report(for: hike)
    }

    /// What was walked on the calendar day containing `date`.
    func totals(forDayContaining date: Date) throws(HikeIntentFailure) -> HikeTotalsReport {
        let day = calendar.startOfDay(for: date)
        guard let next = calendar.date(byAdding: .day, value: 1, to: day) else {
            // Only reachable for a date the calendar cannot step from, which
            // is not a state the walker can be told anything useful about —
            // and not a store failure, so not `.storage`, whose own sentence
            // would claim their hikes could not be read.
            throw .unknownDay
        }
        return try totals(from: day, to: next)
    }

    func totals(from start: Date, to end: Date) throws(HikeIntentFailure) -> HikeTotalsReport {
        let descriptor = FetchDescriptor<Hike>(
            predicate: #Predicate { hike in
                !hike.isRecording && hike.date >= start && hike.date < end
            }
        )
        let hikes = try fetch(descriptor)
        return HikeTotalsReport(
            hikeCount: hikes.count,
            distance: Measurement(
                value: hikes.reduce(0) { $0 + $1.distanceMeters },
                unit: .meters
            )
        )
    }

    /// Today, by the walker's own calendar and the injected clock.
    func totalsForToday() throws(HikeIntentFailure) -> HikeTotalsReport {
        try totals(forDayContaining: clock())
    }

    /// A context per query rather than one held for the coordinator's life:
    /// these are read-only fetches minutes or days apart, and a long-lived
    /// context would keep serving whatever it had registered the last time an
    /// intent ran — including hikes deleted since.
    private func fetch(
        _ descriptor: FetchDescriptor<Hike>
    ) throws(HikeIntentFailure) -> [Hike] {
        do {
            return try ModelContext(container).fetch(descriptor)
        } catch {
            // Logged rather than carried into the failure: SwiftData's message
            // is written for a developer, and everything a `HikeIntentFailure`
            // holds is read out loud.
            Self.logger.error("Reading hikes for an intent failed: \(error.localizedDescription, privacy: .public)")
            throw .storage
        }
    }

    /// Reads the elapsed clock off the route's own end stamps rather than
    /// through ``Hike/routeStatistics``.
    ///
    /// That property is documented at its declaration as deriving every
    /// statistic "from scratch, on the calling thread, on every read", and
    /// this coordinator is `@MainActor` — so a saved multi-hour hike, which is
    /// thousands of points, would run a full accumulator pass on the main
    /// actor inside an intent that has a system execution budget. Both report
    /// paths reach here, and one of them lands immediately after a save.
    ///
    /// The answer is the same one: `HikeRouteStatistics` takes its duration
    /// between the first and last *stamped* points, which is what these two
    /// searches find, and calls it `nil` unless the clock actually ran.
    private static func report(for hike: Hike) -> FinishedHikeReport {
        let route = hike.route
        let first = route.first { $0.timestamp != nil }?.timestamp
        let last = route.last { $0.timestamp != nil }?.timestamp
        let duration: TimeInterval? = if let first, let last, last > first {
            last.timeIntervalSince(first)
        } else {
            nil
        }
        return FinishedHikeReport(
            id: hike.id,
            title: hike.displayTitle,
            date: hike.date,
            distance: hike.distance,
            duration: duration
        )
    }
}
