//
//  SeededRecordingFixture.swift
//  OpenHikes
//
//  A recording under way, behind `--ui-test-seed-recording=<GPX name>`.
//
//  The recording screen is a screen of figures, and a recording a test starts
//  has none worth reading: everything is zero until a walk's worth of fixes
//  has gone in at a walk's pace, which is minutes a scenario does not have.
//  Fed faster, the figures read as a run — the App Store frame of this screen
//  walked twenty fixes 22 m apart at four seconds each, and said 18 km/h with
//  no climb at all.
//
//  So this writes what a crash would have left behind: a ``TrackJournal``
//  holding the opening stretch of a bundled GPX, re-timed to end a moment
//  ago, and lets ``HikeRecorder``'s own recovery resume it. Nothing about the
//  screen is a stand-in — the distance, the climb, the moving time and both
//  speeds are what the recorder's accumulator makes of the points, and the
//  line is the recorder's trace — only the walk is borrowed. Mirrors
//  ``SeededWalkFixture``, and like it is compiled only into `DEBUG`.
//

import CoreLocation
import Foundation
import OpenHikesData

#if DEBUG
nonisolated enum SeededRecordingFixture {
    /// How far into the route the walker has got: up the switchbacks to just
    /// short of the Kühroint alm on the Königssee fixture, two hours and some
    /// seven hundred metres of climb in.
    static let walkedMeters = 4200.0
    /// How long ago the last point was taken.
    ///
    /// Recent enough that recovery resumes the recording rather than parking
    /// it for a decision — ``HikeRecorder/finishRecovery(session:journal:recoveryLastUpdatedAt:automaticallyResume:)``
    /// asks for five minutes — and long enough that the scenario's first live
    /// fix, a few metres on, reads as a walk rather than a sprint.
    static let lastPointAge: TimeInterval = 15
    /// The accuracy every point is given: a good fix in open forest, the same
    /// figure the UI tests' simulated locations carry.
    static let horizontalAccuracy = 5.0

    /// Writes the recording into `directory`, the recorder's journal directory
    /// for this launch, and answers whether there is one to recover.
    static func write(fixture name: String, into directory: URL, now: Date = .now) async -> Bool {
        guard let url = Bundle.main.url(forResource: name, withExtension: "gpx"),
              let track = try? GPXImport.load(from: url) else { return false }
        let points = recordedPoints(of: track.route, upTo: walkedMeters, endingAt: now - lastPointAge)
        guard let first = points.first else { return false }
        let journal = TrackJournal(directory: directory)
        do {
            try await journal.start(sessionID: UUID(), startedAt: first.timestamp)
            for point in points {
                try await journal.append(point)
            }
            try await journal.flush()
            try await journal.close()
            return true
        } catch {
            return false
        }
    }

    /// The route's points up to `meters` along it, each moved by the same
    /// amount so the last of them was taken at `end`.
    ///
    /// The file's own clock is kept rather than invented: its pace and its
    /// rest stops are what make the moving time and the two speeds differ the
    /// way a walk's do. A route with a point that carries no time has no clock
    /// to keep, and gives nothing.
    static func recordedPoints(
        of route: [RouteCoordinate],
        upTo meters: Double,
        endingAt end: Date
    ) -> [RecordingPoint] {
        var walked = 0.0
        var stretch: [RouteCoordinate] = []
        for point in route {
            if let previous = stretch.last {
                walked += RouteGeometry.distanceMeters(from: previous.clCoordinate, to: point.clCoordinate)
                guard walked <= meters else { break }
            }
            stretch.append(point)
        }
        guard let last = stretch.last?.timestamp,
              stretch.allSatisfy({ $0.timestamp != nil }) else { return [] }
        let shift = end.timeIntervalSince(last)
        return stretch.compactMap { point in
            point.timestamp.map { taken in
                RecordingPoint(
                    latitude: point.latitude,
                    longitude: point.longitude,
                    timestamp: taken.addingTimeInterval(shift),
                    horizontalAccuracy: horizontalAccuracy,
                    elevation: point.elevation
                )
            }
        }
    }
}
#endif
