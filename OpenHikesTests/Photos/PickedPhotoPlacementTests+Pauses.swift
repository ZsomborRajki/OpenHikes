//
//  PickedPhotoPlacementTests+Pauses.swift
//  OpenHikesTests
//
//  The camera's position snapped onto a route a pause has split (#1334). A
//  pause is no distance (see ``RouteBoundary``), so a piece the recording
//  resumed on and never moved along has the very distance of the fix before
//  the pause, and a distance alone cannot tell the two apart. Read back
//  through ``RouteProfile/coordinate(atDistance:)``, a photo taken where the
//  recording resumed was pinned a drive away from its camera, at the other
//  end of the pause, or at the start of the next piece, and labelled as
//  placed by where it was taken.
//
//  Beside those, the two things that already held and must go on holding: a
//  piece that does move after a pause snaps a camera onto its line as any
//  sparse stretch does, and the drive itself is never trail.
//
//  Split from ``PickedPhotoPlacementTests`` as an extension, because one test
//  type goes in a file and these share its fixtures.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

/// The ways a recording can resume without moving, 110 km north of where it
/// paused, after a kilometre walked.
enum StationaryResume: String, CaseIterable, Sendable {
    /// One more fix there, and the recording stopped: the route in #1334.
    case atTheEnd = "at the route's end"
    /// One more fix there, then another pause and a drive on.
    case beforeAnotherPause = "before another pause"
    /// Several fixes standing there before walking on.
    case beforeWalkingOn = "before walking on"

    static let resumedAt = CLLocationCoordinate2D(latitude: 48, longitude: 12)
    /// A kilometer north, in degrees of latitude.
    static let kilometer = 0.01
    /// About as far as each pause drives, in degrees of latitude.
    static let drive = 1.0
    static let startedAt = CLLocationCoordinate2D(latitude: resumedAt.latitude - drive, longitude: resumedAt.longitude)
    /// Where the second pause of ``beforeAnotherPause`` resumes.
    static let resumedAgainAt = CLLocationCoordinate2D(
        latitude: resumedAt.latitude + drive,
        longitude: resumedAt.longitude
    )

    /// The kilometre walked, then the pause and the drive to ``resumedAt``.
    static let beforeThePause = [
        fix(startedAt),
        fix(startedAt, kilometersNorth: 1),
        fix(resumedAt, boundary: .paused),
    ]

    static func fix(
        _ place: CLLocationCoordinate2D,
        kilometersNorth: Double = 0,
        boundary: RouteBoundary? = nil
    ) -> RouteCoordinate {
        RouteCoordinate(
            latitude: place.latitude + kilometer * kilometersNorth,
            longitude: place.longitude,
            boundary: boundary
        )
    }

    var route: [RouteCoordinate] {
        let standing = Self.fix(Self.resumedAt)
        return switch self {
        case .atTheEnd:
            Self.beforeThePause + [standing]
        case .beforeAnotherPause:
            Self.beforeThePause + [
                standing,
                Self.fix(Self.resumedAgainAt, boundary: .paused),
                Self.fix(Self.resumedAgainAt, kilometersNorth: 1),
            ]
        case .beforeWalkingOn:
            Self.beforeThePause + [standing, standing, Self.fix(Self.resumedAt, kilometersNorth: 1)]
        }
    }
}

extension PickedPhotoPlacementTests {
    private static func placement(
        on route: [RouteCoordinate],
        camera: CLLocationCoordinate2D
    ) -> PickedPhotoPlacement {
        PickedPhotoPlacement.resolve(
            PickedPhotoMetadata(capturedAt: nil, coordinate: camera),
            plan: HikePhotoSearchPlan(timeline: nil, walks: [], route: route, profilesRoute: true),
            fallback: graphSelection,
            now: PhotoDiscoveryFixture.epoch
        )
    }

    /// A few metres beside where the recording resumed, which is a point of
    /// this trail and nowhere near the kilometre walked before the pause.
    @Test("a photo where a recording resumed without moving is snapped there", arguments: StationaryResume.allCases)
    func stationaryPieceAfterAPause(piece: StationaryResume) {
        let resumedAt = StationaryResume.resumedAt
        let beside = CLLocationCoordinate2D(latitude: resumedAt.latitude, longitude: resumedAt.longitude + 0.0003)

        let placement = Self.placement(on: piece.route, camera: beside)

        #expect(placement.evidence == .place)
        #expect(Self.meters(placement.coordinate, resumedAt) < 1)
    }

    /// The ordinary case beside it: a piece that walks on after the pause,
    /// with a kilometre between two of its fixes, takes a camera halfway
    /// along onto the line, and one at the resume onto the resume.
    @Test("a photo on a sparse piece after a pause is snapped onto its line", arguments: [0.0, 0.5])
    func sparsePieceAfterAPause(kilometersNorth: Double) {
        let resumedAt = StationaryResume.resumedAt
        let route = StationaryResume.beforeThePause + [StationaryResume.fix(resumedAt, kilometersNorth: 1)]
        let takenAt = CLLocationCoordinate2D(
            latitude: resumedAt.latitude + StationaryResume.kilometer * kilometersNorth,
            longitude: resumedAt.longitude
        )

        let placement = Self.placement(on: route, camera: takenAt)

        #expect(placement.evidence == .place)
        #expect(Self.meters(placement.coordinate, takenAt) < 1)
    }

    /// Halfway along the drive is 55 km from either piece. Were the paused
    /// leg trail, the camera would be standing on it.
    @Test("a photo on the drive between two pieces goes to the graph selection", arguments: StationaryResume.allCases)
    func theDriveIsNeverMatched(piece: StationaryResume) {
        let start = StationaryResume.startedAt
        let onTheDrive = CLLocationCoordinate2D(
            latitude: (start.latitude + StationaryResume.resumedAt.latitude) / 2,
            longitude: start.longitude
        )

        let placement = Self.placement(on: piece.route, camera: onTheDrive)

        #expect(placement.evidence == nil)
        #expect(Self.meters(placement.coordinate, Self.graphSelection) < 1)
    }
}
