//
//  RecordingEntry.swift
//  OpenHikes
//
//  The record button on the map: whether a recording is live, and what a tap
//  on the button does.
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
//  walk the way End does and then records.
//
//  The live state and the start are closures rather than the recorder itself,
//  so the map's suite can offer a button without building a recorder, a store
//  and a journal behind it. Observation tracking follows a read through a
//  closure exactly as it follows one made directly.
//

import Foundation

/// Whether a recording is live, and the request to start or reopen one.
@MainActor
final class RecordingEntry {
    private let isLive: @MainActor () -> Bool
    private let start: @MainActor () async -> Void
    private let walkUnderWay: @MainActor () -> String?
    private let endWalk: @MainActor () -> Bool
    private let openRequests: HikeOpenRequests

    /// - Parameters:
    ///   - isLive: whether a recording is under way. Read inside the map's
    ///     observation, so it has to read observable state.
    ///   - start: starts one. Only called while `isLive` says there is none,
    ///     and `walkUnderWay` that nothing is being walked.
    ///   - walkUnderWay: the title of the trail being walked, or `nil`. Read
    ///     inside the map's observation, like `isLive`.
    ///   - endWalk: ends that walk, and says whether it did — a commit the
    ///     store refused leaves it under way.
    ///   - openRequests: where the request for the screen is sent.
    init(
        isLive: @escaping @MainActor () -> Bool,
        start: @escaping @MainActor () async -> Void,
        walkUnderWay: @escaping @MainActor () -> String? = { nil },
        endWalk: @escaping @MainActor () -> Bool = { true },
        openRequests: HikeOpenRequests
    ) {
        self.isLive = isLive
        self.start = start
        self.walkUnderWay = walkUnderWay
        self.endWalk = endWalk
        self.openRequests = openRequests
    }

    convenience init(recorder: HikeRecorder, walkSession: TrailWalkSession, openRequests: HikeOpenRequests) {
        self.init(
            isLive: { [weak recorder] in recorder?.isActive == true },
            start: { [weak recorder] in await recorder?.start() },
            walkUnderWay: { [weak walkSession] in walkSession?.walkUnderWayTitle },
            endWalk: { [weak walkSession] in
                guard let walkSession else { return true }
                if case .refused = walkSession.end() { return false }
                return true
            },
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
            if !isLive() { await start() }
            openRequests.openRecording()
        }
    }

    /// The hiker said yes to ending their walk to record: ends it as End
    /// does — kept in the trail's History when it covered enough — and then
    /// records. A walk the store would not let go of stays under way, and
    /// nothing starts beside it.
    func endWalkAndRecord() {
        if walkToEnd != nil, !endWalk() { return }
        requestRecording()
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
