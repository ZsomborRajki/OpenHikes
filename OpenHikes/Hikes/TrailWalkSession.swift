//
//  TrailWalkSession.swift
//  OpenHikes
//
//  The walk in progress: the one place a walk is started, fed, paused,
//  ended and written down.
//
//  Following a trail used to answer one question — *where am I on this trail
//  right now* — and forget the answer. This is what remembers it. A walk
//  begins on the first matched fix with Auto-Follow Trail on, keeps the
//  union of along-route intervals its consecutive matches spanned, can be
//  paused and resumed, and ends into a `HikeWalk` row the History segment
//  lists. It outlives the screen that started it: popping the detail,
//  opening another trail, or starting a recording changes nothing here.
//
//  One `@Observable` reference type, read by the leaves and never by
//  `HikeDetailView.body`, with its properties split by rate. `walkedHikeID`,
//  `phase` and `walkedHikeTitle` change on a tap; `coveredFraction` and
//  `furthestDistanceMeters` change per matched fix. The controls and the
//  sheet's row read the first group, the progress row reads the second, and
//  `TrailWalkIsolationTests` is what keeps a fix-rate write from reaching a
//  body that only wanted the phase.
//
//  The record itself is `@ObservationIgnored`: it is the thing that changes
//  most and the thing no body draws. It is written to the sidecar at
//  milestones and at most at the widget feed's cadence, never per fix.
//

import Foundation
import Observation
import OpenHikesShared
import os
import SwiftData

/// What ending a walk came to.
///
/// Three answers rather than an optional row, because the third one is not a
/// missing row: a store that refuses the commit leaves the walk *under way*,
/// and a caller that could not tell it from a walk too short to keep would
/// take the controls off screen for a walk that is still running.
enum TrailWalkEnd {
    /// The walk ended with nothing to keep — under
    /// ``TrailWalkPolicy/minimumCoverageMeters``, or along a hike that has
    /// gone away — or there was no walk to end.
    case discarded
    /// The walk ended and became this row.
    case kept(HikeWalk)
    /// The store refused the commit. Nothing was cleared and nothing was
    /// written: the walk is still under way and can be ended again.
    case refused
}

extension TrailWalkEnd {
    /// The row the walk became, if it became one. For a caller that has
    /// nothing to say about a refusal; the one that does switches instead.
    var walk: HikeWalk? {
        guard case let .kept(walk) = self else { return nil }
        return walk
    }
}

@MainActor
@Observable
final class TrailWalkSession {
    private static let logger = Logger(subsystem: "OpenHikes", category: "TrailWalk")

    // MARK: Coarse — changes on a tap

    /// The hike being walked, or `nil` when nothing is.
    private(set) var walkedHikeID: UUID?
    /// Its name, for the notice another trail's detail shows while this one
    /// holds the walk.
    private(set) var walkedHikeTitle: String = ""
    private(set) var phase: TrailWalkPhase?
    /// The walk that just ended with a record to show, for the screen that
    /// pushes its summary. Cleared by the next start.
    private(set) var lastEndedWalk: HikeWalk?

    // MARK: Fine — changes per matched fix

    private(set) var coveredFraction: Double = 0
    private(set) var furthestDistanceMeters: Double = 0

    // MARK: Storage

    @ObservationIgnored private(set) var record: TrailWalkRecord?
    @ObservationIgnored private var walkedHike: Hike?
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let tracker: BackgroundTrailTracker?
    @ObservationIgnored private let clock: @Sendable () -> Date
    /// The recorder's answer to "which hike is the active draft", so a
    /// recording's own row never gets a walk. A closure rather than the
    /// recorder because the recorder is the single authority on that and
    /// this must not become a second one.
    @ObservationIgnored private let activeRecordingHikeID: () -> UUID?
    @ObservationIgnored private let commit: (ModelContext) throws -> Void
    @ObservationIgnored private var lastPersistedAt: Date?
    /// The hike whose walk was ended here, held until the walker leaves its
    /// route or turns following on again.
    ///
    /// Without it End is not an end: the next accepted on-route fix finds no
    /// record, starts a fresh walk, and the controls come straight back —
    /// most visibly for a walk under 100 m, where End returns nothing and
    /// the detail is still on screen. Cleared by ``recordOffRoute(hikeID:)``
    /// and by turning Auto-Follow Trail back on, which are the two ways a
    /// walker says they mean to walk this trail again.
    @ObservationIgnored private var endedHikeID: UUID?

