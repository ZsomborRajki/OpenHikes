//
//  TrailWalkFeedSupport.swift
//  OpenHikesTests
//
//  The session's two feeds as most suites call them: with a fix that says
//  nothing of its accuracy, which leaves a turn at
//  `TrailWalkPolicy.minimumTurnMeters`. The app's own entry points take no
//  default, so the compiler holds each feed to handing over the fix's real
//  accuracy (#1307); a suite about the accuracy names one.
//

import Foundation
@testable import OpenHikes
import OpenHikesData

extension TrailWalkSession {
    /// ``recordForegroundMatch(hike:profile:distance:accuracy:revision:at:)``
    /// for a fix that reports no uncertainty.
    @discardableResult func recordForegroundMatch(
        hike: Hike,
        profile: RouteProfile,
        distance: Double,
        revision: String? = nil,
        at timestamp: Date? = nil
    ) -> Bool {
        recordForegroundMatch(
            hike: hike,
            profile: profile,
            distance: distance,
            accuracy: 0,
            revision: revision,
            at: timestamp
        )
    }

    /// ``recordBackgroundMatch(hikeID:distance:accuracy:at:)`` for a fix that
    /// reports no uncertainty.
    @discardableResult func recordBackgroundMatch(hikeID: UUID, distance: Double, at timestamp: Date) -> Bool {
        recordBackgroundMatch(hikeID: hikeID, distance: distance, accuracy: 0, at: timestamp)
    }
}
