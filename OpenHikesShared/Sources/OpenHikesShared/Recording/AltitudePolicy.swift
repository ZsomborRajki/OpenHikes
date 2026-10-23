//
//  AltitudePolicy.swift
//  OpenHikesShared
//
//  Which GPS heights a recording is allowed to believe — on the phone, on the
//  watch and in the widget's sparse anchors alike.
//
//  ## Why one rule for three readers
//
//  Each of them used to write the check out for itself, and they had drifted
//  into three different rules. The phone refused a height whose vertical
//  uncertainty was over 15 m. The widget allowed 30 m and never asked whether
//  the height was a number. The watch had no upper bound at all, so a level
//  walk with heights alternating 100 m and 200 m at ±100 m reached
//  `ElevationAccumulator` as 300 m of climb. That figure went to the watch
//  face, onto the hike the walk turned into and into Health (#932). The
//  deadband after it cannot help, because a 100 m swing is not noise to a
//  three-metre threshold, so the height has to be refused when it comes in.
//
//  ## Why at the recorder, and not in the accumulator
//
//  For the reason `RecordingFixWindow` gives: `WatchWalkAccumulator` is also
//  what a journal is replayed into, and a journal keeps the height without the
//  accuracy it was judged by. A refused height must not cost its fix, though.
//  Each caller keeps the position and drops only the altitude, so a walk under
//  a poor sky still has its full track. `ElevationAccumulator` skips a missing
//  height without breaking the chain, so the climb across that stretch is
//  still counted, from the trusted height before it to the one after.
//

import Foundation

/// When a GPS altitude can be kept on a recorded fix.
public enum AltitudePolicy {
    /// Above this many metres of vertical uncertainty a height is a guess.
    /// Raw GPS height wanders by ±5–15 m even under a clear sky, which is
    /// already more than `ElevationAccumulator`'s deadband can clean; past
    /// that, the swings are as large as the hills.
    public static let maximumVerticalAccuracy: Double = 15

    /// `altitude`, or `nil` when it should not be recorded.
    ///
    /// A negative `verticalAccuracy` is Core Location saying the altitude is
    /// invalid. Zero is a valid claim and is kept: Core Location documents
    /// zero or more as "plus or minus that many metres". A non-finite
    /// altitude is refused whatever its accuracy, because one would turn every
    /// statistic derived from it into NaN, and `JSONEncoder` cannot write it.
    public static func trustedAltitude(_ altitude: Double, verticalAccuracy: Double) -> Double? {
        guard verticalAccuracy >= 0,
              verticalAccuracy <= maximumVerticalAccuracy,
              altitude.isFinite
        else { return nil }
        return altitude
    }
}
