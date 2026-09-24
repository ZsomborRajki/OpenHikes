//
//  TrailWalkSession.swift
//  OpenHikes
//
//  The walk in progress: the one place a walk is started, fed, paused,
//  ended and written down.
//
//  Following a trail used to answer one question — *where am I on this trail
//  right now* — and forget the answer. This is what remembers it. A walk
//  begins on the first matched fix with Follow This Trail on, or on the
//  detail's Start — ``start(hike:profile:)`` — and keeps the union of along-route intervals its consecutive matches spanned, can be
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
//  milestones and at the widget feed's cadence, with one prompt retry after
//  a failure before returning to the cadence for persistent failures.
//

import Foundation
import Observation
import OpenHikesShared
import os
import SwiftData

/// That a walk started without being asked to, and on which trail.
///
/// The title is taken when the walk starts rather than looked up when the pill
/// draws, so the pill reads nothing of the hike and a rename mid-walk does not
/// redraw it.
struct TrailWalkStartNotice: Equatable {
    let hikeID: UUID
    let title: String
}

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
    /// A walk a matched fix just started, for the pill on the map that says
    /// so — see ``WalkStartedPill``. Cleared by its *x* and by the walk
    /// ending; a walk adopted at launch was already announced and sets none.
    private(set) var startNotice: TrailWalkStartNotice?

    // MARK: Fine — changes per matched fix

    private(set) var coveredFraction: Double = 0
    private(set) var furthestDistanceMeters: Double = 0

    // MARK: Storage

    @ObservationIgnored private(set) var record: TrailWalkRecord?
    @ObservationIgnored private var walkedHike: Hike?
    /// The walked route's distance and height index, for the time left —
    /// see ``secondsLeft(at:)``. Taken from whichever foreground match or
    /// Start hands one in, so a walk adopted at launch has none until the
    /// detail's follow loop supplies it.
    @ObservationIgnored private(set) var walkedProfile: RouteProfile?
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let tracker: BackgroundTrailTracker?
    @ObservationIgnored private let clock: @Sendable () -> Date
    /// The recorder's answer to "which hike is the active draft", so a
    /// recording's own row never gets a walk. A closure rather than the
    /// recorder because the recorder is the single authority on that and
    /// this must not become a second one.
    @ObservationIgnored private let activeRecordingHikeID: () -> UUID?
    /// The reminder a paused walk can produce, when the app has one.
    ///
    /// The same instance the recorder holds, which is what makes "a recording
    /// outranks a followed trail" expressible here as well — see
    /// ``MovementReminderController``. Optional so a suite about the state
    /// machine alone reaches no notification centre.
    @ObservationIgnored let reminders: MovementReminderController?
    @ObservationIgnored private let commit: (ModelContext) throws -> Void
    /// Today's light where the hiker is, for the after-dark warning — see
    /// ``DuskWatch``. A closure for the reason ``activeRecordingHikeID`` is
    /// one: the weather manager is the single authority on the reading.
    @ObservationIgnored let daylight: () -> WeatherDaylight?
    @ObservationIgnored private var lastPersistedAt: Date?
    @ObservationIgnored private var lastPersistenceAttemptAt: Date?
    /// Capped at two: the first failure gets one prompt retry, then attempts
    /// wait for the regular cadence until a write succeeds.
    @ObservationIgnored private var persistenceFailures = 0
    /// The hike whose walk was ended here, held until the hiker leaves its
    /// route or turns following on again.
    ///
    /// Without it End is not an end: the next accepted on-route fix finds no
    /// record, starts a fresh walk, and the controls come straight back —
    /// most visibly for a walk under 100 m, where End returns nothing and
    /// the detail is still on screen. Cleared by ``recordOffRoute(hikeID:)``
    /// and by turning Follow This Trail back on, which are the two ways a
    /// hiker says they mean to walk this trail again.
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
        reminders: MovementReminderController? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        activeRecordingHikeID: @escaping () -> UUID? = { nil },
        daylight: @escaping () -> WeatherDaylight? = { nil },
        save: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.context = context
        self.tracker = tracker
        self.reminders = reminders
        self.clock = clock
        commit = save
        self.activeRecordingHikeID = activeRecordingHikeID
        self.daylight = daylight
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

    /// Whether the walk along `hikeID` was ended here and nothing has yet
    /// said the hiker means to walk it again.
    ///
    /// The same boundary ``canStart(_:)`` refuses to start a second walk on,
    /// asked by the feeds rather than by the start path. An End leaves its
    /// closing figures on the Lock Screen for
    /// ``HikeLiveActivityController/finishedDismissAfter``, and the fixes
    /// that keep arriving along the same trail carry no walk — so without
    /// this they read as an ordinary follow and put a second panel beside a
    /// result that was deliberately left up. Cleared by the same two gestures
    /// that rearm the start, which is what makes a genuinely new walk's
    /// activity start normally.
    func hasEndedWalk(hikeID: UUID) -> Bool { endedHikeID == hikeID }

    /// The walk's figures for the widget and the Lock Screen, or `nil` when
    /// `hikeID` is not being walked.
    func payload(for hikeID: UUID, state: SharedTrailSnapshot.Walk.State? = nil) -> SharedTrailSnapshot.Walk? {
        guard let record, record.hikeID == hikeID else { return nil }
        let now = clock()
        return Self.payload(for: record, at: now, state: state, secondsLeft: secondsLeft(at: now))
    }

    /// The walk's clock, minus its pauses, read now. Not observable — the
    /// readout that draws it ticks on its own timer.
    func activeSeconds() -> TimeInterval {
        record?.activeSeconds(at: clock()) ?? 0
    }

    /// The time left, read now — see ``secondsLeft(at:)``.
    func secondsLeft() -> TimeInterval? {
        secondsLeft(at: clock())
    }

    // MARK: Feeding

    /// A fix matched on-route at `distance` along `hike`, from the foreground
    /// follow loop. Starts a walk if one may start, extends the one under
    /// way, or does nothing for a hike that is not the walked one.
    ///
    /// - Returns: whether this fix *ended* the walk. A caller that publishes
    ///   the fix afterwards must not: see ``recordMatch(hikeID:distance:at:)``.
    ///
    /// - Parameter timestamp: when the receiver *took* the fix, which is not
    ///   when the follow loop got round to it. A fix as much as
    ///   ``LocationFixPolicy/foregroundMaximumAge`` old is accepted for
    ///   matching, and stamping one of those with the delivery time is what
    ///   makes half-minute-old evidence look newer than a fix that really is
    ///   — which is the whole of what orders this feed against the background
    ///   one. `nil` for a caller with no fix time to hand, where the clock is
    ///   the honest answer.
    @discardableResult func recordForegroundMatch(
        hike: Hike,
        profile: RouteProfile,
        distance: Double,
        at timestamp: Date? = nil
    ) -> Bool {
        let now = clock()
        let matchedAt = timestamp ?? now
        discardWalkIfHikeGone()
        // Asked of the clock rather than of the fix: whether anything has been
        // seen for six hours is a question about now, and a walk must not
        // outlive its bound because the fix that closed it was taken early.
        endIfAbandoned(at: now)
        if record == nil {
            startIfEligible(hike: hike, profile: profile, at: matchedAt)
        }
        if record?.hikeID == hike.id { walkedProfile = profile }
        return recordMatch(hikeID: hike.id, distance: distance, at: matchedAt)
    }

    /// A fix matched on-route by the background feed. Never starts a walk —
    /// selection alone starts nothing, and neither does a significant
    /// change — but keeps one accruing while the phone is in a pocket.
    ///
    /// - Returns: whether this fix ended the walk, as above.
    @discardableResult func recordBackgroundMatch(hikeID: UUID, distance: Double, at timestamp: Date) -> Bool {
        discardWalkIfHikeGone()
        endIfAbandoned(at: clock())
        return recordMatch(hikeID: hikeID, distance: distance, at: timestamp)
    }

    /// An accepted fix that did not match `hikeID`'s route: the hiker is
    /// off the trail. Breaks the walk under way's coverage continuity, and
    /// rearms auto-start for a hike whose walk was ended here — leaving the
    /// route is the boundary an End waits for.
    func recordOffRoute(hikeID: UUID) {
        breakCoverage(hikeID: hikeID)
        rearmStart(hikeID: hikeID)
    }

    /// How far an accepted fix fell from the route, whether or not it matched.
    ///
    /// Fed by both feeds — the foreground poll and the significant-change
    /// deliveries that carry on in a pocket — and forwarded only while a walk
    /// is actually *following*. A paused walk's hiker is somewhere else on
    /// purpose, and a walk that has ended is not a trail anybody is on.
    ///
    /// Separate from ``recordOffRoute(hikeID:)`` rather than folded into it,
    /// because that one is about coverage continuity and fires only when a
    /// fix failed to match. This one wants every fix, including the ones that
    /// matched — being *back* on the line is what re-arms the reminder.
    func recordRouteDistance(hikeID: UUID, offRouteMeters: Double?, at date: Date) {
        guard let record, record.hikeID == hikeID, record.phase == .following else { return }
        reminders?.walkObserved(
            offRouteMeters: offRouteMeters,
            trailTitle: walkedHikeTitle,
            at: date
        )
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
        // A fix something newer has already overtaken says nothing that has
        // not been said better since, and it is not this walk's most recent
        // news whatever order it arrived in. Rejected before the record is
        // touched, because both things it would do are wrong: it would move
        // the walk's last-seen time backwards, and — while paused — offer a
        // stretch of trail the hiker covered *before* they stopped as
        // evidence that they have set off again.
        //
        // Not a hypothetical ordering. ``BackgroundTrailTracker`` matches off
        // the main thread behind an await, so a fix taken earlier can be
        // handed over later than a foreground one; a significant-change
        // delivery is routinely a cached fix from where the hiker set off;
        // and serialising the background feed against itself orders it
        // against nothing else.
        guard now >= current.lastActivityAt else { return false }
        current.lastMatchedAt = now
        guard current.phase == .following else {
            // Seen, so the walk is not abandoned — but not walked. Still
            // offered to the sidecar: a paused walk accrues nothing of its
            // own, so these fixes are the only thing that can carry a write
            // the store refused earlier, and the cadence keeps them cheap.
            record = current
            if current.phase == .paused {
                reminders?.walkObserved(distanceAlongRoute: distance, at: now)
            }
            persistIfDue(at: now)
            return false
        }
        current.coverage.record(distance: distance)
        // The walk's *position*, kept beside the coverage union rather than
        // derived from it: the union's maximum is where the walk has been,
        // and a pause has to be anchored at where the hiker is. See
        // ``TrailWalkRecord/lastFollowedDistanceMeters``.
        current.lastFollowedDistanceMeters = distance
        record = current
        let fraction = current.coveredFraction
        if coveredFraction != fraction { coveredFraction = fraction }
        let furthest = current.coverage.furthestDistanceMeters
        if furthestDistanceMeters != furthest { furthestDistanceMeters = furthest }
        estimateFinish(at: now)
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
        walkedProfile = profile
        startNotice = TrailWalkStartNotice(hikeID: hike.id, title: hike.displayTitle)
        // A refused first write is not a refused start: nothing on disk says
        // otherwise yet, and the walk is under way in memory. `persist` left
        // the next write due at once, so the next matched fix writes it.
        persist(started, at: now)
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
        // A walk adopted from the sidecar was paused on a previous launch as
        // often as it was started on this one, and the pause a background
        // relaunch inherits is exactly the one a hiker forgets: the phone has
        // been in a pocket since.
        updateReminder(for: walk)
    }

    /// The pill's *x*. The walk goes on; only the news of it is put away.
    func dismissStartNotice() {
        startNotice = nil
    }

    // MARK: Pause and resume

    /// The hiker tapped Pause.
    ///
    /// - Returns: whether the walk is now paused. A phase is a milestone and
    ///   is committed the way an end is: the record, the screens and both
    ///   feeds are moved only once the sidecar has taken the new phase, so a
    ///   refusal leaves the walk following rather than saying Paused about a
    ///   walk the disk still calls under way. Nothing else would put that
    ///   right — a paused walk accrues nothing to write later, so the
    ///   sidecar's Following would outlive the pause and a relaunch would
    ///   bank the whole stop as active time.
    @discardableResult func pause() -> Bool {
        let now = clock()
        guard var current = record, current.phase == .following else { return false }
        current.pause(at: now)
        guard persist(current, at: now) else { return false }
        record = current
        phase = .paused
        updateReminder(for: current)
        publishState()
        return true
    }

    /// The hiker tapped Resume.
    ///
    /// - Returns: whether the walk is following again, refused for the reason
    ///   above — with the walk left paused, which is what it still is on disk.
    @discardableResult func resume() -> Bool {
        let now = clock()
        guard var current = record, current.phase == .paused else { return false }
        current.resume(at: now)
        current.lastMatchedAt = now
        guard persist(current, at: now) else { return false }
        record = current
        phase = .following
        reminders?.walkDidResumeOrEnd()
        publishState()
        return true
    }

    /// Enabling Follow This Trail rearms auto-start after an End. Neither
    /// direction changes a walk already under way: its phase belongs to
    /// Pause / Resume / End, independently of the detail's live marker.
    func autoFollowDidChange(hikeID: UUID, enabled: Bool) {
        if enabled { rearmStart(hikeID: hikeID) }
    }

    private func publishState() {
        guard let record else { return }
        let now = clock()
        tracker?.walkStateDidChange(
            Self.payload(for: record, at: now, secondsLeft: secondsLeft(at: now)),
            hikeID: record.hikeID
        )
    }

    // MARK: End

    /// The hiker tapped End. Returns the row it became, a walk under the
    /// minimum that was simply cleared, or a commit the store refused — see
    /// ``TrailWalkEnd``.
    @discardableResult func end() -> TrailWalkEnd {
        finish(reason: .ended, at: clock())
    }

    /// Forgets the walk along a hike that is being deleted. No row: the host
    /// is going, and a walk has to hang off one.
    func discardWalk(forDeletedHike hikeID: UUID) {
        guard let record, record.hikeID == hikeID else { return }
        // As `finish` does: the standing banners are about a walk that no
        // longer exists, and the once-per-walk warnings must re-arm for the
        // next one, or it would never hear that it ends after dark.
        reminders?.walkDidStopFollowing()
        clearState()
        tracker?.walkDidEnd(final: nil)
    }

    /// The same, for a hike that went away without anything telling us.
    ///
    /// `MapSheet`'s swipe is the one deletion that calls the method above; a
    /// deletion mirrored from the hiker's other device calls nothing, and
    /// there is no remote-change handling to hang it off. Checked beside
    /// ``endIfAbandoned(at:)``, on every fix, because until the walk is
    /// cleared no trail can start one — ``canStart(_:)`` needs `record ==
    /// nil` — and every *other* trail offers to end this one on a screen that
    /// no longer exists.
    ///
    /// Nothing is written: the hike is detached, so the sidecar column cannot
    /// be reached through it, and the row goes whole at the next launch —
    /// see ``OpenHikesModel/reclaimOrphanedLocalStates(in:)``.
    private func discardWalkIfHikeGone() {
        guard let record, walkedHike?.isAttached == false else { return }
        discardWalk(forDeletedHike: record.hikeID)
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
        // Nobody is following anything any more, so a standing "Off the trail"
        // is a claim about a walk that is over. Here rather than in
        // `walkDidResumeOrEnd()`, which is about a *pause* ending — a pause
        // ending is when this watch starts mattering, not when it stops.
        reminders?.walkDidStopFollowing()
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
        reminders?.walkDidResumeOrEnd()
        record = nil
        walkedHike = nil
        walkedProfile = nil
        endedHikeID = nil
        lastPersistedAt = nil
        lastPersistenceAttemptAt = nil
        persistenceFailures = 0
        walkedHikeID = nil
        walkedHikeTitle = ""
        startNotice = nil
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
                clearOrphanedWalk(on: state)
                return
            }
            adopt(stale, hike: hike)
            finish(reason: .abandoned, at: now)
        case let .resume(state, open):
            guard let hike = fetchHike(open.hikeID) else {
                clearOrphanedWalk(on: state)
                return
            }
            adopt(open, hike: hike)
            tracker?.walkDidStart(hikeID: hike.id)
        }
    }

    /// Clears a walk whose hike is no longer in the store, on either branch
    /// above: a hike deleted on the hiker's other device takes the mirrored
    /// row and cannot touch this sidecar, so the column outlives it.
    ///
    /// Left uncleared it is picked again at every launch — it is the newest
    /// open walk, and ``OpenHikesModel/openWalkAtLaunch(now:fetchingLocalStates:)``
    /// returns exactly one — so a genuine open walk on another hike is never
    /// adopted. The row itself is not deleted here:
    /// ``OpenHikesModel/reclaimOrphanedLocalStates(in:)`` owns that, and this
    /// runs in background relaunches where no sweep ever gets to.
    private func clearOrphanedWalk(on state: HikeLocalState) {
        state.walkInProgress = nil
        save(reason: "clearing an orphaned walk")
    }

    private func fetchHike(_ id: UUID) -> Hike? {
        try? context.fetch(FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })).first
    }

    private static func payload(
        for record: TrailWalkRecord,
        at now: Date,
        state: SharedTrailSnapshot.Walk.State? = nil,
        secondsLeft: TimeInterval? = nil
    ) -> SharedTrailSnapshot.Walk {
        SharedTrailSnapshot.Walk(
            state: state ?? (record.phase == .paused ? .paused : .active),
            coveredFraction: record.coveredFraction,
            furthestDistanceMeters: record.coverage.furthestDistanceMeters,
            activeSeconds: record.activeSeconds(at: now),
            startedAt: record.startedAt,
            secondsLeft: secondsLeft
        )
    }
}

