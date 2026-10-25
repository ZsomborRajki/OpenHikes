//
//  RecordingShutterPositionTests.swift
//  OpenHikesTests
//
//  Where a photo taken while recording is pinned when the camera hands it
//  over some time after its shutter fired (#970).
//
//  The camera shows each shot for review, and the walk goes on until Use Photo
//  is tapped. The recorder's last accepted fix is where the hiker is at that
//  tap; the fixes accepted since the shutter are what say where they were.
//  ``PhotoTrailAnchor/recordingCoordinate(atShutter:recent:latest:)`` reads
//  those through ``HikePhotoTimeline``, and these hold it to the same rules a
//  library photo on a saved walk is held to — and to the old answer wherever
//  there is nothing newer to correct it with.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import RealModule
import Testing

@Suite("Recording shutter position")
struct RecordingShutterPositionTests {
    private static let start = Date(timeIntervalSince1970: 1_700_000_000)
    /// A degree of latitude is about 111 km, so this is a few centimetres.
    private static let tolerance = 1e-7

    private static func point(
        _ latitude: Double,
        at seconds: TimeInterval,
        flags: RecordingPointFlags = []
    ) -> RecordingPoint {
        RecordingPoint(
            latitude: latitude,
            longitude: 12.86,
            timestamp: start.addingTimeInterval(seconds),
            horizontalAccuracy: 5,
            flags: flags
        )
    }

    /// - Parameter resumed: The recorder has just resumed and accepted no
    ///   fix on the new leg yet, which leaves it without a latest fix.
    private static func coordinate(
        atShutter seconds: TimeInterval?,
        recent: [RecordingPoint],
        resumed: Bool = false
    ) -> CLLocationCoordinate2D? {
        PhotoTrailAnchor.recordingCoordinate(
            atShutter: seconds.map { start.addingTimeInterval($0) },
            recent: recent,
            latest: resumed ? nil : recent.last
        )
    }

    /// The issue's reproduction: taken at A, handed over a minute and a few
    /// fixes later at B.
    @Test("a photo handed over after the walk moved on stays where its shutter fired")
    func laterFixesDoNotMoveTheShutter() throws {
        let walk = [Self.point(47.63, at: 0), Self.point(47.6302, at: 10), Self.point(47.6304, at: 60)]

        let pinned = try #require(Self.coordinate(atShutter: 0, recent: walk))

        #expect(pinned.latitude.isApproximatelyEqual(to: 47.63, absoluteTolerance: Self.tolerance))
    }

    @Test("a shutter between two fixes is placed between them")
    func shutterBetweenFixesInterpolates() throws {
        let walk = [Self.point(47.63, at: 0), Self.point(47.6302, at: 10), Self.point(47.6304, at: 60)]

        let pinned = try #require(Self.coordinate(atShutter: 5, recent: walk))

        #expect(pinned.latitude.isApproximatelyEqual(to: 47.6301, absoluteTolerance: Self.tolerance))
    }

    @Test("with no shutter time the latest fix is the answer, as before")
    func missingShutterUsesTheLatestFix() throws {
        let walk = [Self.point(47.63, at: 0), Self.point(47.6304, at: 60)]

        let pinned = try #require(Self.coordinate(atShutter: nil, recent: walk))

        #expect(pinned.latitude.isApproximatelyEqual(to: 47.6304, absoluteTolerance: Self.tolerance))
    }

    /// A hiker standing still produces no new fixes, so the last one may be
    /// far older than the timeline's grace and still be exactly right.
    @Test("a shutter after the newest fix keeps the latest fix however old it is")
    func shutterAfterTheNewestFixUsesTheLatestFix() throws {
        let walk = [Self.point(47.63, at: 0), Self.point(47.6304, at: 60)]

        let pinned = try #require(Self.coordinate(atShutter: 60 + 900, recent: walk))

        #expect(pinned.latitude.isApproximatelyEqual(to: 47.6304, absoluteTolerance: Self.tolerance))
    }

    @Test("straight after a resume, before the new leg's first fix, there is nowhere to pin")
    func resumedLegWithoutAFixPinsNothing() {
        let walk = [Self.point(47.63, at: 0), Self.point(47.6304, at: 60)]

        #expect(Self.coordinate(atShutter: 400, recent: walk, resumed: true) == nil)
    }

    /// A pause is never interpolated across: the leg walked while it was on
    /// was never recorded. Either side is an end of a segment, within the
    /// timeline's grace, and the middle of a long pause is nowhere.
    @Test("a shutter during a pause is placed at the nearer end of it, or nowhere")
    func pauseIsNotInterpolatedAcross() throws {
        let walk = [
            Self.point(47.63, at: 0),
            Self.point(47.64, at: 1200, flags: .resumed),
            Self.point(47.6402, at: 1210),
        ]

        let early = try #require(Self.coordinate(atShutter: 60, recent: walk))
        let late = try #require(Self.coordinate(atShutter: 1150, recent: walk))

        #expect(early.latitude.isApproximatelyEqual(to: 47.63, absoluteTolerance: Self.tolerance))
        #expect(late.latitude.isApproximatelyEqual(to: 47.64, absoluteTolerance: Self.tolerance))
        #expect(Self.coordinate(atShutter: 600, recent: walk) == nil)
    }

    /// The buffer keeps only the last ``RecentRecordingFixes/retention`` of
    /// the walk. A shutter further back than that would otherwise be read
    /// against the oldest fix kept as though the walk began there, and pinned
    /// to it within the timeline's grace.
    @Test("a shutter older than the fixes kept is placed nowhere, not at the oldest kept")
    func shutterBeyondTheRetentionPinsNothing() throws {
        let retention = RecentRecordingFixes.retention
        // What the buffer holds once a fix at 0 has been let go.
        let kept = [Self.point(47.631, at: 100), Self.point(47.632, at: 100 + retention)]

        #expect(Self.coordinate(atShutter: 50, recent: kept) == nil)
        let atTheHorizon = try #require(Self.coordinate(atShutter: 100, recent: kept))
        #expect(atTheHorizon.latitude.isApproximatelyEqual(to: 47.631, absoluteTolerance: Self.tolerance))
    }
}
