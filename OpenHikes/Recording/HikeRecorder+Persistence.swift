//
//  HikeRecorder+Persistence.swift
//  OpenHikes
//
//  Persistence, session lifecycle, and failure/reset helpers for
//  HikeRecorder, split out to keep HikeRecorder+Helpers.swift under the
//  file-length limit.
//

import CoreLocation
import Foundation
import Observation
import OpenHikesData
import OpenHikesShared
import os
import SwiftData

// MARK: - Save Preparation & Persistence

extension HikeRecorder {

    // MARK: Save preparation

    /// Everything the save writes, worked out off the main actor — see
    /// ``RecordingPreparation/forSave(points:startedAt:graph:gapDistances:)``.
    func prepareForSave(
        _ session: TrackJournalSession
    ) async throws(RecordingFailure) -> PreparedRecording {
        guard session.metadata.endedAt != nil else { throw .save(String(
            localized: "The recording has not been finished yet."
        )) }

        let (normalized, graph, gapEvidence) = await normalizeSession(session)
        // `forSave` is typed `throws(RecordingFailure)` and `@concurrent`
        // preserves that, so the failure propagates as itself — no re-catch,
        // no `localizedDescription` round-trip through `any Error`.
        let prepared = try await RecordingPreparation.forSave(
            points: normalized,
            startedAt: session.metadata.startedAt,
            graph: graph,
            gapDistances: gapEvidence
        )
        Self.logger.debug(
            """
            Prepared recording: points=\(normalized.count, privacy: .public) \
            graph=\(graph != nil, privacy: .public) \
            matched=\(prepared.matchResult != nil, privacy: .public) \
            checks=\(prepared.assembly?.checks.count ?? 0, privacy: .public)
            """
        )
        return prepared
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
        // The name the stop alert showed, when the hiker was shown one — see
        // ``HikeRecorder/stop(customName:offeredTitle:)``. Otherwise — Siri,
        // the watch, a recovered walk — measured against the prepared distance
        // rather than the live one: this is the last word on how long the
        // walk was, and the share the floor is applied to should be a share
        // of it. Its shape is the prepared route's for the same reason, read
        // off the main thread when it was prepared.
        let suggestedTitle = offeredTitle ?? suggestedTitle(
            forDistance: prepared.distanceMeters,
            shape: prepared.shape,
            startedAt: prepared.startedAt
        )
        if let existing = try existingHike(sessionID: hikeID) {
            guard existing.isRecording else { return existing }
            let finalized = try finalizeDraft(
                existing,
                session: session,
                prepared: prepared,
                customName: customName,
                suggestedTitle: suggestedTitle
            )
            exportToHealth(finalized, session: session, prepared: prepared)
            return finalized
        }

        let hike = Hike(
            title: session.metadata.title
                ?? suggestedTitle
                ?? Self.defaultTitle(for: prepared.startedAt),
            distanceMeters: prepared.distanceMeters,
            id: hikeID,
            date: prepared.startedAt,
            tintHex: Hike.randomTintHex(),
            route: prepared.route,
            rawRoute: prepared.rawRoute,
            isRecording: false
        )
        hike.customName = customName
        hike.routeEdit = Self.routeEdit(of: prepared)
        container.mainContext.insert(hike)
        let walk = insertRecordedWalk(
            for: hike,
            session: session,
            prepared: prepared
        )
        do {
            try saveModelContext(container.mainContext)
            exportToHealth(hike, session: session, prepared: prepared)
            return hike
        } catch {
            discardRecordedWalk(walk)
            container.mainContext.delete(hike)
            throw .save(error.localizedDescription)
        }
    }