// MARK: - Start by hand

extension TrailWalkSession {
    /// Whether the detail's Start may begin a walk on `hike` right now:
    /// nothing else is being walked, and this is not a recording's own draft.
    ///
    /// Looser than ``canStart(_:)`` on purpose. Following off and an End just
    /// taken both hold the *automatic* start back, because neither a fix nor a
    /// selection says the hiker means to walk this trail. A tap on Start says
    /// exactly that.
    func canStartByHand(_ hike: Hike) -> Bool {
        record == nil
            && hike.isAttached
            && !hike.belongsToActiveRecording(currentHikeID: activeRecordingHikeID())
    }

    /// The hiker tapped Start on the hike's detail.
    ///
    /// Begins the walk now, from wherever the hiker is. Nothing is covered
    /// until a fix matches the route: the follow loop feeds a walk under way
    /// whether or not following is on, so from here on this is the same walk
    /// a matched fix would have started. No ``startNotice`` either — the pill
    /// is news of a start nobody asked for, and this one was asked for.
    ///
    /// - Returns: whether a walk started. A refused first write is not a
    ///   refused start, for the reason ``startIfEligible(hike:profile:at:)``
    ///   gives: the walk is under way in memory, and the next fix writes it.
    @discardableResult func start(hike: Hike, profile: RouteProfile) -> Bool {
        let now = clock()
        discardWalkIfHikeGone()
        endIfAbandoned(at: now)
        guard canStartByHand(hike), profile.totalDistanceMeters > 0 else { return false }
        let started = TrailWalkRecord(
            hikeID: hike.id,
            routeDistanceMeters: profile.totalDistanceMeters,
            startedAt: now
        )
        adopt(started, hike: hike)
        walkedProfile = profile
        persist(started, at: now)
        tracker?.walkDidStart(hikeID: hike.id)
        // Now rather than on the first match: a hiker standing at the
        // trailhead produces no fix until they move, and the widget and the
        // Lock Screen should say the walk is on from the tap.
        publishState()
        return true
    }
}