    /// - Parameters:
    ///   - context: where the sidecar column and the finished rows are
    ///     written. The container's main context in the app; a suite passes
    ///     the context its fixtures live in.
    ///   - tracker: the widget and Lock Screen feed, pinned to the walked
    ///     hike for the life of a walk. Optional so a suite about the state
    ///     machine alone needs no App Group.
    ///   - save: the seam the commit goes through, so a test can refuse one
    ///     and watch what the session does with a walk it could not write.
    ///     The same seam ``HikeDeletion/delete(_:store:save:)`` takes. Last,
    ///     so `activeRecordingHikeID` stays the trailing closure it was.
    init(
        context: ModelContext,
        tracker: BackgroundTrailTracker? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        activeRecordingHikeID: @escaping () -> UUID? = { nil },
        save: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.context = context
        self.tracker = tracker
        self.clock = clock
        commit = save
        self.activeRecordingHikeID = activeRecordingHikeID
        tracker?.walkSession = self
    }

    // MARK: Questions

    /// Whether `hikeID` is the walk under way.
    func isWalking(_ hikeID: UUID) -> Bool { walkedHikeID == hikeID }

    /// Whether the feeds should publish a fix for `hikeID`: yes for a hike
    /// with no walk, yes for a walk that is following, no for one that is
    /// paused — the widget already says so and a moving dot would contradict it.
    func publishes(hikeID: UUID) -> Bool {
        guard let record, record.hikeID == hikeID else { return true }
        return record.phase == .following
    }

    /// The walk's figures for the widget and the Lock Screen, or `nil` when
    /// `hikeID` is not being walked.
    func payload(for hikeID: UUID, state: SharedTrailSnapshot.Walk.State? = nil) -> SharedTrailSnapshot.Walk? {
        guard let record, record.hikeID == hikeID else { return nil }
        return Self.payload(for: record, at: clock(), state: state)
    }

    /// The walk's clock, minus its pauses, read now. Not observable — the
    /// readout that draws it ticks on its own timer.
    func activeSeconds() -> TimeInterval {
        record?.activeSeconds(at: clock()) ?? 0
    }

    // MARK: Feeding

    /// A fix matched on-route at `distance` along `hike`, from the foreground
    /// follow loop. Starts a walk if one may start, extends the one under
    /// way, or does nothing for a hike that is not the walked one.
    ///
    /// - Returns: whether this fix *ended* the walk. A caller that publishes
    ///   the fix afterwards must not: see ``recordMatch(hikeID:distance:at:)``.
    @discardableResult func recordForegroundMatch(hike: Hike, profile: RouteProfile, distance: Double) -> Bool {
        let now = clock()
        endIfAbandoned(at: now)
        if record == nil {
            startIfEligible(hike: hike, profile: profile, at: now)
        }
        return recordMatch(hikeID: hike.id, distance: distance, at: now)
    }

    /// A fix matched on-route by the background feed. Never starts a walk —
    /// selection alone starts nothing, and neither does a significant
    /// change — but keeps one accruing while the phone is in a pocket.
    ///
    /// - Returns: whether this fix ended the walk, as above.
    @discardableResult func recordBackgroundMatch(hikeID: UUID, distance: Double, at timestamp: Date) -> Bool {
        endIfAbandoned(at: clock())
        return recordMatch(hikeID: hikeID, distance: distance, at: timestamp)
    }

