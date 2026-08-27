//
//  RecordingEnduranceWalk.swift
//  OpenHikesTests
//
//  The simulated hike ``RecordingEnduranceTests`` drives, and the tolerances
//  it holds the pipeline to. Separated from the tests themselves only because
//  the two together are longer than one file is allowed to be.
//
//  Every generated fix is built to clear ``RecordingFixPolicy`` outright — a
//  walking pace well above the displacement gate and well below the speed cap,
//  and a stopped cadence at or beyond `maximumInterval` so a fix that has not
//  moved is still admitted. That is deliberate: it makes "delivered" and
//  "accepted" the same number, so a shortfall is a dropped fix rather than a
//  policy decision the test failed to model.
//
//  The route comes from ``SeededGenerator``, so a failure names the seed it
//  happened on and can be replayed on exactly the values that produced it.
//

import CoreLocation
import Foundation
@testable import OpenHikes

// MARK: - The simulated walk

enum Endurance {
    static let secondsPerHour: TimeInterval = 3600
    /// A long day out. Long enough that the journal is flushed hundreds of
    /// times and the trace is more than twenty times the widget's budget.
    static let hours = 6.0
    /// The recording is reconciled against the journal once per simulated
    /// hour, which is also what keeps the serial queue from having to buffer
    /// the entire hike before anything drains.
    static let segments = 6

    /// CoreLocation's cadence while the walker is moving.
    static let movingInterval: TimeInterval = 5
    /// ...and while they are standing still, where the wider distance filter
    /// means the only fixes arriving are the ones the timer produces. At or
    /// beyond ``RecordingFixPolicy/maximumInterval``, which is what admits a
    /// fix that has not moved far enough to clear the displacement gate.
    static let stoppedInterval: TimeInterval = 15

    /// 6.0-7.2 m every 5 s is 1.2-1.44 m/s: a walking pace, comfortably above
    /// the 5 m displacement gate this accuracy produces and comfortably below
    /// ``RecordingFixPolicy/maximumSpeed``.
    static let minimumStepMeters = 6.0
    static let maximumStepMeters = 7.2

    /// GPS noise while standing still. Small enough that the *first* moving
    /// fix after a stop still clears the 5 m gate measured from wherever the
    /// noise left the walker, which is why it is under a metre rather than the
    /// several metres a real phone wanders.
    static let wanderMeters = 0.8

    static let stopCount = 3
    static let stopSeconds: TimeInterval = 6 * 60

    static let horizontalAccuracy: CLLocationAccuracy = 8
    static let verticalAccuracy: CLLocationAccuracy = 5

    static let originLatitude = 47.63
    static let originLongitude = 12.86
    static let initialBearingDegrees = 20.0
    static let maximumTurnDegrees = 6.0

    static let baseAltitudeMeters = 620.0
    static let altitudeAmplitudeMeters = 45.0
    static let altitudeCycles = 3.0

    static let metersPerDegreeLatitude = 111_320.0
    static let metersPerDegreeLongitude = metersPerDegreeLatitude
        * cos(originLatitude * .pi / 180)

    static let degreesPerTurn = 360.0
}

/// One fix the simulated walk delivers, without a timestamp: the driving loop
/// stamps each one from the test clock at the moment it hands it over, so
/// every fix is exactly as old as ``LocationFixPolicy`` expects a live one to
/// be.
struct EnduranceStep {
    let interval: TimeInterval
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let course: CLLocationDirection
    let speed: CLLocationSpeed
    let isMoving: Bool

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func location(at timestamp: Date) -> CLLocation {
        CLLocation(
            coordinate: coordinate,
            altitude: altitude,
            horizontalAccuracy: Endurance.horizontalAccuracy,
            verticalAccuracy: Endurance.verticalAccuracy,
            course: course,
            speed: speed,
            timestamp: timestamp
        )
    }
}

/// A deterministic six-hour walk: a meandering climb-and-descend with three
/// real stops in it.
struct EnduranceWalk {
    let seed: UInt64
    let steps: [EnduranceStep]
    /// The geodesic metres between consecutive generated positions, summed
    /// over every delivered leg. Computed from the coordinates rather than
    /// from the metre offsets that produced them, so it is an independent
    /// reference for what the accumulator should arrive at rather than a
    /// restatement of the generator's own arithmetic.
    let plannedDistanceMeters: Double
    /// Where in ``steps`` the walker was standing still, so a test that needs
    /// a stationary window can deliver up to the end of one rather than
    /// guessing at an index.
    let stopRanges: [Range<Int>]

    init(
        hours: Double = Endurance.hours,
        seed: UInt64 = SeededGenerator.defaultSeed
    ) {
        var builder = Builder(hours: hours, seed: seed)
        builder.walk()
        self.seed = seed
        steps = builder.steps
        stopRanges = builder.stopRanges
        plannedDistanceMeters = zip(builder.steps, builder.steps.dropFirst())
            .reduce(0.0) { total, pair in
                total + RouteGeometry.distanceMeters(
                    from: pair.0.coordinate,
                    to: pair.1.coordinate
                )
            }
    }

