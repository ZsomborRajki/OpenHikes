//
//  WatchWorkoutCollection.swift
//  OpenHikesShared
//
//  What the watch's workout session collects: heart rate, and nothing else.
//
//  ## What is collected stays
//
//  The session is there to keep a recording alive, and its builder is
//  discarded on every path out of one, so that the phone writes the walk to
//  Health once — see `WatchRecorder`. Discarding keeps out the workout and
//  nothing more. `HKWorkoutBuilder.h` says of `discardWorkout()` that
//  "Samples that were added to the workout will not be deleted", and Apple's
//  *Running workout sessions* says that while a session runs, Apple Watch
//  "saves samples to the HealthKit store". A live data source left to
//  HealthKit's defaults collects what the workout's configuration calls for,
//  and Apple's example, an outdoor run, collects energy and distance as well
//  as heart rate. So every recording on the watch could leave energy the app
//  never says it writes, and a second distance beside the walk the phone
//  writes.
//
//  So the data source keeps what the watch reads, which is heart rate, and
//  stops the rest. Heart rate stays exactly as HealthKit set it up, its
//  predicate included, because the screen's figure has no other feed, and
//  the privacy policy says Health may keep those readings. Nothing is turned
//  on: defaults without heart rate leave a session that shows none, as one
//  always did, rather than a collection this app picked.
//
//  Nobody has looked in Health after a recording on a real watch (#1210).
//  Collected-means-saved is Apple's documented model, and the decision holds
//  whichever way it goes: what is never collected cannot be left behind.
//
//  ## Why here
//
//  *The watch app* in the repository instructions: there is no watch test
//  bundle, so the decision lives in this package and the watch target only
//  hands HealthKit's types in and turns off what comes back. It is made over
//  their identifiers, HealthKit's own strings, which keeps HealthKit out of
//  this package's library; the suite holds them to HealthKit's constants.
//

import Foundation

/// Which of the types a live workout data source would collect for the
/// watch's session it goes on collecting, and which it is told to stop.
public struct WatchWorkoutCollection: Equatable, Sendable {
    /// `HKQuantityTypeIdentifier.heartRate`'s raw value.
    static let heartRate = "HKQuantityTypeIdentifierHeartRate"

    /// Every type the watch reads off the session's builder. A figure that
    /// starts reading another joins it here, or its data source never
    /// collects what it reads.
    static let read: Set<String> = [heartRate]

    /// The defaults the watch reads, collected as HealthKit set them up.
    public let kept: Set<String>
    /// The defaults nothing reads, which the data source stops collecting.
    public let stopped: Set<String>

    /// - Parameter defaults: the identifiers of the data source's
    ///   `typesToCollect`, as HealthKit filled them in for the session's
    ///   configuration.
    public init(defaults: Set<String>) {
        kept = defaults.intersection(Self.read)
        stopped = defaults.subtracting(Self.read)
    }
}
