//
//  RecordingEntry.swift
//  OpenHikes
//
//  The record button on the map: whether a recording is live, and what a tap
//  on the button — or on the recording screen's Start — does.
//
//  The button lives in the leading-edge pill under *Make a trail* — see
//  ``MapTrailDraftControlsView`` — which is UIKit on a map that never
//  re-renders, and cannot reach the sheet's navigation stack. So a tap starts
//  the recorder here and then asks for the screen through
//  ``HikeOpenRequests``, as though the widget showing the recording had been
//  tapped. That is deliberately not a way in of its own: ``OpenHikesView``
//  already knows how to open a live recording from a widget link, and two
//  routes to one screen are how they come to disagree.
//
//  A hiker walks a trail or records one, never both. So a tap while a walk is
//  under way does not start anything: the button asks first — see
//  ``walkToEnd`` — and ``endWalkAndRecord()`` is the answer that ends the
//  walk the way End does and then records. A refused End is said the way the
//  detail's End says it, through ``walkEndRefused``: a menu choice that did
//  nothing would read as one that was never made.
//
//  The recording screen's own Start goes through here as well — see
//  ``RecordingCard`` — because that screen can be up with nothing recording
//  on this phone: a row carrying another device's draft opens it. Asking the
//  recorder from there began a recording beside a paused walk (#1310). Its
//  request for the screen then asks for the one already up, which a widget
//  tap on it does too, and which selects the recording just started.
//
//  One more way in asks nothing here, because it is itself the answer to a
//  question: a hiker who left the trail they were walking and chose to record
//  instead — see ``OffTrailQuestion``. That one ends the walk too, and hands
//  what it covered to the recording, so the hike so far is in it: see
//  ``recordInsteadOfWalk()``.
//
//  The live state and the start are closures rather than the recorder itself,
//  so the map's suite can offer a button without building a recorder, a store
//  and a journal behind it. Observation tracking follows a read through a
//  closure exactly as it follows one made directly.
//

import Foundation
import OpenHikesShared

/// What ending a walk for the recording that takes over from it came to.
enum WalkTakeover {
    /// The walk is over, and this is what the recording begins with: `nil`
    /// when the walk had covered nothing to carry.
    case ended(carrying: RecordingSeed?)
    /// Another walk is under way: the one asked about ended while it was
    /// being handed over, and the next began in that moment. Nothing records
    /// beside it, and nothing is said — the question was about a walk that
    /// is over, and the record button asks about this one.
    case overtaken
    /// The walk is still under way: the store refused its end, or its line
    /// could not be read for what it covered to be carried. The walk asks its
    /// question again, saying so — see ``OffTrailQuestion/handOffFailed``.
    case refused
}

/// Whether a recording is live, and the request to start or reopen one.
@MainActor
@Observable
final class RecordingEntry {
    private let isLive: @MainActor () -> Bool
    private let start: @MainActor (RecordingSeed?) async -> Void
    private let walkUnderWay: @MainActor () -> String?
    private let endWalk: @MainActor () -> Bool
    private let takeOverWalk: @MainActor () async -> WalkTakeover
    private let unclaimedSeed: @MainActor () -> RecordingSeed?
    private let letGoOfUnclaimedWalk: @MainActor () -> Void
    private let openRequests: HikeOpenRequests

    /// Whether the store refused the End that ``endWalkAndRecord()`` asked
    /// for. The map's alert reads and clears it — see ``MapScreenAlerts``.
    /// ``recordInsteadOfWalk()`` has its question asked again instead.
    var walkEndRefused = false

    /// - Parameters:
    ///   - isLive: whether a recording is under way. Read inside the map's
    ///     observation, so it has to read observable state.
    ///   - start: starts one, beginning with what it is handed — see
    ///     ``RecordingSeed`` — or with nothing. Only called while `isLive`
    ///     says there is none, and `walkUnderWay` that nothing is being
    ///     walked.
    ///   - walkUnderWay: the title of the trail being walked, or `nil`. Read
    ///     inside the map's observation, like `isLive`.
    ///   - endWalk: ends that walk, and says whether it did — a commit the
    ///     store refused leaves it under way.
    ///   - takeOverWalk: ends that walk for a recording that begins with what
    ///     it covered, and hands that over.
    ///   - unclaimedSeed: what a handoff whose start failed carried, for the
    ///     recording screen's Start to try it again — see
    ///     ``HikeRecorder/unclaimedSeed``.
    ///   - letGoOfUnclaimedWalk: lets go of that, for a recording screen that
    ///     is up for something else.
    ///   - openRequests: where the request for the screen is sent.
    init(
        isLive: @escaping @MainActor () -> Bool,
        start: @escaping @MainActor (RecordingSeed?) async -> Void,
        walkUnderWay: @escaping @MainActor () -> String? = { nil },
        endWalk: @escaping @MainActor () -> Bool = { true },
        takeOverWalk: @escaping @MainActor () async -> WalkTakeover = { .ended(carrying: nil) },
        unclaimedSeed: @escaping @MainActor () -> RecordingSeed? = { nil },
        letGoOfUnclaimedWalk: @escaping @MainActor () -> Void = { /* nothing kept */ },
        openRequests: HikeOpenRequests
    ) {
        self.isLive = isLive
        self.start = start
        self.walkUnderWay = walkUnderWay
        self.endWalk = endWalk
        self.takeOverWalk = takeOverWalk
        self.unclaimedSeed = unclaimedSeed
        self.letGoOfUnclaimedWalk = letGoOfUnclaimedWalk
        self.openRequests = openRequests
    }

