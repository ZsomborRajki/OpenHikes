//
//  HikeRecorder+Persistence.swift
//  OpenHikes
//
//  Persistence, route review, session lifecycle, and failure/reset helpers
//  for HikeRecorder, split out to keep HikeRecorder+Helpers.swift under the
//  file-length limit.
//

import CoreLocation
import Foundation
import Observation
import os
import SwiftData

// MARK: - Save Preparation & Persistence

extension HikeRecorder {

    // MARK: Save preparation

    func prepareForSave(
        _ session: TrackJournalSession,
        customName: String? = nil
    ) async throws(RecordingFailure) -> (
        prepared: PreparedRecording,
        review: PendingReviewSave?
    ) {
        guard session.metadata.endedAt != nil else { throw .save("The recording has not been finished yet.") }

        let (normalized, graph, gapEvidence) = await normalizeSession(session)
        // `prepareOffMain` is typed `throws(RecordingFailure)` and `@concurrent`
        // preserves that, so the failure propagates as itself — no re-catch,
        // no `localizedDescription` round-trip through `any Error`.
        let prepared = try await RecordingPreparation.prepareOffMain(
            points: normalized,
            startedAt: session.metadata.startedAt,
            graph: graph,
            gapDistances: gapEvidence
        )

        let sections = await groupedSections(in: prepared.matchResult)
        Self.logger.debug(
            """
            Prepared recording: points=\(normalized.count, privacy: .public) \
            graph=\(graph != nil, privacy: .public) \
            matched=\(prepared.matchResult != nil, privacy: .public) \
            sections=\(sections.count, privacy: .public)
            """
        )

        let review: PendingReviewSave?
        if graph != nil,
           let matchResult = prepared.matchResult,
           !sections.isEmpty {
            review = PendingReviewSave(
                session: session,
                normalizedPoints: normalized,
                matchResult: matchResult,
                customName: customName,
                sections: sections
            )
        } else {
            review = nil
        }
        return (prepared, review)
    }

    /// Grouping walks every leg, so it joins the rest of the save pipeline off
    /// the main thread rather than running at stop time on the UI.
    private func groupedSections(
        in matchResult: TrailMatchResult?
    ) async -> [RouteReviewSection] {
        guard let matchResult else { return [] }
        return await RouteReviewSection.sectionsOffMain(in: matchResult)
    }

    func normalizeSession(
        _ session: TrackJournalSession
    ) async -> (        normalized: [RecordingPoint],
        graph: TrailGraph?,
        gapEvidence: [Int: Double]
    ) {
        let normalized = await RecordingPreparation
            .normalizedPointsOffMain(session.points)
        let graph = await trailGraph(covering: normalized)
        let gapEvidence = await gapDistances(for: normalized)
        return (normalized, graph, gapEvidence)
    }