    /// An accepted fix that did not match `hikeID`'s route: the walker is
    /// off the trail. Rearms auto-start for a hike whose walk was ended
    /// here — leaving the route is the boundary an End waits for.
    func recordOffRoute(hikeID: UUID) {
        rearmStart(hikeID: hikeID)
    }

    /// Lets `hikeID` start a walk again after one was ended along it.
    private func rearmStart(hikeID: UUID) {
        guard endedHikeID == hikeID else { return }
        endedHikeID = nil
    }

    /// Ends a walk that has gone unmatched for ``TrailWalkPolicy/abandonAfter``.
    /// Called on every fix and on every return to the foreground, which is
    /// as often as anything here runs — there is no timer.
    func endIfAbandoned(at now: Date? = nil) {
        guard let record, record.isAbandoned(at: now ?? clock()) else { return }
        finish(reason: .abandoned, at: now ?? clock())
    }

    /// - Returns: whether the match closed the walk. Both callers publish the
    ///   fix they just fed in, and a fix that completed a walk must not be
    ///   published: with the record cleared, `publishes(_:)` says yes and
    ///   `payload(for:)` says nothing, so the write would start a fresh plain
    ///   follow over the finished panel ``walkDidEnd(final:)`` just queued.
    @discardableResult private func recordMatch(hikeID: UUID, distance: Double, at now: Date) -> Bool {
        guard var current = record, current.hikeID == hikeID else { return false }
        current.lastMatchedAt = now
        guard current.phase == .following else {
            // Seen, so the walk is not abandoned — but not walked.
            record = current
            return false
        }
        current.coverage.record(distance: distance)
        record = current
        let fraction = current.coveredFraction
        if coveredFraction != fraction { coveredFraction = fraction }
        let furthest = current.coverage.furthestDistanceMeters
        if furthestDistanceMeters != furthest { furthestDistanceMeters = furthest }
        if current.reachesEnd(atMatch: distance) {
            // A refused commit leaves the walk under way, and the fix that
            // fed it is an ordinary one again.
            if case .refused = finish(reason: .reachedEnd, at: now) { return false }
            return true
        }
        persistIfDue(at: now)
        return false
    }

    // MARK: Start

    /// Whether `hike` may start a walk right now: nothing else is being
    /// walked, the last walk along it has not just been ended, following is
    /// on, and this is not a recording's own draft.
    func canStart(_ hike: Hike) -> Bool {
        record == nil
            && endedHikeID != hike.id
            && hike.autoFollowEnabled
            && hike.isAttached
            && !hike.belongsToActiveRecording(currentHikeID: activeRecordingHikeID())
    }

    private func startIfEligible(hike: Hike, profile: RouteProfile, at now: Date) {
        guard canStart(hike), profile.totalDistanceMeters > 0 else { return }
        let started = TrailWalkRecord(
            hikeID: hike.id,
            routeDistanceMeters: profile.totalDistanceMeters,
            startedAt: now
        )
        adopt(started, hike: hike)
        RenderSignpost.mark("TrailWalkStarted")
        persist(at: now)
        tracker?.walkDidStart(hikeID: hike.id)
    }

    private func adopt(_ walk: TrailWalkRecord, hike: Hike) {
        record = walk
        walkedHike = hike
        endedHikeID = nil
        lastEndedWalk = nil
        walkedHikeID = hike.id
        walkedHikeTitle = hike.displayTitle
        phase = walk.phase
        coveredFraction = walk.coveredFraction
        furthestDistanceMeters = walk.coverage.furthestDistanceMeters
    }

    // MARK: Pause and resume

    func pause() {
        let now = clock()
        guard var current = record, current.phase == .following else { return }
        current.pause(at: now)
        record = current
        phase = .paused
        RenderSignpost.mark("TrailWalkPhase", "paused")
        persist(at: now)
        publishState()
    }

