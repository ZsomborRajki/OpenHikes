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
    @ObservationIgnored private var lastPersistedAt: Date?

    /// - Parameters:
    ///   - context: where the sidecar column and the finished rows are
    ///     written. The container's main context in the app; a suite passes
    ///     the context its fixtures live in.
    ///   - tracker: the widget and Lock Screen feed, pinned to the walked
    ///     hike for the life of a walk. Optional so a suite about the state
    ///     machine alone needs no App Group.
    init(
        context: ModelContext,
        tracker: BackgroundTrailTracker? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        activeRecordingHikeID: @escaping () -> UUID? = { nil }
    ) {
        self.context = context
        self.tracker = tracker
        self.clock = clock
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
    func recordForegroundMatch(hike: Hike, profile: RouteProfile, distance: Double) {
        let now = clock()
        endIfAbandoned(at: now)
        if record == nil {
            startIfEligible(hike: hike, profile: profile, at: now)
        }
        recordMatch(hikeID: hike.id, distance: distance, at: now)
    }

    /// A fix matched on-route by the background feed. Never starts a walk —
    /// selection alone starts nothing, and neither does a significant
    /// change — but keeps one accruing while the phone is in a pocket.
    func recordBackgroundMatch(hikeID: UUID, distance: Double, at timestamp: Date) {
        endIfAbandoned(at: clock())
        recordMatch(hikeID: hikeID, distance: distance, at: timestamp)
    }

    /// Ends a walk that has gone unmatched for ``TrailWalkPolicy/abandonAfter``.
    /// Called on every fix and on every return to the foreground, which is
    /// as often as anything here runs — there is no timer.
    func endIfAbandoned(at now: Date? = nil) {
        guard let record, record.isAbandoned(at: now ?? clock()) else { return }
        finish(reason: .abandoned, at: now ?? clock())
    }

    private func recordMatch(hikeID: UUID, distance: Double, at now: Date) {
        guard var current = record, current.hikeID == hikeID else { return }
        current.lastMatchedAt = now
        guard current.phase == .following else {
            // Seen, so the walk is not abandoned — but not walked.
            record = current
            return
        }
        current.coverage.record(distance: distance)
        record = current
        let fraction = current.coveredFraction
        if coveredFraction != fraction { coveredFraction = fraction }
        let furthest = current.coverage.furthestDistanceMeters
        if furthestDistanceMeters != furthest { furthestDistanceMeters = furthest }
        if current.reachesEnd(atMatch: distance) {
            finish(reason: .reachedEnd, at: now)
            return
        }
        persistIfDue(at: now)
    }

    // MARK: Start

    /// Whether `hike` may start a walk right now: nothing else is being
    /// walked, following is on, and this is not a recording's own draft.
    func canStart(_ hike: Hike) -> Bool {
        record == nil
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
        guard !enabled, let record, record.hikeID == hikeID, record.phase == .following else { return false }
        pause()
        return true
    }

    private func publishState() {
        guard let record else { return }
        tracker?.walkStateDidChange(Self.payload(for: record, at: clock()), hikeID: record.hikeID)
    }

    // MARK: End

    /// The walker tapped End. Returns the row it became, or `nil` for a walk
    /// under the minimum, which is simply cleared.
    @discardableResult func end() -> HikeWalk? {
        finish(reason: .ended, at: clock())
    }

    /// Forgets the walk along a hike that is being deleted. No row: the host
    /// is going, and a walk has to hang off one.
    func discardWalk(forDeletedHike hikeID: UUID) {
        guard let record, record.hikeID == hikeID else { return }
        clearState()
        tracker?.walkDidEnd(final: nil)
    }

    @discardableResult private func finish(reason: TrailWalkEndReason, at now: Date) -> HikeWalk? {
        guard let closing = record else { return nil }
        let kept = closing.coverage.meetsMinimum
        var row: HikeWalk?
        if kept, let hike = walkedHike, hike.isAttached {
            let walk = HikeWalk(closing: closing, at: now, reason: reason)
            context.insert(walk)
            walk.hike = hike
            row = walk
        }
        // The row and the cleared column land in one save.
        walkedHike?.walkInProgress = nil
        save(reason: "ending a walk")
        RenderSignpost.mark("TrailWalkEnded", reason.rawValue)
        let lingers = kept && reason != .abandoned
        let final = lingers ? Self.payload(for: closing, at: now, state: .finished) : nil
        clearState()
        if lingers { lastEndedWalk = row }
        tracker?.walkDidEnd(final: final)
        return row
    }

    private func clearState() {
        record = nil
        walkedHike = nil
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

    private func save(reason: String) {
        do {
            try context.save()
        } catch {
            let description = error.localizedDescription
            Self.logger.error("Could not save while \(reason, privacy: .public): \(description, privacy: .public)")
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