    /// The trail graph this recording is matched against.
    ///
    /// A finished recording is the one moment where reaching the network for a
    /// graph earns its cost. Prefetching during the walk can only name regions
    /// a fix arrived in, so the stretches that lost their fixes — the ones
    /// that most need a mapped route to be reconstructed from — are precisely
    /// the ones no region was ever requested for. Left at the cached graph,
    /// the matcher arrives at the gap with nothing to route through and draws
    /// a straight line.
    ///
    /// Bounded on both sides: nothing is downloaded for a recording without
    /// gaps, and the download as a whole is abandoned after
    /// ``gapGraphDownloadBudget`` so a stop on a dead connection isn't held
    /// open by per-region timeouts. Whatever landed inside the budget is used
    /// and the rest of the route keeps its GPS geometry, which is the same
    /// partial answer this pipeline gives everywhere else.
    private func trailGraph(
        covering points: [RecordingPoint]
    ) async -> TrailGraph? {
        guard let trailGraphProvider else { return nil }
        let corridor = TrailGraphCorridor.coordinates(bridging: points)
        if !corridor.isEmpty {
            await downloadTrailGraph(
                corridor: corridor,
                provider: trailGraphProvider
            )
        }
        do {
            return try await trailGraphProvider.cachedGraph(
                covering: points.map(\.coordinate) + corridor
            )
        } catch {
            Self.logger.error(
                "Cached trail graph could not be loaded: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private func downloadTrailGraph(
        corridor: [CLLocationCoordinate2D],
        provider: any TrailGraphProviding
    ) async {
        guard trailGraphNetworkDecision(.interactive).isAllowed else { return }
        let coordinates = TrailGraphCorridor.prefetchCoordinates(
            for: corridor,
            provider: provider
        )
        guard !coordinates.isEmpty else { return }
        Self.logger.debug(
            "Downloading \(coordinates.count, privacy: .public) trail graph region(s) to close recording gaps"
        )
        let budget = Self.gapGraphDownloadBudget
        // A race rather than a per-request timeout: the budget covers the
        // whole run, so eight regions that each take three seconds still fit
        // while one region on a dead connection cannot consume it alone.
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await Task.sleep(for: budget)
            }
            group.addTask {
                for coordinate in coordinates {
                    guard !Task.isCancelled else { return }
                    try? await provider.prefetch(around: coordinate)
                }
            }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: Persistence

    func persist(
        _ session: TrackJournalSession,
        prepared: PreparedRecording,
        customName: String? = nil
    ) throws(RecordingFailure) -> Hike {
        let hikeID = session.metadata.sessionID
        stats.dominantTrailName = prepared.matchedTrailName
        if let existing = try existingHike(sessionID: hikeID) {
            guard existing.isRecording else { return existing }

            let previousDistance = existing.distanceMeters
            let previousDate = existing.date
            let previousRoute = existing.route
            let previousRawRoute = existing.rawRoute
            let previousCustomName = existing.customName

            existing.distanceMeters = prepared.distanceMeters
            existing.date = prepared.startedAt
            existing.route = prepared.route
            existing.rawRoute = prepared.rawRoute
            existing.customName = customName
            existing.isRecording = false
            do {
                try saveModelContext(container.mainContext)
                return existing
            } catch {
                existing.distanceMeters = previousDistance
                existing.date = previousDate
                existing.route = previousRoute
                existing.rawRoute = previousRawRoute
                existing.customName = previousCustomName
                existing.isRecording = true
                throw .save(error.localizedDescription)
            }
        }

        let hike = Hike(
            title: session.metadata.title ?? Self.defaultTitle(for: prepared.startedAt),
            distanceMeters: prepared.distanceMeters,
            id: hikeID,
            date: prepared.startedAt,
            tintHex: Hike.randomTintHex(),
            route: prepared.route,
            rawRoute: prepared.rawRoute,
            isRecording: false
        )
        hike.customName = customName
        container.mainContext.insert(hike)
        do {
            try saveModelContext(container.mainContext)
            return hike
        } catch {
            container.mainContext.delete(hike)
            throw .save(error.localizedDescription)
        }
    }

    func ensureRecordingHike(
        sessionID: UUID,
        startedAt: Date,
        title: String?
    ) throws(RecordingFailure) -> Hike {
        if let existing = try existingHike(sessionID: sessionID) {
            if existing.isRecording {
                currentHike = existing
            }
            return existing
        }

        let hike = Hike(
            title: title ?? Self.defaultTitle(for: startedAt),
            distanceMeters: 0,
            id: sessionID,
            date: startedAt,
            tintHex: Hike.randomTintHex(),
            route: [],
            isRecording: true
        )
        container.mainContext.insert(hike)
        do {
            try saveModelContext(container.mainContext)
            currentHike = hike
            return hike
        } catch {
            container.mainContext.delete(hike)
            throw .save(error.localizedDescription)
        }
    }

    func deleteRecordingHike(sessionID: UUID?) throws(RecordingFailure) {
        guard let sessionID,
              let hike = try existingHike(sessionID: sessionID),
              hike.isRecording else { return }
        // A discarded draft is deleted the same way a saved hike is, sidecar
        // and photo files included — see `HikeDeletion`. A recording draft is
        // not an empty one on either count: the camera attaches photos to it
        // while the walk is on, and `AutoSaveController` folds browsing tiles
        // into whichever hike is active, which for the length of a walk is
        // this draft.
        do {
            try HikeDeletion.delete([hike], store: photoStore, save: saveModelContext)
        } catch {
            throw .save(error.localizedDescription)
        }
    }

    func deleteOrphanedRecordingHikes(
        except sessionID: UUID? = nil
    ) throws(RecordingFailure) {
        let descriptor = FetchDescriptor<Hike>(
            predicate: #Predicate { $0.isRecording }
        )
        let drafts: [Hike]
        do {
            drafts = try container.mainContext.fetch(descriptor)
        } catch {
            throw .save(error.localizedDescription)
        }
        let orphans = drafts.filter { $0.id != sessionID }
        guard !orphans.isEmpty else { return }

        if let currentHike,
           orphans.contains(where: { $0.id == currentHike.id }) {
            self.currentHike = nil
        }
        // One commit for the whole sweep, and — as in
        // `deleteRecordingHike(sessionID:)` — nothing erased until it lands.
        // An orphan has had a whole walk to accumulate photos and auto-saved
        // tile keys before the launch that abandoned it.
        do {
            try HikeDeletion.delete(orphans, store: photoStore, save: saveModelContext)
        } catch {
            throw .save(error.localizedDescription)
        }
    }

    func finishPreparedSession(
        _ session: TrackJournalSession,
        journal: TrackJournal,
        customName: String? = nil
    ) async throws(RecordingFailure) -> RecordingStopOutcome {
        if let existing = try existingHike(
            sessionID: session.metadata.sessionID
        ), !existing.isRecording {
            await finishSavedSession(session, journal: journal)
            return .saved(existing)
        }

        let result = try await prepareForSave(
            session,
            customName: customName
        )
        if let pending = result.review {
            pendingPreparedSave = nil
            pendingReviewSave = pending
            routeReview = RecordingRouteReview(sections: pending.sections)
            phase = .reviewing
            updateReviewPreview()
            publishSharedRecordingSnapshot(force: true)
            return .needsReview
        }

        let pending = PendingPreparedSave(
            session: session,
            prepared: result.prepared,
            customName: customName
        )
        pendingPreparedSave = pending
        pendingReviewSave = nil
        let hike = try persist(
            session,
            prepared: pending.prepared,
            customName: pending.customName
        )
        await finishSavedSession(session, journal: journal)
        return .saved(hike)
    }

    func existingHike(sessionID: UUID) throws(RecordingFailure) -> Hike? {
        let descriptor = FetchDescriptor<Hike>(
            predicate: #Predicate { $0.id == sessionID }
        )
        do {
            return try container.mainContext.fetch(descriptor).first
        } catch {
            throw .save(error.localizedDescription)
        }
    }

    // MARK: Route review

    /// Rebuilds the previewed route from the current per-section choices and
    /// publishes it.
    ///
    /// The resolution walks every leg of the whole recording, so it is
    /// proportional to the length of the hike rather than to the section being
    /// looked at — which is why it does not run on the main actor even though
    /// it is triggered by a tap. Superseded rather than queued: a hiker
    /// scrubbing through sections issues one of these per tap, and an older
    /// answer arriving after a newer one would draw the wrong section.
    func updateReviewPreview() {
        guard let pendingReviewSave, let routeReview else { return }
        let request = ReviewPreviewRequest(
            matchResult: pendingReviewSave.matchResult,
            legChoices: routeReview.legChoices,
            section: routeReview.current,
            sectionChoice: routeReview.current.map(routeReview.choice(for:))
        )

        reviewPreviewTask?.cancel()
        let taskID = UUID()
        reviewPreviewTask = Task { [weak self] in
            let preview = await Self.resolveReviewPreview(request)
            guard let self, !Task.isCancelled else { return }
            trace.showReview(
                route: preview.route,
                highlightedSegment: preview.highlightedSegment
            )
            if reviewPreviewTaskID == taskID { reviewPreviewTask = nil }
        }
        reviewPreviewTaskID = taskID
    }

    func cancelReviewPreview() {
        reviewPreviewTask?.cancel()
        reviewPreviewTask = nil
        reviewPreviewTaskID = nil
    }

    nonisolated struct ReviewPreviewRequest: Sendable {
        let matchResult: TrailMatchResult
        let legChoices: [Int: TrailRouteChoice]
        let section: RouteReviewSection?
        let sectionChoice: TrailRouteChoice?
    }

    nonisolated struct ReviewPreview: Sendable {
        let route: [CLLocationCoordinate2D]
        let highlightedSegment: [CLLocationCoordinate2D]
    }

    /// `@concurrent` rather than a detached task, for the same reason
    /// ``RouteReviewSection/sectionsOffMain(in:)`` is: the work stays in the
    /// caller's task, so cancelling the tap cancels this, and it runs at the
    /// tap's own priority rather than at a default one.
    @concurrent
    nonisolated static func resolveReviewPreview(
        _ request: ReviewPreviewRequest
    ) async -> ReviewPreview {
        assertOffMainThread(
            "Review preview resolution must stay off the main thread"
        )
        let route = request.matchResult
            .points(resolving: request.legChoices)
            .map(\.coordinate)
        let highlighted: [CLLocationCoordinate2D]
        if let section = request.section, let choice = request.sectionChoice {
            highlighted = section.points(for: choice).map(\.coordinate)
        } else {
            highlighted = []
        }
        return ReviewPreview(route: route, highlightedSegment: highlighted)
    }

    func finishSavedSession(
        _ session: TrackJournalSession,
        journal: TrackJournal
    ) async {
        endRecordingActivity(.finished)
        await clearSharedRecordingState(
            sessionID: session.metadata.sessionID
        )
        do {
            try await journal.discard()
        } catch {
            Self.logger.error(
                "Saved hike but could not remove its finished journal: \(error.localizedDescription, privacy: .public)"
            )
        }
        resetSession()
    }

    // MARK: Failure / reset

    func fail(
        _ failure: RecordingFailure,
        endLocationUpdates: Bool = true
    ) {
        cancelLiveMatching(clearWindow: false)
        cancelTrailGraphPrefetches()
        endFieldRecordingSpan()
        if endLocationUpdates {
            stopLocationSensors()
        }
        journalFlushTask?.cancel()
        journalFlushTask = nil
        phase = .failed(failure)
        startRequested = false
        if sessionID != nil {
            publishSharedRecordingSnapshot(force: true)
        }
        // Unconditionally, from every one of its call sites, because no
        // failure leaves a recording still taking fixes. The flag
        // `endLocationUpdates: false` does not mean "it carries on" — it means
        // the sensors are already off or were never started: `stop()` and
        // `discard()` stop them first, and the activation and recovery paths
        // fail before `initializeSessionState(id:startedAt:)` starts them. So
        // the last state the panel holds says `isCapturingFixes: false`, which
        // it draws as *Paused*, and nothing publishes again to correct it: the
        // panel goes on saying the walk is waiting for the hiker until the
        // system's stale date makes it merely look old, and then goes on
        // saying it.
        //
        // `.abandoned` rather than `.finished` even where `canRetrySave` is
        // true: no `Hike` stands behind those figures yet, and a lingering
        // final panel claims one that was saved. A walker who retries and
        // succeeds is looking at the app, not at the Lock Screen. Harmless
        // where no recording panel is up — `endRecordingActivity(_:)` checks —
        // so a followed trail's activity is left where it is.
        endRecordingActivity(.abandoned)
    }

    func resetSession() {
        cancelTrailGraphPrefetches()
        endFieldRecordingSpan()
        phase = .idle
        recoveryState = .absent
        sessionStartedAt = nil
        currentHike = nil
        routeReview = nil
        pendingReviewSave = nil
        pendingPreparedSave = nil
        sessionID = nil
        sessionUptimeBase = nil
        lastAcceptedPoint = nil
        accumulator = RecordingDistanceAccumulator()
        elevationFilter.reset()
        latestMotionState = .unknown
        startRequested = false
        isActivating = false
        pendingResumeFlag = false
        acceptedFixRevision = 0
        liveMatchWindow = []
        liveMatchingTask?.cancel()
        liveMatchingTask = nil
        liveMatchingTaskID = nil
        liveMatchNeedsRun = false
        cancelReviewPreview()
        journalFlushTask?.cancel()
        journalFlushTask = nil
        pendingFixMergeTask?.cancel()
        pendingFixMergeTask = nil
        lastSharedSnapshotAt = nil
        lastSharedSnapshotPointCount = 0
        stats.reset()
        trace.reset()
    }

    // MARK: Default title

    nonisolated private static let afternoonEndHour = 17
    nonisolated private static let eveningEndHour = 22

    nonisolated static func defaultTitle(
        for date: Date,
        calendar: Calendar = .current
    ) -> String {
        let timeOfDay: String
        switch calendar.component(.hour, from: date) {
        case 5..<12: timeOfDay = "Morning Hike"
        case 12..<Self.afternoonEndHour: timeOfDay = "Afternoon Hike"
        case Self.afternoonEndHour..<Self.eveningEndHour: timeOfDay = "Evening Hike"
        default: timeOfDay = "Hike"
        }

        // `Date.FormatStyle` rather than `DateFormatter`: the old formatter is
        // an `NSObject` that had to be built and configured on every call, and
        // this runs once per saved recording. A format style is a `Sendable`
        // value, which is also what lets this stay `nonisolated` without
        // parking a shared mutable formatter somewhere.
        //
        // `.abbreviated` is `DateFormatter`'s `.medium`. Locale and time zone
        // stay at the system's, as they were.
        let dateText = date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .omitted, calendar: calendar)
        )
        return "\(timeOfDay) – \(dateText)"
    }

