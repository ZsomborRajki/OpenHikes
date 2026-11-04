//
//  HikePhotoSearchPlanFingerprintTests.swift
//  OpenHikesTests
//
//  What tells a plan from the hike it was read off (#1280): everything that
//  can move a photograph's answer, and nothing that cannot. A difference it
//  missed would keep a pin from a line that has gone. One it invented would
//  throw away a review for a save that moved nothing, which is what heights
//  filled onto a line are.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Photo search plan fingerprint")
struct HikePhotoSearchPlanFingerprintTests {
    /// One way a line can differ from the fixture's, and whether a pin could
    /// land elsewhere for it.
    enum Change: String, CaseIterable, Sendable {
        case heights = "heights"
        case latitude = "latitude"
        case longitude = "longitude"
        case motion = "motion"
        case pause = "pause"
        case provenance = "provenance"
        case timestamp = "timestamp"

        var movesAPin: Bool { self != .heights && self != .motion }

        func apply(to point: inout RouteCoordinate) {
            switch self {
            case .heights: point.elevation = 800
            case .latitude: point.latitude += 0.0001
            case .longitude: point.longitude += 0.0001
            case .motion: point.motion = .nonPedestrian
            case .pause: point.boundary = .paused
            case .provenance: point.provenance = .inferred
            case .timestamp: point.timestamp = point.timestamp?.addingTimeInterval(60)
            }
        }
    }

    private static func fingerprint(
        of route: [RouteCoordinate] = PhotoDiscoveryFixture.route,
        walks: [HikeWalkPhotoTimeline] = []
    ) -> HikePhotoSearchPlan.Fingerprint {
        HikePhotoSearchPlan.Source(route: route, walks: walks).fingerprint
    }

    private static func walk(endingAtStep step: Double) throws -> HikeWalkPhotoTimeline {
        try #require(
            HikeWalkPhotoTimeline(
                startedAt: PhotoDiscoveryFixture.date(atStep: 0),
                endedAt: PhotoDiscoveryFixture.date(atStep: step),
                coverage: TrailWalkCoverage(intervals: [0, 100], furthestDistanceMeters: 100)
            )
        )
    }

    @Test("a plan's fingerprint is its source's")
    func planCarriesItsSourcesFingerprint() {
        let source = HikePhotoSearchPlan.Source(route: PhotoDiscoveryFixture.route, walks: [])

        #expect(HikePhotoSearchPlan(source: source).fingerprint == source.fingerprint)
    }

    @Test("a line differs by what can move a pin, and only that", arguments: Change.allCases)
    func lineDiffersByWhatCanMoveAPin(change: Change) {
        var route = PhotoDiscoveryFixture.route
        change.apply(to: &route[3])

        #expect((Self.fingerprint(of: route) != Self.fingerprint()) == change.movesAPin)
    }

    /// A height the store could not represent is not a difference: a line
    /// that read unequal to itself would be searched again without end.
    @Test("a line reads as itself, whatever its heights hold")
    func lineReadsAsItself() {
        var route = PhotoDiscoveryFixture.route
        route[3].elevation = .nan
        let read = Self.fingerprint(of: route)
        let readAgain = Self.fingerprint(of: route)

        #expect(read == readAgain)
    }

    @Test("the walks a plan rests on are part of it")
    func walksAreCounted() throws {
        let walked = Self.fingerprint(walks: [try Self.walk(endingAtStep: 9)])
        let walkedAgain = Self.fingerprint(walks: [try Self.walk(endingAtStep: 9)])

        #expect(walked == walkedAgain)
        #expect(walked != Self.fingerprint())
        #expect(walked != Self.fingerprint(walks: [try Self.walk(endingAtStep: 8)]))
    }
}