    /// Writes the hike to Health, if the hiker asked for that.
    ///
    /// **After** the save, and only after a successful one: Health is a second
    /// store and it must never hold a walk this app does not. Fire-and-forget
    /// because the hiker is waiting for their hike to appear and a Health
    /// round trip is not something to make them wait on — and because there is
    /// nothing to report. A failed write can still leave something in Health,
    /// and unlike a file written outside SwiftData nothing can sweep for it,
    /// because Health cannot be read. So its owner is filed first:
    /// ``HikeWorkoutExport/write(_:with:filingInto:)`` marks the hike before
    /// Health hears anything, and the hike's deletion takes back whatever the
    /// write left, by the hike's own identifier.
    ///
    /// The ascent and descent come off the accumulator rather than from the
    /// saved line: they are barometrically fused where the device had a
    /// barometer, and re-deriving them from route altitudes would be a second
    /// opinion that could only disagree with the figures the hike itself
    /// shows. The weather is read here, at save, and only kept if it is
    /// about this walk — see ``HikeWorkoutWeather``.
    ///
    /// The workout ends when the hiker pressed Stop, and its pauses come off
    /// the saved line — see ``HikeWorkoutPauses`` for why not off the
    /// journal's own pause list.
    private func exportToHealth(
        _ hike: Hike,
        session: TrackJournalSession,
        prepared: PreparedRecording
    ) {
        guard let workoutWriter, HikeWorkoutExport.isEnabled(in: defaults) else { return }
        let endedAt = HikeWorkoutPauses.end(
            stoppedAt: session.metadata.endedAt,
            startedAt: prepared.startedAt,
            route: prepared.route
        )
        let request = HikeWorkoutRequest(
            hikeID: hike.id,
            startedAt: prepared.startedAt,
            endedAt: endedAt,
            pauses: HikeWorkoutPauses.pauses(in: prepared.route, from: prepared.startedAt, to: endedAt),
            distanceMeters: prepared.distanceMeters,
            elevationGainMeters: accumulator.elevationGainMeters,
            elevationLossMeters: accumulator.elevationLossMeters,
            weather: HikeWorkoutWeather(
                state: weatherState(),
                walkFrom: prepared.startedAt,
                to: endedAt
            ),
            route: prepared.route
        )
        workoutQueue.enqueue(for: hike.id) { [container] in
            await HikeWorkoutExport.write(request, with: workoutWriter, filingInto: container)
        }
    }

    /// Finishes the draft this recording has been writing into, in the one
    /// commit that also writes the walk it was.
    ///
    /// Every field it touches is read back first, because a refused save has
    /// to leave a draft that is still recordable — see the rollback below and
    /// ``aRefusedSaveLeavesNoWalk``. A half-finalized draft is worse than a
    /// failed save: it is a hike the recorder no longer owns and the hiker
    /// cannot finish.
    private func finalizeDraft(
        _ existing: Hike,
        session: TrackJournalSession,
        prepared: PreparedRecording,
        customName: String?,
        suggestedTitle: String?
    ) throws(RecordingFailure) -> Hike {
        let previousDistance = existing.distanceMeters
        let previousDate = existing.date
        let previousRoute = existing.route
        let previousRawRoute = existing.rawRoute
        let previousCustomName = existing.customName
        let previousTitle = existing.title
        let previousEdit = existing.routeEditData

        existing.distanceMeters = prepared.distanceMeters
        existing.date = prepared.startedAt
        existing.replaceRoute(with: prepared.route)
        existing.rawRoute = prepared.rawRoute
        existing.routeEdit = Self.routeEdit(of: prepared)
        existing.customName = customName
        // The draft was named for the time of day before the first fix
        // arrived, because that was all there was to go on. Replaced here
        // rather than while the walk was running: the draft is a mirrored row
        // and it is what the Live Activity draws, so a name that changed
        // every time one trail overtook another would be a CloudKit export
        // per flip and a Lock Screen renaming itself under the hiker.
        //
        // Into `title` and never `customName`. `customName` is the name a
        // person typed and `displayTitle` prefers it, so a hiker who typed
        // one in the stop alert keeps it — what is replaced here is only ever
        // a default this app chose for them.
        if let suggestedTitle { existing.title = suggestedTitle }
        existing.isRecording = false
        // The walk this recording was, in the same commit as the hike it
        // finalizes — see ``RecordedWalk``.
        let walk = insertRecordedWalk(
            for: existing,
            session: session,
            prepared: prepared
        )
        do {
            try saveModelContext(container.mainContext)
            return existing
        } catch {
            discardRecordedWalk(walk)
            existing.distanceMeters = previousDistance
            existing.date = previousDate
            existing.replaceRoute(with: previousRoute)
            existing.rawRoute = previousRawRoute
            existing.routeEditData = previousEdit
            existing.customName = previousCustomName
            existing.title = previousTitle
            existing.isRecording = true
            throw .save(error.localizedDescription)
        }
    }

    /// What a recording keeps about its line beside the line: the stretches
    /// trail matching left a question on, and the ends that were not walked.
    /// `nil` for a walk with neither, which keeps no column.
    private static func routeEdit(of prepared: PreparedRecording) -> RouteEdit? {
        let edit = RouteEdit(assembly: prepared.assembly, notOnFoot: prepared.notOnFoot)
        return edit.isEmpty ? nil : edit
    }