    // MARK: Session lifecycle helpers

    func cleanUpMissingSession() async {
        do {
            try deleteOrphanedRecordingHikes()
        } catch {
            fail(error, endLocationUpdates: false)
            return
        }
        endRecordingActivity(.abandoned)
        await clearSharedRecordingState(sessionID: nil)
        phase = .idle
    }

    func initializeSessionState(id: UUID, startedAt: Date) {
        cancelTrailGraphPrefetches()
        beginFieldRecordingSpan()
        sessionID = id
        sessionStartedAt = startedAt
        sessionUptimeBase = uptime()
        cancelLiveMatching(clearWindow: true)
        stats.reset()
        trace.reset()
        accumulator = RecordingDistanceAccumulator()
        elevationFilter.reset()
        latestMotionState = .unknown
        lastAcceptedPoint = nil
        pendingReviewSave = nil
        pendingPreparedSave = nil
        pendingResumeFlag = false
        recoveryState = .absent
        startElevationUpdates()
        startMotionUpdates()
        source.startRecordingUpdates(profile: resolvedEnergyProfile())
        phase = .waitingForFix
        publishSharedRecordingSnapshot(force: true)
    }

    /// The name the walker typed into the Stop alert, as it should be stored.
    ///
    /// Its own name rather than a bare ``HikeTitle/bounded(_:)`` call because
    /// this is the recorder's vocabulary and `RecordingView` reasons about it
    /// by that name — but the rule itself lives in one place, so the alert's
    /// field and the rename field cannot drift apart.
    nonisolated static func normalizedCustomName(
        _ customName: String?
    ) -> String? {
        HikeTitle.bounded(customName)
    }
}
