//
//  ElevationAccumulator.swift
//  OpenHikesShared
//
//  The one definition of "climbed", shared by the phone and the watch.
//

import Foundation

/// Running elevation totals over a sequence of points: the extremes reached,
/// and the climb and descent between them, counted in runs rather than in
/// single steps so that sensor noise is not read as terrain.
///
/// Separate from the statistics that use it because three callers want exactly
/// this and nothing else — a hike's detail stats, the widget snapshot's summary
/// of a saved trail, and a recording's live gain — and "climbed" has to mean the
/// same thing in all three. That is also why the deadband lives here and not at
/// a call site: a recorded hike arrives barometrically smoothed and an imported
/// GPX arrives raw, and the two must still produce comparable numbers.
public struct ElevationAccumulator: Sendable, Equatable {
    /// How far elevation has to reverse before the climb it interrupted is
    /// counted.
    ///
    /// Without one of these every sensor wobble is a hill. Noise is symmetric
    /// but summing `max(delta, 0)` is not, so jitter integrates in one
    /// direction forever: 2,000 points wandering ±1.5 m around a single
    /// elevation — a phone resting on a table — accumulate roughly 965 m of
    /// "climb". The error grows with the number of points, which means the
    /// longer the hike the more wrong the number, and it is never visibly
    /// wrong: 1,150 m on a 1,000 m climb reads like a plausible figure.
    ///
    /// Three metres is above the barometer's short-term noise floor and below
    /// anything a hiker would call a rise, so real terrain passes through it
    /// unchanged — the fixture in `HikeStatisticsTests` reports the same
    /// +200/−60 with the deadband as without. It does not fully clean raw GPS
    /// altitude, which wanders by ±5–15 m; nothing at this layer can, because
    /// a 10 m spike is indistinguishable from a 10 m step. It bounds the
    /// damage to the amplitude of the noise instead of the amplitude times
    /// the point count, which is the difference between an overstatement and
    /// a fiction.
    public static let reversalThresholdMeters = 3.0

    public private(set) var count = 0
    public private(set) var minimumMeters: Double?
    public private(set) var maximumMeters: Double?

    /// A parameter only so tests can drive the deadband directly instead of
    /// inferring it; callers take the default, because "climbed" has to mean
    /// the same thing in all three of them.
    public let reversalThresholdMeters: Double

    private var committedGain = 0.0
    private var committedLoss = 0.0

    /// The elevation the current run started from, and the furthest the run
    /// has reached. Everything between them is provisional: it counts toward
    /// the totals immediately but is not committed until the direction
    /// reverses far enough to prove the run is over.
    private var anchor: Double?
    private var extreme: Double?

    public init(reversalThresholdMeters: Double = Self.reversalThresholdMeters) {
        self.reversalThresholdMeters = reversalThresholdMeters
    }

    /// Feeds one point's elevation in. A point without one is skipped rather
    /// than read as sea level, and it doesn't break the chain: the next height
    /// is compared against the last one that existed.
    ///
    /// A height that isn't a number is skipped the same way, and more
    /// urgently. NaN loses every comparison, so one of them reaching the
    /// `min`/`max` below would replace the extremes of the entire route with
    /// itself rather than corrupt only its own reading.
    public mutating func record(_ elevation: Double?) {
        guard let elevation, elevation.isFinite else { return }
        count += 1
        minimumMeters = min(minimumMeters ?? elevation, elevation)
        maximumMeters = max(maximumMeters ?? elevation, elevation)

        guard let runStart = anchor, let runPeak = extreme else {
            anchor = elevation
            extreme = elevation
            return
        }

        if runPeak >= runStart {
            // Climbing. A new high extends the run; anything short of the
            // threshold below the high is noise on the way up.
            if elevation > runPeak {
                extreme = elevation
            } else if runPeak - elevation >= reversalThresholdMeters {
                committedGain += runPeak - runStart
                anchor = runPeak
                extreme = elevation
            }
        } else {
            if elevation < runPeak {
                extreme = elevation
            } else if elevation - runPeak >= reversalThresholdMeters {
                committedLoss += runStart - runPeak
                anchor = runPeak
                extreme = elevation
            }
        }
    }

    /// Closes the run in progress, so the next height starts a new one instead
    /// of being compared with the last. For a gap whose rise is not ground the
    /// hiker walked — a pause, after which the receiver may be somewhere else.
    public mutating func endRun() {
        committedGain = gainMeters
        committedLoss = lossMeters
        anchor = nil
        extreme = nil
    }

    /// Metres climbed, including the run in progress.
    ///
    /// The provisional run is included rather than withheld because a
    /// recording reads this live: a hiker halfway up a climb has climbed,
    /// and a total that froze until they came back down would be wrong in a
    /// way the user can see. It also means no caller has to remember to
    /// finalise the accumulator when the route ends.
    public var gainMeters: Double {
        guard let anchor, let extreme, extreme > anchor else { return committedGain }
        return committedGain + (extreme - anchor)
    }

    public var lossMeters: Double {
        guard let anchor, let extreme, extreme < anchor else { return committedLoss }
        return committedLoss + (anchor - extreme)
    }

    /// Whether gain and loss mean anything yet. A single height is a position,
    /// not a change, and reporting "0 m climbed" for it would be a claim the
    /// data does not support.
    public var hasChange: Bool { count > 1 }
}