// MARK: - Persistence

private extension TrailWalkSession {
    func persistIfDue(at now: Date) {
        guard let record else { return }
        if persistenceFailures > 0, let lastPersistenceAttemptAt {
            let elapsed = now.timeIntervalSince(lastPersistenceAttemptAt)
            // Start and its first match share a timestamp. Do not spend the
            // prompt retry twice in that same fix, or across the two feeds.
            guard elapsed > 0 else { return }
            if persistenceFailures > 1, elapsed < TrailWalkPolicy.persistInterval { return }
        } else if let lastPersistedAt, now.timeIntervalSince(lastPersistedAt) < TrailWalkPolicy.persistInterval {
            return
        }
        persist(record, at: now)
    }

    /// Writes `walk` to the sidecar as the walk in progress.
    ///
    /// - Returns: whether it may be presented as written down. A refusal puts
    ///   the column back by hand — the same undo ``finish(reason:at:)`` does,
    ///   and for the same reason: the write exists only as a pending edit, so
    ///   a context left holding it would hand a later unrelated save a phase
    ///   nobody committed. The successful-write marker moves only on commit;
    ///   a separate attempt marker bounds automatic retries. Explicit
    ///   milestones always attempt their write, even during that retry wait.
    @discardableResult func persist(_ walk: TrailWalkRecord, at now: Date) -> Bool {
        guard let walkedHike, walkedHike.isAttached else {
            // No sidecar to reach: the hike is gone, the walk goes with it at
            // the next fix — ``discardWalkIfHikeGone()`` — and the row left
            // behind names a hike no launch can fetch, so nothing can be
            // restored from it. Not a refusal; there is nothing to refuse.
            return true
        }
        let previous = walkedHike.walkInProgress
        walkedHike.walkInProgress = walk
        lastPersistenceAttemptAt = now
        guard save(reason: "writing the walk in progress") else {
            walkedHike.walkInProgress = previous
            persistenceFailures = min(persistenceFailures + 1, 2)
            return false
        }
        lastPersistedAt = now
        persistenceFailures = 0
        return true
    }