    /// Saves a stopped recording, at once.
    ///
    /// A recording trail matching had moved, bridged or found ambiguous used
    /// to stop here in a review, and was a hike only once the hiker had
    /// answered for every such stretch. It is saved now with each stretch at
    /// its default and the questions kept on the hike — see
    /// ``RouteAssembly`` — so Stop finishes wherever it is pressed: on a
    /// screen, by Siri, from the watch.
    func finishPreparedSession(
        _ session: TrackJournalSession,
        journal: TrackJournal,
        customName: String? = nil
    ) async throws(RecordingFailure) -> Hike {
        if let existing = try existingHike(
            sessionID: session.metadata.sessionID
        ), !existing.isRecording {
            await finishSavedSession(session, journal: journal)
            return existing
        }

        let pending = PendingPreparedSave(
            session: session,
            prepared: try await prepareForSave(session),
            customName: customName
        )
        pendingPreparedSave = pending
        let hike = try persist(
            session,
            prepared: pending.prepared,
            customName: pending.customName
        )
        await finishSavedSession(session, journal: journal)
        return hike
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

    func finishSavedSession(
        _ session: TrackJournalSession,
        journal: TrackJournal
    ) async {
        // First, before anything here suspends: once `resetSession()` lets go
        // of the draft, nothing else stops a fix from starting a walk on it.
        recordingDidSave?(session.metadata.sessionID)
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
        resetAutoPause()
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
        // final panel claims one that was saved. A hiker who retries and
        // succeeds is looking at the app, not at the Lock Screen. Harmless
        // where no recording panel is up — `endRecordingActivity(_:)` checks —
        // so a followed trail's activity is left where it is.
        endRecordingActivity(.abandoned)
    }

    func resetSession() {
        cancelTrailGraphPrefetches()
        phase = .idle
        recoveryState = .absent
        sessionStartedAt = nil
        fixWindow = nil
        currentHike = nil
        pendingPreparedSave = nil
        sessionID = nil
        sessionUptimeBase = nil
        lastAcceptedPoint = nil
        recentFixes.removeAll()
        accumulator = RecordingDistanceAccumulator()
        elevationFilter.reset()
        latestMotionState = .unknown
        resetAutoPause()
        autoPause.refresh?.cancel()
        autoPause.refresh = nil
        startRequested = false
        activationID = nil
        carriedSeed = nil
        pendingResumeFlag = false
        acceptedFixRevision = 0
        liveMatchWindow = []
        trailNames = RecordingTrailNames()
        startPlaceName = nil
        hasAskedForStartPlace = false
        offeredTitle = nil
        liveMatchingTask?.cancel()
        liveMatchingTask = nil
        liveMatchingTaskID = nil
        liveMatchNeedsRun = false
        journalFlushTask?.cancel()
        journalFlushTask = nil
        pendingFixMergeTask?.cancel()
        pendingFixMergeTask = nil
        lastSharedSnapshotAt = nil
        lastSharedSnapshotPointCount = 0
        stats.reset()
        trace.reset()
    }

    // MARK: Default titles

    nonisolated private static let afternoonEndHour = 17
    nonisolated private static let eveningEndHour = 22

    nonisolated static func defaultTitle(
        for date: Date,
        calendar: Calendar = .current
    ) -> String {
        let timeOfDay: String
        switch calendar.component(.hour, from: date) {
        case 5..<12: timeOfDay = String(localized: "Morning Hike")
        case 12..<Self.afternoonEndHour: timeOfDay = String(localized: "Afternoon Hike")
        case Self.afternoonEndHour..<Self.eveningEndHour: timeOfDay = String(localized: "Evening Hike")
        default: timeOfDay = String(localized: "Hike")
        }
        // The shape every offered name has, with the time of day where the
        // town and the trail would be — see ``RecordingTitle``.
        return timeOfDay + RecordingTitle.separator + RecordingTitle.day(date, calendar: calendar)
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
        sessionID = id
        sessionStartedAt = startedAt
        fixWindow = RecordingFixWindow(opensAt: startedAt)
        sessionUptimeBase = uptime()
        cancelLiveMatching(clearWindow: true)
        stats.reset()
        trace.reset()
        accumulator = RecordingDistanceAccumulator()
        elevationFilter.reset()
        latestMotionState = .unknown
        resetAutoPause()
        lastAcceptedPoint = nil
        recentFixes.removeAll()
        pendingPreparedSave = nil
        pendingResumeFlag = false
        recoveryState = .absent
        startElevationUpdates()
        startMotionUpdates()
        source.startRecordingUpdates(profile: resolvedEnergyProfile())
        phase = .waitingForFix
        publishSharedRecordingSnapshot(force: true)
    }

    /// The name the hiker typed into the Stop alert, as it should be stored.
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
