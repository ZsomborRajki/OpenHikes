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
import SwiftData

@MainActor
final class HikeIntentCoordinator {
    private let recorder: HikeRecorder
    private let container: ModelContainer
    private let calendar: Calendar
    private let clock: @Sendable () -> Date

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
    /// Whether Core Location has been asked yet.
    ///
    /// Read by the intents *before* starting rather than inferred from a
    /// failure afterwards: `HikeRecorder.start()` answers `.notDetermined` by
    /// putting up the system prompt and waiting, which from a background intent
    /// is a recording that silently never begins.
    var authorization: HikeIntentAuthorization {
        switch recorder.source.authorization {
        case .authorized: .granted
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

    func pauseRecording() throws(HikeIntentFailure) -> LiveRecordingReport {
        guard recorder.phase == .waitingForFix || recorder.phase == .recording else {
            throw .noActiveRecording
        }
        recorder.pause()
        try throwIfRecorderFailed()
        return liveReport()
    }

    func resumeRecording() async throws(HikeIntentFailure) -> LiveRecordingReport {
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
            throw .storage(error.localizedDescription)
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
    func currentRecording() throws(HikeIntentFailure) -> LiveRecordingReport {
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
            trailName: recorder.stats.currentTrail?.name
        )
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
            // is not a state the walker can be told anything useful about.
            throw .storage("That day couldn't be worked out.")
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
            throw .storage(error.localizedDescription)
        }
    }

    private static func report(for hike: Hike) -> FinishedHikeReport {
        FinishedHikeReport(
            id: hike.id,
            title: hike.displayTitle,
            date: hike.date,
            distance: hike.distance,
            duration: hike.routeStatistics.duration
        )
    }
}
