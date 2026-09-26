//
//  WatchWalkImport.swift
//  OpenHikes
//
//  A walk recorded on the watch, becoming a hike here.
//
//  ## Why this is an import and not a recording
//
//  Because by the time it reaches this phone it *is* a finished track, and the
//  app already knows what to do with one of those. `HikeRecorder` owns a
//  recording in progress: a live trace, a durable journal, crash recovery,
//  barometric fusion, a trail matcher and a review step for the legs the
//  matcher moved. None of that applies to a walk that ended an hour ago on
//  another device — there is nothing live to trace, no journal to recover, and
//  no matcher decision left for a hiker to review. What arrives is a route
//  with timestamps, which is exactly what ``HikeImport`` turns a GPX file into,
//  and this follows it deliberately: the same off-main write, the same commit
//  before anything is told there is a hike, the same refusal to hand back a
//  row that the store would not keep.
//
//  ## Arriving twice is ordinary
//
//  `transferUserInfo` guarantees delivery and says nothing about how many
//  times. A receipt lost on the way back to the watch leaves it holding a walk
//  it will offer again on the next connection, which is the behaviour that
//  makes the queue safe — so this has to recognise the second arrival rather
//  than merely hope for one. ``HikeLocalState/watchSessionID`` is the ledger,
//  and ``existingHike(for:in:ledger:)`` is the check; a repeat costs one
//  fetch and sends another receipt. A check that could not be made is not a
//  check that found nothing: the walk is refused, and stays on the watch.
//
//  ## Whose figures win
//
//  The track's. The watch sends its own totals because they are what the hiker
//  was shown while walking, but the route is what this app measures everything
//  else from, and two numbers for one walk is how a hike comes to disagree
//  with its own elevation chart. So the distance is recomputed here the way
//  every other hike's is, and the watch's figure is used for nothing but the
//  log line that would explain a discrepancy.
//

import Algorithms
import Foundation
import OpenHikesData
import OpenHikesShared
import os
import SwiftData

/// Why a walk from the watch did not become a hike.
enum WatchWalkImportFailure: LocalizedError, Equatable, Sendable {
    /// The store refused the write. Carries no diagnostic, for the reason
    /// ``HikeImportFailure/notSaved`` carries none.
    case notSaved
    /// Fewer than two fixes: a place rather than a walk. The watch refuses to
    /// send one of these, so this is the belt to that braces.
    case tooShort

    var errorDescription: String? {
        switch self {
        case .notSaved: "This hike couldn't be saved."
        case .tooShort: "That walk was too short to keep."
        }
    }
}

/// What one arrival did.
enum WatchWalkImportOutcome: Equatable, Sendable {
    /// Already here, from an earlier arrival of the same recording.
    case alreadyImported(UUID)
    /// Saved now.
    case imported(UUID)
    case refused(WatchWalkImportFailure)

    /// Whether the watch should be told it can let this walk go.
    ///
    /// True for both of the first two, which is the point: a walk this phone
    /// already has is a walk the watch is done with, and withholding the
    /// receipt would leave it offering the same transfer forever.
    var deservesReceipt: Bool {
        switch self {
        case .alreadyImported, .imported: true
        case .refused: false
        }
    }
}