    func resume() {
        let now = clock()
        guard var current = record, current.phase == .paused else { return }
        current.resume(at: now)
        current.lastMatchedAt = now
        record = current
        phase = .following
        // A resumed walk with following off would accrue nothing, silently.
        walkedHike?.autoFollowEnabled = true
        RenderSignpost.mark("TrailWalkPhase", "following")
        persist(at: now)
        publishState()
    }

    /// Turning Auto-Follow Trail off for the walked hike is the one
    /// non-button gesture that pauses: it is the walker saying *stop
    /// following*. Returns whether a walk was paused by it, so the caller
    /// knows the Lock Screen is saying Paused rather than coming down.
    @discardableResult func autoFollowDidChange(hikeID: UUID, enabled: Bool) -> Bool {
        guard !enabled else {
            // Turning it back on is the walker asking to follow this trail
            // again — the other way an End's boundary is rearmed.
            rearmStart(hikeID: hikeID)
            return false
        }
        guard let record, record.hikeID == hikeID, record.phase == .following else { return false }
        pause()
        return true
    }

    private func publishState() {
        guard let record else { return }
        tracker?.walkStateDidChange(Self.payload(for: record, at: clock()), hikeID: record.hikeID)
    }

    // MARK: End

    /// The walker tapped End. Returns the row it became, a walk under the
    /// minimum that was simply cleared, or a commit the store refused — see
    /// ``TrailWalkEnd``.
    @discardableResult func end() -> TrailWalkEnd {
        finish(reason: .ended, at: clock())
    }

    /// Forgets the walk along a hike that is being deleted. No row: the host
    /// is going, and a walk has to hang off one.
    func discardWalk(forDeletedHike hikeID: UUID) {
        guard let record, record.hikeID == hikeID else { return }
        clearState()
        tracker?.walkDidEnd(final: nil)
    }

    /// Closes the walk under way and writes what it came to.
    ///
    /// The commit is the whole of it. Nothing here is cleared, published or
    /// handed back until the store has accepted the row and the cleared
    /// column together: on a refusal the inserted row and the cleared
    /// sidecar exist only as pending edits, and a process that exits there
    /// would find a sidecar still describing an open walk with the row gone.
    /// So a refusal rolls the context back and leaves the walk exactly as it
    /// was — the same refusal ``HikeDeletion`` and ``HikeRecorder`` make, and
    /// the caller either says so or tries again on the next fix.
    @discardableResult private func finish(reason: TrailWalkEndReason, at now: Date) -> TrailWalkEnd {
        guard let closing = record else { return .discarded }
        // An abandonment is noticed long after it happened — six hours later
        // at best, and at the next launch for a walk found stale — so `now` is
        // when nobody was walking any more, not when the walk ended.
        // ``TrailWalkRecord/lastActivityAt`` is the end: the last moment the
        // walk was known to be on the route, and what both abandonment rules
        // are already measured from. Closing at `now` banked the idle hours as
        // active time, which is what the History row and the summary's "Active
        // Time" then said — a four-minute walk swept at the next day's launch
        // read as twenty-four hours. The other two reasons end when they say.
        let endedAt = reason == .abandoned ? closing.lastActivityAt : now
        let kept = closing.coverage.meetsMinimum
        var row: HikeWalk?
        if kept, let hike = walkedHike, hike.isAttached {
            let walk = HikeWalk(closing: closing, at: endedAt, reason: reason)
            context.insert(walk)
            walk.hike = hike
            row = walk
        }
        // The row and the cleared column land in one save.
        walkedHike?.walkInProgress = nil
        guard save(reason: "ending a walk") else {
            // Put both edits back by hand rather than through
            // `ModelContext.rollback()`, which does not do the second one:
            // measured in ``StoredTileDeletion``, a rolled-back context still
            // holds an attribute written over an existing row. Undoing the
            // row by hand as well keeps the pair symmetrical and leaves every
            // other pending edit in the context alone.
            if let row {
                row.hike = nil
                context.delete(row)
            }
            walkedHike?.walkInProgress = closing
            // The column on disk is whatever the last accepted write left, so
            // the next milestone has to write again rather than wait out the
            // cadence.
            lastPersistedAt = nil
            return .refused
        }
        RenderSignpost.mark("TrailWalkEnded", reason.rawValue)
        let lingers = row != nil && reason != .abandoned
        let final = lingers ? Self.payload(for: closing, at: endedAt, state: .finished) : nil
        let endedID = closing.hikeID
        clearState()
        // After `clearState`, which clears it: an ended walk is exactly what
        // has to stop the next matched fix from starting another one.
        if reason != .abandoned { endedHikeID = endedID }
        if lingers { lastEndedWalk = row }
        tracker?.walkDidEnd(final: final)
        return row.map { .kept($0) } ?? .discarded
    }

