//
//  SeededCommunityFixture.swift
//  OpenHikesTests
//
//  What the two seeded-transport suites both need: a transport per scenario, a
//  nearby read, a directory a preview can download into, and a draft to
//  submit.
//
//  Shared rather than written twice because the two suites are one subject
//  split for length — see ``SeededCommunityTransportTests`` for what that
//  subject is and why it is worth a unit suite at all.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData

nonisolated enum SeededCommunityFixture {
    static let startLatitude = SeededCommunityTransport.startLatitude
    static let startLongitude = SeededCommunityTransport.startLongitude

    /// Where every scenario puts the simulated fix. The transport ignores it
    /// deliberately — see its own note — so this is a coordinate rather than a
    /// place the answer depends on.
    static let anywhere = CLLocationCoordinate2D(
        latitude: startLatitude,
        longitude: startLongitude
    )

    static func transport(
        _ scenario: SeededCommunityTransport.Scenario
    ) -> SeededCommunityTransport {
        SeededCommunityTransport(scenario: scenario)
    }

    /// Wide enough to reach every seeded row, and a page bigger than the
    /// three of them, so a read that came back short said something about the
    /// transport rather than about the arguments it was given.
    private static let searchRadiusMeters = 10_000.0
    private static let pageLimit = 50

    static func nearby(
        _ scenario: SeededCommunityTransport.Scenario,
        excluding: Set<String> = []
    ) async throws -> [CommunityListing] {
        try await transport(scenario).listings(
            near: anywhere,
            radiusMeters: searchRadiusMeters,
            limit: pageLimit,
            excluding: excluding,
            // The widest question, because a seeded scenario's curated half is
            // a stand-in that reaches nothing: a narrower scope here would
            // leave `SeededCuratedTrailSource`'s rows out of every fixture
            // that asks for a mixed list.
            scope: .withCuratedTrails
        ).listings
    }

    /// A directory per case, deleted by the case — the same contract the
    /// preview screen has with this transport.
    static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seeded-transport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A short walk near the seeded trailhead. Spelled out here rather than
    /// borrowed from the transport's own route generator, which is file-private
    /// to it — and a draft is the hiker's own route arriving from outside
    /// anyway.
    static let walkedRoute: [RouteCoordinate] = (0..<walkedPointCount).map { step in
        RouteCoordinate(
            latitude: startLatitude + Double(step) * stepLatitude,
            longitude: startLongitude + Double(step) * stepLongitude,
            elevation: baseElevation + Double(step) * elevationStep,
            timestamp: SeededCommunityTransport.hikeDate
                .addingTimeInterval(Double(step) * secondsPerPoint)
        )
    }

    /// Enough points to be a walk rather than a line, at roughly a walking
    /// pace — the transport only asks whether there are any.
    private static let walkedPointCount = 6
    private static let stepLatitude = 0.0002
    private static let stepLongitude = 0.00012
    private static let baseElevation = 535.0
    private static let elevationStep = 4.0
    private static let secondsPerPoint: TimeInterval = 20

    /// A length that is nothing in particular: the seeded transport does not
    /// read it, and the screens that do are not what these suites are about.
    private static let draftDistanceMeters = 4200.0

    static func draft(
        hikeID: UUID = UUID(),
        route: [RouteCoordinate] = walkedRoute
    ) -> CommunitySubmissionDraft {
        CommunitySubmissionDraft(
            hikeID: hikeID,
            title: "A hike to send",
            authorName: "Tester",
            trackDescription: nil,
            hikeDate: SeededCommunityTransport.hikeDate,
            distanceMeters: draftDistanceMeters,
            route: route,
            photoPins: [],
            photoFileURLs: [],
            stagingDirectory: FileManager.default.temporaryDirectory
        )
    }
}