nonisolated enum WatchWalkImport {
    private static let logger = Logger(subsystem: "OpenHikes", category: "WatchWalk")

    /// Saves a walk from the watch, or says why it did not.
    ///
    /// - Parameter save: the seam the commit goes through, so a suite can
    ///   refuse it — the same shape ``HikeImport/hike(from:into:save:)`` takes
    ///   its own. There is no sequence of taps that makes a store say no, and
    ///   this is the one failure whose whole point is what it does *not* leave
    ///   behind: an unsaved walk must keep its place on the watch's queue.
    /// - Parameter ledger: the two reads that decide whether this walk is
    ///   already here, as a seam for the same reason — see ``Ledger``.
    @concurrent
    static func store(
        _ walk: WatchRecordedWalk,
        in container: ModelContainer,
        ledger: Ledger = .store,
        save: @Sendable (ModelContext) throws -> Void = { try $0.save() }
    ) async -> WatchWalkImportOutcome {
        assertOffMainThread("Serializing a watch recording must stay off the main thread")
        guard walk.isWorthKeeping else { return .refused(.tooShort) }

        let context = ModelContext(container)
        let existing: UUID?
        do {
            existing = try existingHike(for: walk.sessionID, in: context, ledger: ledger)
        } catch {
            // Not the same answer as "no match": a read that failed says
            // nothing about whether this walk is already a hike, and saving it
            // anyway is how a redelivery becomes a duplicate. Refused, so the
            // watch keeps it and offers it again.
            logger.error(
                """
                Could not check whether a walk from the watch was already saved: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            return .refused(.notSaved)
        }
        if let existing {
            logger.debug("A walk from the watch arrived again and is already saved")
            return .alreadyImported(existing)
        }

        let route = walk.fixes.map { fix in
            RouteCoordinate(
                latitude: fix.latitude,
                longitude: fix.longitude,
                elevation: fix.elevationMeters,
                timestamp: fix.timestamp,
                // A pause is the hiker's own decision to stop recording, so
                // the ground either side of it is not a lost signal. Carried
                // across from the watch as the boundary it already is on the
                // phone, which is what lets the map, the elevation profile and
                // the GPX export each decline to draw a line through it.
                boundary: fix.resumesAfterPause ? .paused : nil
            )
        }
        let measured = measuredDistance(of: route)
        let hike = Hike(
            title: HikeTitle.watchRecording(trailName: walk.title, recordedAt: walk.startedAt),
            distanceMeters: measured,
            date: walk.startedAt,
            tintHex: Hike.randomTintHex(),
            route: route
        )
        context.insert(hike)
        // Written *after* the insert, because a device-local passthrough is a
        // silent no-op on a row with no `modelContext` — the same trap
        // `Fixture.hike(in:configure:)` is shaped around.
        hike.watchSessionID = walk.sessionID
        do {
            try save(context)
        } catch {
            logger.error(
                """
                A walk from the watch could not be saved: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            return .refused(.notSaved)
        }
        logger.debug(
            """
            Kept a walk from the watch: \
            \(Int(measured), privacy: .public) m measured against \
            \(Int(walk.distanceMeters), privacy: .public) m reported
            """
        )
        return .imported(hike.id)
    }

    /// The hike an earlier arrival of this recording became, if there was one.
    ///
    /// Throws rather than answering `nil` when either read fails, because the
    /// caller does something irreversible with `nil`: it inserts a new hike.
    /// The sidecar can outlive its hike for as long as a delete is in flight,
    /// so the row is resolved back to a real hike rather than trusted.
    private static func existingHike(
        for sessionID: UUID,
        in context: ModelContext,
        ledger: Ledger
    ) throws -> UUID? {
        guard let hikeID = try ledger.recordedHikeID(sessionID, context) else { return nil }
        return try ledger.hikeExists(hikeID, context) ? hikeID : nil
    }

    /// The two reads behind ``existingHike(for:in:ledger:)``.
    ///
    /// A seam for the reason `save` is one: nothing makes a `ModelContext`
    /// throw on demand, and the failing read is the branch whose whole point
    /// is what it does *not* do — insert a second copy of a walk this phone
    /// may already have.
    nonisolated struct Ledger: Sendable {
        /// The hike the sidecar says a session became, if it says one did.
        ///
        /// A fetch on ``HikeLocalState`` rather than on `Hike`, because that
        /// is where the fact lives — see ``HikeLocalState/watchSessionID``.
        var recordedHikeID: @Sendable (_ sessionID: UUID, ModelContext) throws -> UUID?
        /// Whether a hike with this id is still in the store.
        var hikeExists: @Sendable (_ hikeID: UUID, ModelContext) throws -> Bool

        static let store = Self(
            recordedHikeID: { sessionID, context in
                var descriptor = FetchDescriptor<HikeLocalState>(
                    predicate: #Predicate { $0.watchSessionID == sessionID }
                )
                descriptor.fetchLimit = 1
                return try context.fetch(descriptor).first?.hikeID
            },
            hikeExists: { hikeID, context in
                var descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.id == hikeID })
                descriptor.fetchLimit = 1
                return try context.fetchCount(descriptor) > 0
            }
        )
    }

    /// The walk's length, summed along the saved line.
    ///
    /// Recomputed rather than taken from the watch, for the reason in this
    /// file's header — and skipping the legs a pause opened, which is the same
    /// rule the recorder's own preparation keeps: a hiker who paused at a
    /// saddle and resumed at the hut did not walk the straight line between
    /// them.
    private static func measuredDistance(of route: [RouteCoordinate]) -> Double {
        var total = 0.0
        for (previous, point) in route.adjacentPairs() where point.boundary != .paused {
            total += RouteGeometry.distanceMeters(from: previous.clCoordinate, to: point.clCoordinate)
        }
        return total
    }
}
