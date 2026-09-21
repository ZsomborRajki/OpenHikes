//
//  StubTrailLegRouter.swift
//  OpenHikesTests
//
//  A leg router that answers whatever it is told to, and counts.
//
//  The seam ``TrailLegRouting`` exists to give: no suite may reach a
//  volunteer-run public API, and the policy worth asserting in
//  ``TrailDraftController`` is *who is asked and how often* — which is
//  invisible against a real router and is this type's whole reason for
//  existing.
//
//  It can also be held open. A question that has been asked and has not
//  answered is the state half the controller's rules are about — a leg
//  already in flight, a maker closed mid-question — and there is no way to be
//  in it against a router that answers immediately.
//

import CoreLocation
import Foundation
@testable import OpenHikes

actor StubTrailLegRouter: TrailLegRouting {
    /// What the next answer says, or `nil` for the answer a cancelled
    /// question gives — which is no answer at all.
    private var snap: TrailLegSnap?
    private var asked: [TrailLegEnds] = []
    /// Whether answers are held back until ``release()``.
    private var isHolding: Bool
    /// The callers waiting for that release.
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(answering snap: TrailLegSnap?, holding: Bool = false) {
        self.snap = snap
        isHolding = holding
    }

    func route(_ ends: TrailLegEnds) async -> TrailLegRoute? {
        asked.append(ends)
        if isHolding {
            await withCheckedContinuation { continuation in
                waiting.append(continuation)
            }
        }
        guard let snap else { return nil }
        return .straight(along: ends, snap)
    }

    /// What every answer from here on says, or `nil` to answer the way a
    /// cancelled question does.
    func answer(with snap: TrailLegSnap?) {
        self.snap = snap
    }

    /// Lets everything waiting through, and stops holding the next question.
    func release() {
        isHolding = false
        let resuming = waiting
        waiting = []
        for continuation in resuming { continuation.resume() }
    }

    func askedCount() -> Int { asked.count }
}