    /// - Returns: whether the store accepted it. Every caller reads the
    ///   answer: a walk's phase is not a phase until the sidecar holds it,
    ///   and a walk that ends is the one commit with nothing behind it to try
    ///   again.
    @discardableResult func save(reason: String) -> Bool {
        do {
            try commit(context)
            return true
        } catch {
            let description = error.localizedDescription
            Self.logger.error("Could not save while \(reason, privacy: .public): \(description, privacy: .public)")
            return false
        }
    }
}

// MARK: - Coverage

private extension TrailWalkSession {
    /// Closes the walked interval at the last on-route match, so the fix that
    /// brings the hiker back to the trail starts a fresh one.
    ///
    /// The gap bound bridges a *lost signal*, on the reasoning that the
    /// hiker probably did walk the stretch in between. Here the evidence is
    /// the opposite: a fix was accepted, matched, and found off the route.
    /// Without this, cutting a switchback by road and rejoining within
    /// ``TrailWalkPolicy/gapBoundMeters`` hands the union the whole shortcut —
    /// and this is the coverage that reaches `HikeWalk`, History, Show on Map
    /// and the completion rule. The same statement a pause makes, made by the
    /// matcher instead of the hiker.
    ///
    /// Kept to the cadence rather than committed like a milestone: this
    /// arrives per fix, and a walk that never comes back to the route is
    /// abandoned or ended, both of which write.
    ///
    /// Which is why the write is offered on *every* off-route fix and not
    /// only on the one that made the break. An excursion accrues nothing of
    /// its own, so these fixes are the only thing that can carry a write the
    /// cadence deferred or the store refused — the same reason a paused
    /// walk's matches still reach ``persistIfDue(at:)``. Without that, a
    /// break made inside the 45-second window would live in memory alone,
    /// and a relaunch during the excursion would restore the old anchor and
    /// credit the shortcut after all.
    func breakCoverage(hikeID: UUID) {
        guard var current = record, current.hikeID == hikeID else { return }
        if current.coverage.lastMatchedDistance != nil {
            current.coverage.breakContinuity()
            record = current
        }
        // Nothing to carry once the sidecar holds this record: the hiker can
        // be off the route for hours, and an unchanged rewrite every cadence
        // is a save and a `@Query` tick for nothing. A refused write left the
        // column as it was, so it still differs here and is still retried.
        guard walkedHike?.walkInProgress != current else { return }
        persistIfDue(at: clock())
    }
}

