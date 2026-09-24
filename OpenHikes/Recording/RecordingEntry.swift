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
    private let openRequests: HikeOpenRequests

    /// - Parameters:
    ///   - isLive: whether a recording is under way. Read inside the map's
    ///     observation, so it has to read observable state.
    ///   - start: starts one. Only called while `isLive` says there is none.
    ///   - openRequests: where the request for the screen is left.
    init(
        isLive: @escaping @MainActor () -> Bool,
        start: @escaping @MainActor () async -> Void,
        openRequests: HikeOpenRequests
    ) {
        self.isLive = isLive
        self.start = start
        self.openRequests = openRequests
    }

    convenience init(recorder: HikeRecorder, openRequests: HikeOpenRequests) {
        self.init(
            isLive: { [weak recorder] in recorder?.isActive == true },
            start: { [weak recorder] in await recorder?.start() },
            openRequests: openRequests
        )
    }

    /// Whether the button opens a recording already under way rather than
    /// starting one — which is what turns it red.
    var isRecording: Bool { isLive() }

    /// Starts a recording when none is under way, then asks for its screen —
    /// the two steps the sheet's button took before it moved to the map.
    ///
    /// A start refused for want of location still leaves the recorder
    /// active, on its failure, so the screen opens on the reason rather than
    /// the tap doing nothing. See ``HikeRecorder/start()``.
    func requestRecording() {
        Task {
            if !isLive() { await start() }
            openRequests.openRecording()
        }
    }
}