    convenience init(recorder: HikeRecorder, walkSession: TrailWalkSession, openRequests: HikeOpenRequests) {
        self.init(
            isLive: { [weak recorder] in recorder?.isActive == true },
            start: { [weak recorder] seed in await recorder?.start(carrying: seed) },
            walkUnderWay: { [weak walkSession] in walkSession?.walkUnderWayTitle },
            endWalk: { [weak walkSession] in
                guard let walkSession else { return true }
                let end = walkSession.end()
                // Felt as the detail's End is — see ``WalkHaptics``.
                end.hapticMoment.play()
                if case .refused = end { return false }
                return true
            },
            takeOverWalk: { [weak walkSession] in
                guard let walkSession else { return .ended(carrying: nil) }
                switch await walkSession.handOffToRecording() {
                case let .ended(end, seed):
                    // Felt as an End is, which is what it was.
                    end.hapticMoment.play()
                    if case .refused = end { return .refused }
                    return .ended(carrying: seed)
                case .lineUnreadable:
                    // Felt as a refused End is: the walk is still under way.
                    HapticMoment.walkFailed.play()
                    return .refused
                case .noWalk:
                    return .ended(carrying: nil)
                case .overtaken:
                    return .overtaken
                }
            },
            unclaimedSeed: { [weak recorder] in recorder?.unclaimedSeed },
            letGoOfUnclaimedWalk: { [weak recorder] in recorder?.letGoOfUnclaimedWalk() },
            openRequests: openRequests
        )
    }

    /// Whether the button opens a recording already under way rather than
    /// starting one — which is what turns it red.
    var isRecording: Bool { isLive() }

    /// The trail whose walk a tap would have to end before recording, or
    /// `nil` when it would not — nothing walked, or a recording already live,
    /// which a tap only reopens. What has the button ask first.
    var walkToEnd: String? { isLive() ? nil : walkUnderWay() }

    /// Starts a recording when none is under way, then asks for its screen —
    /// the two steps the sheet's button took before it moved to the map.
    ///
    /// A start refused for want of location leaves **no** session and the
    /// recorder inactive, but the screen is where that refusal is explained
    /// and Settings offered — so the request goes out regardless, and the
    /// link's handler admits it through ``HikeRecorder/hasScreenToShow``.
    func requestRecording() {
        // The button asks before this can be reached mid-walk; a recording
        // started beside a walk anyway would be the overlap this refuses.
        guard walkToEnd == nil else { return }
        Task {
            if !isLive() { await start(nil) }
            openRequests.openRecording()
        }
    }

    /// The recording screen's Start: ``requestRecording()``, except that a
    /// handoff from a walk whose start failed there is tried again with what
    /// the walk covered — see ``HikeRecorder/unclaimedSeed``. The screen is
    /// where that failure was explained, so its Start is the retry; the
    /// map's button starts a recording of its own.
    func startOnRecordingScreen() {
        guard walkToEnd == nil else { return }
        Task {
            if !isLive() { await start(unclaimedSeed()) }
            openRequests.openRecording()
        }
    }

    /// A library row that is a recording's draft opens the recording screen
    /// too, on this phone's idle recorder — `MapSheet` says so here as it
    /// pushes it. The screen is then up for that row, not for a handoff
    /// whose start failed, so its Start is a recording of its own: the walk
    /// kept for that retry is let go of, as any other start lets it go.
    func recordingScreenOpenedForRow() {
        letGoOfUnclaimedWalk()
    }

    /// The hiker said yes to ending their walk to record: ends it as End
    /// does — kept in the trail's History when it covered enough — and then
    /// records. A walk the store would not let go of stays under way, and
    /// nothing starts beside it.
    func endWalkAndRecord() {
        if walkToEnd != nil, !endWalk() {
            walkEndRefused = true
            return
        }
        requestRecording()
    }

    /// The hiker left the trail they were walking and said to record instead:
    /// ends the walk as End does, where it was last on its trail, and then
    /// records, beginning with what the walk covered — so the hike so far is
    /// in the recording. A walk that could not be handed over stays under
    /// way, nothing starts beside it, and its question is asked again, saying
    /// so; one that another walk replaced meanwhile starts nothing beside
    /// that one.
    func recordInsteadOfWalk() {
        Task {
            guard case let .ended(seed) = await takeOverWalk() else { return }
            if !isLive() { await start(seed) }
            openRequests.openRecording()
        }
    }
}

extension HikeRecorder {
    /// Whether the recording screen has something to show: a recording under
    /// way, or a start refused before any session existed.
    ///
    /// Wider than ``isActive`` by exactly that refusal. A start that fails on
    /// `.locationDenied` clears `startRequested` with no session behind it, so
    /// the recorder is not active — yet the recording screen is the one place
    /// that failure is explained and its Settings button offered. The map's
    /// record button reaches that screen through the widget's link, and a link
    /// gated on `isActive` alone turned the tap into nothing at all. A widget
    /// never offers the link without a live snapshot, so it gains nothing here.
    var hasScreenToShow: Bool {
        if case .failed = phase { return true }
        return isActive
    }
}