// MARK: - Reminders

private extension TrailWalkSession {
    /// Arms or disarms the reminder that a paused walk is being walked anyway.
    ///
    /// One function for the two places a walk's phase is set from a record —
    /// the hiker's own Pause, and a walk adopted from the sidecar at launch —
    /// because a relaunched pause is exactly the one a hiker forgets and the
    /// two must not disagree about what watches it.
    ///
    /// Anchored at the position the walk had reached rather than at a
    /// coordinate: the feeds a paused walk still hears from speak in distance
    /// along this route, and that is the measurement — which is also why the
    /// controller takes the displacement in either direction, so a hiker who
    /// covers the trail backwards while paused is noticed just the same.
    ///
    /// Stamped with the record's own ``TrailWalkRecord/phaseChangedAt``
    /// rather than with the clock, for the same reason one function serves
    /// both callers: a pause adopted at launch happened whenever the hiker
    /// tapped it, possibly hours before this process existed, and dating it
    /// from launch would hand the watch a boundary every fix taken during the
    /// pause falls before.
    ///
    /// The *position*, emphatically not the coverage maximum. A hiker who
    /// went out to a summit and came back down before pausing has a maximum
    /// half a walk away from where they are standing, and anchoring there
    /// told them they had covered eight hundred metres for standing still.
    func updateReminder(for walk: TrailWalkRecord) {
        guard walk.phase == .paused else {
            reminders?.walkDidResumeOrEnd()
            return
        }
        reminders?.walkDidPause(
            trailTitle: walkedHikeTitle,
            atDistance: walk.lastFollowedDistanceMeters
                ?? walk.coverage.furthestDistanceMeters,
            on: walk.phaseChangedAt
        )
    }
}
