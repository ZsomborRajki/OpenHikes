//
//  MovementThresholds.swift
//  OpenHikesData
//
//  What "standing still" and "faster than a person moves on foot" mean.
//
//  Here rather than on the recorder because two places ask and they are on
//  either side of this package's edge: a saved route's moving time and
//  fastest segment are worked out in here (``MovingTimeAccumulator``,
//  ``HikeRouteStatistics``), and the live recording's are worked out in the
//  app. A hiker who watched "2h 10m moving" during a walk and then read
//  "1h 58m" on the saved hike would have been shown two numbers with one
//  name, so both read these figures and neither declares its own. The app's
//  `RecordingDistanceAccumulator` and `RecordingFixPolicy` keep their names
//  for them and point here.
//

import CoreLocation
import Foundation

nonisolated public enum MovementThresholds {
    /// How long a hiker has to stay inside one small area before a recording
    /// stops calling it walking.
    public static let stationaryInterval: TimeInterval = 30
    /// And how small that area is.
    public static let stationaryNetDisplacement: CLLocationDistance = 15
    /// Faster than a person moves on foot: a fix implying more is rejected
    /// live, and a saved segment implying more is not a walking speed.
    public static let maximumOnFootSpeed: CLLocationSpeed = 8
}