    private struct Builder {
        let hours: Double
        var steps: [EnduranceStep] = []
        var stopRanges: [Range<Int>] = []

        private var rng: SeededGenerator
        private var easting = 0.0
        private var northing = 0.0
        private var bearing = Endurance.initialBearingDegrees
        private var elapsed = 0.0

        init(hours: Double, seed: UInt64) {
            self.hours = hours
            rng = SeededGenerator(seed: seed)
        }

        mutating func walk() {
            let total = hours * Endurance.secondsPerHour
            let between = total / Double(Endurance.stopCount + 1)
            var nextStop = between
            var taken = 0
            while elapsed < total {
                if taken < Endurance.stopCount, elapsed >= nextStop {
                    rest()
                    taken += 1
                    nextStop += between
                    continue
                }
                pace()
            }
        }

        private mutating func pace() {
            let distance = Double.random(
                in: Endurance.minimumStepMeters...Endurance.maximumStepMeters,
                using: &rng
            )
            bearing += Double.random(
                in: -Endurance.maximumTurnDegrees...Endurance.maximumTurnDegrees,
                using: &rng
            )
            let radians = bearing * .pi / 180
            easting += distance * sin(radians)
            northing += distance * cos(radians)
            elapsed += Endurance.movingInterval
            append(
                offsetEasting: 0,
                offsetNorthing: 0,
                speed: distance / Endurance.movingInterval,
                isMoving: true
            )
        }

        /// A stop that a real recording would see: fixes keep arriving on the
        /// timer, none of them goes anywhere, and the accumulator eventually
        /// calls it stationary.
        private mutating func rest() {
            let start = steps.count
            var rested = 0.0
            while rested < Endurance.stopSeconds {
                rested += Endurance.stoppedInterval
                elapsed += Endurance.stoppedInterval
                let angle = Double.random(in: 0...(2 * .pi), using: &rng)
                let radius = Double.random(in: 0...Endurance.wanderMeters, using: &rng)
                append(
                    offsetEasting: radius * cos(angle),
                    offsetNorthing: radius * sin(angle),
                    speed: 0,
                    isMoving: false
                )
            }
            stopRanges.append(start..<steps.count)
        }

        private mutating func append(
            offsetEasting: Double,
            offsetNorthing: Double,
            speed: CLLocationSpeed,
            isMoving: Bool
        ) {
            let progress = elapsed / (hours * Endurance.secondsPerHour)
            steps.append(
                EnduranceStep(
                    interval: isMoving
                        ? Endurance.movingInterval
                        : Endurance.stoppedInterval,
                    latitude: Endurance.originLatitude
                        + (northing + offsetNorthing) / Endurance.metersPerDegreeLatitude,
                    longitude: Endurance.originLongitude
                        + (easting + offsetEasting) / Endurance.metersPerDegreeLongitude,
                    altitude: Endurance.baseAltitudeMeters
                        + Endurance.altitudeAmplitudeMeters
                        * sin(progress * Endurance.altitudeCycles * 2 * .pi),
                    course: bearing.truncatingRemainder(
                        dividingBy: Endurance.degreesPerTurn
                    ),
                    speed: speed,
                    isMoving: isMoving
                )
            )
        }
    }
}

// MARK: - Tolerances

enum EnduranceExpectation {
    /// The live accumulator and the journal replay run the same arithmetic
    /// over the same points in the same order, so they should agree to the
    /// bit. A millimetre of slack rather than exact equality only so a future
    /// reordering of one addition reports as a near miss instead of as a
    /// crash-level surprise.
    static let replayToleranceMeters = 0.001

    /// The accumulator is allowed to come in *under* the geodesic sum of every
    /// delivered leg, because it freezes distance for the duration of a
    /// stationary window and resumes with the straight-line displacement from
    /// the anchor rather than the wandering path. Three stops cost well under
    /// a hundred metres of a twenty-six kilometre walk.
    static let underCountFraction = 0.03
    /// Coming in *over* the geodesic sum is double counting, and there is no
    /// mechanism that should produce it — a metre of floating-point slack.
    static let overCountMeters = 1.0

    /// The profile's elevation summary and the recorder's live one are two
    /// implementations of the same reversal-threshold rule over altitudes that
    /// round-trip through the journal's `Float` field.
    static let elevationToleranceMeters = 2.0

    /// ``RouteProfile`` sums every leg of the saved route, while the
    /// accumulator freezes distance for the duration of a stationary window
    /// and resumes with the straight-line displacement from its anchor. The
    /// profile is therefore expected to be the longer of the two, by whatever
    /// the stops wandered — 41 m of a 26 km walk on the default seed. A
    /// percent is a wide enough band to survive a different seed and a tight
    /// enough one to catch a profile that has walked a different route.
    static let profileExcessFraction = 0.01

    static let widgetPolylineBudget = 180
    /// The decimated polyline is an even stride over the trace, so its bounding
    /// box is inset from the full route's by at most one stride of walking.
    static let boundingBoxToleranceMeters = 60.0
}