    private func clearState() {
        record = nil
        walkedHike = nil
        endedHikeID = nil
        lastPersistedAt = nil
        walkedHikeID = nil
        walkedHikeTitle = ""
        phase = nil
        coveredFraction = 0
        furthestDistanceMeters = 0
    }

    // MARK: Launch

    /// Adopts a walk left open by the previous launch, or closes it as
    /// abandoned when it is too old to be the same walk — see
    /// ``OpenHikesModel/openWalkAtLaunch(now:fetchingLocalStates:)`` for the
    /// rule and for why a fetch that fails closes nothing.
    ///
    /// Called from the model's own init rather than from the root view's
    /// launch task, unlike the other sweeps: a background relaunch never
    /// shows a view, and a fix that arrives in one has to find the walk it
    /// belongs to.
    func restoreAtLaunch(now launch: Date? = nil) {
        let now = launch ?? clock()
        switch OpenHikesModel.openWalkAtLaunch(now: now, fetchingLocalStates: {
            try context.fetch(FetchDescriptor<HikeLocalState>())
        }) {
        case .absent, .unreadable:
            return
        case let .abandon(state, stale):
            guard let hike = fetchHike(stale.hikeID) else {
                state.walkInProgress = nil
                save(reason: "clearing an orphaned walk")
                return
            }
            adopt(stale, hike: hike)
            finish(reason: .abandoned, at: now)
        case let .resume(_, open):
            guard let hike = fetchHike(open.hikeID) else { return }
            adopt(open, hike: hike)
            tracker?.walkDidStart(hikeID: hike.id)
        }
    }

    private func fetchHike(_ id: UUID) -> Hike? {
        try? context.fetch(FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })).first
    }

    // MARK: Persistence

    private func persistIfDue(at now: Date) {
        if let lastPersistedAt, now.timeIntervalSince(lastPersistedAt) < TrailWalkPolicy.persistInterval {
            return
        }
        persist(at: now)
    }

    private func persist(at now: Date) {
        guard let record, let walkedHike, walkedHike.isAttached else { return }
        walkedHike.walkInProgress = record
        lastPersistedAt = now
        RenderSignpost.mark("TrailWalkPersisted")
        save(reason: "writing the walk in progress")
    }

    /// - Returns: whether the store accepted it. Only ``finish(reason:at:)``
    ///   reads the answer: a sidecar write that fails is written again at the
    ///   next milestone, and a walk that ends is the one commit with nothing
    ///   behind it to try again.
    @discardableResult private func save(reason: String) -> Bool {
        do {
            try commit(context)
            return true
        } catch {
            let description = error.localizedDescription
            Self.logger.error("Could not save while \(reason, privacy: .public): \(description, privacy: .public)")
            return false
        }
    }

    private static func payload(
        for record: TrailWalkRecord,
        at now: Date,
        state: SharedTrailSnapshot.Walk.State? = nil
    ) -> SharedTrailSnapshot.Walk {
        SharedTrailSnapshot.Walk(
            state: state ?? (record.phase == .paused ? .paused : .active),
            coveredFraction: record.coveredFraction,
            furthestDistanceMeters: record.coverage.furthestDistanceMeters,
            activeSeconds: record.activeSeconds(at: now),
            startedAt: record.startedAt
        )
    }
}
