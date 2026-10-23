//
//  CommonsTrailPhotosTests.swift
//  OpenHikesTests
//
//  Which of the files Commons has near a route are kept, where each is
//  pinned, and which dozen of them are shown.
//
//  The route is a straight line due north, ten one-kilometre legs, so every
//  distance below can be checked by hand: a degree of latitude is about 111 km
//  and a degree of longitude at this latitude about 75 km.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Commons trail photos")
struct CommonsTrailPhotosTests {
    private static let startLatitude = 47.6
    private static let longitude = 13.0
    /// One kilometre of latitude, near enough.
    private static let kilometer = 0.009
    /// Fifty and a hundred and fifty metres of longitude at this latitude.
    private static let fiftyMetersEast = 0.000667
    private static let hundredFiftyMetersEast = 0.002

    private static let route: [RouteCoordinate] = (0...10).map { step in
        RouteCoordinate(latitude: startLatitude + Double(step) * kilometer, longitude: longitude)
    }

    private static var profile: RouteProfile { RouteProfile(route: route) }

    private static func candidate(_ pageID: Int, kilometers: Double, east: Double = 0) -> CommonsPhotoCandidate {
        CommonsPhotoCandidate(
            pageID: pageID,
            latitude: startLatitude + kilometers * kilometer,
            longitude: longitude + east
        )
    }

    private static func placed(_ pageID: Int, along: Double, off: Double) -> CommonsTrailPhotos.Placed {
        CommonsTrailPhotos.Placed(
            pageID: pageID,
            latitude: startLatitude,
            longitude: longitude,
            distanceAlongRoute: along,
            offRouteMeters: off
        )
    }

    // MARK: - On the line, or not at all

    @Test("a camera within the corridor is kept and pinned on the line, one past it is not")
    func corridor() throws {
        let kept = CommonsTrailPhotos.placed(
            [
                Self.candidate(1, kilometers: 0.5),
                Self.candidate(2, kilometers: 2.5, east: Self.fiftyMetersEast),
                Self.candidate(3, kilometers: 4.5, east: Self.hundredFiftyMetersEast),
            ],
            on: Self.profile
        )

        #expect(kept.map(\.pageID) == [1, 2])
        let offset = try #require(kept.last)
        #expect(abs(offset.longitude - Self.longitude) < 0.00001, "pinned on the line, not where the camera stood")
        #expect(abs(offset.offRouteMeters - 50) < 3)
        #expect(abs(offset.distanceAlongRoute - 2500) < 15)
    }

    @Test("a file two circles both found is kept once")
    func duplicatesAreKeptOnce() {
        let kept = CommonsTrailPhotos.placed(
            [Self.candidate(7, kilometers: 1), Self.candidate(7, kilometers: 1)],
            on: Self.profile
        )
        #expect(kept.count == 1)
    }

    // MARK: - Spread along the walk

    /// The reason the spread exists: a summit or a hut terrace holds dozens of
    /// files, and the nearest dozen to the line would all be of it.
    @Test("a crowd at the trailhead does not crowd out the far end")
    func crowdedStartLeavesRoomForTheEnd() {
        let crowd = (0..<30).map { Self.placed($0, along: Double($0), off: 1) }
        let lonely = Self.placed(99, along: 9900, off: 80)

        let shown = CommonsTrailPhotos.spread(crowd + [lonely], limit: 12, over: 10_000)

        #expect(shown.count == 12)
        #expect(shown.contains { $0.pageID == 99 }, "the only photograph of the last kilometre is shown")
    }

    @Test("within one stretch, the camera closest to the line wins")
    func closestToTheLineWins() {
        let shown = CommonsTrailPhotos.spread(
            [
                Self.placed(1, along: 100, off: 90),
                Self.placed(2, along: 200, off: 10),
                Self.placed(3, along: 300, off: 40),
            ],
            limit: 1,
            over: 10_000
        )
        #expect(shown.map(\.pageID) == [2])
    }

    @Test("what is shown is in walking order, whatever order it arrived in")
    func walkingOrder() {
        let shown = CommonsTrailPhotos.spread(
            [
                Self.placed(1, along: 9000, off: 5),
                Self.placed(2, along: 1000, off: 5),
                Self.placed(3, along: 5000, off: 5),
            ],
            limit: 12,
            over: 10_000
        )
        #expect(shown.map(\.pageID) == [2, 3, 1])
    }

    @Test("empty stretches are filled from the rest, nearest the line first")
    func emptyStretchesAreFilled() {
        let start = (0..<5).map { Self.placed($0, along: Double($0 * 10), off: Double($0)) }
        let shown = CommonsTrailPhotos.spread(start, limit: 3, over: 10_000)
        #expect(shown.map(\.pageID) == [0, 1, 2])
    }

    /// What a route's shortlist is cut from: every file its circles found
    /// near the line, so the places left over are a few out of many.
    @Test("the places left over go to the crowd's nearest the line, ties to the lower page id")
    func leftoverPlacesFromACrowd() {
        // Sixty files on the first sixty meters, arriving last page first,
        // closest to the line in the middle of the crowd and further off on
        // either side of it.
        let crowd = (0..<60).reversed().map { Self.placed($0, along: Double($0), off: Double(abs($0 - 30) + 1)) }

        let shown = CommonsTrailPhotos.spread(crowd, limit: 4, over: 10_000)

        #expect(shown.map(\.pageID) == [28, 29, 30, 31], "28 and 32 stand as far off the line; the lower page id wins")
    }

    @Test("a limit of nothing shows nothing")
    func zeroLimit() {
        #expect(CommonsTrailPhotos.spread([Self.placed(1, along: 0, off: 0)], limit: 0, over: 1).isEmpty)
    }

    // MARK: - Spread among the people who took them

    /// What the live service answered along the Königssee shore: one
    /// uploader's run of a road on every stretch, and two other people's
    /// photographs that a spread on position alone left out.
    @Test("one photographer does not fill the strip while somebody else's photographs wait")
    func onePhotographerIsCapped() {
        let run = (1...10).map { Self.placed($0, along: Double($0 * 900), off: 1) }
        let others = [Self.placed(20, along: 4500, off: 60), Self.placed(21, along: 7300, off: 70)]
        let authors = Dictionary(uniqueKeysWithValues: run.map { ($0.pageID, "Road") })
            .merging([20: "Anna", 21: "Bence"]) { first, _ in first }

        let shown = CommonsTrailPhotos.chosen(run + others, authors: authors, limit: 5, over: 10_000)

        #expect(shown.count == 5)
        #expect(shown.filter { authors[$0.pageID] == "Road" }.count == CommonsTrailPhotos.perAuthorLimit)
        #expect(Set(shown.map(\.pageID)).isSuperset(of: [20, 21]))
    }

    @Test("a walk only one person photographed still fills the strip with theirs")
    func capGivesWayWhenNobodyElse() {
        let run = (1...10).map { Self.placed($0, along: Double($0 * 900), off: 1) }
        let authors = Dictionary(uniqueKeysWithValues: run.map { ($0.pageID, "Road") })

        let shown = CommonsTrailPhotos.chosen(run, authors: authors, limit: 5, over: 10_000)

        #expect(shown.count == 5)
        #expect(shown.map(\.distanceAlongRoute) == shown.map(\.distanceAlongRoute).sorted(), "in walking order")
    }

    /// The rule the live service's answer along the Königssee shore asked
    /// for: past the limit, one person's run fills a gap in the walk or
    /// nothing.
    @Test("past the limit, a photographer's pictures go only where nobody's stands yet")
    func pastTheLimitOnlyGapsAreFilled() {
        let run = (1...8).map { Self.placed($0, along: Double($0 * 100), off: 1) }
        let anna = Self.placed(20, along: 1500, off: 50)
        let authors = Dictionary(uniqueKeysWithValues: run.map { ($0.pageID, "Road") })
            .merging([20: "Anna"]) { first, _ in first }

        let shown = CommonsTrailPhotos.chosen(run + [anna], authors: authors, limit: 6, over: 6000)

        #expect(shown.map(\.pageID) == [1, 2, 3, 20], "the rest of the run stands where the walk is already shown")
    }

    @Test("when there are more gaps than places, the held-back pictures nearest the line fill them")
    func gapsGoNearestTheLineFirst() {
        let run = (1...3).map { Self.placed($0, along: Double($0 * 100), off: 1) }
        let heldBack = [
            Self.placed(4, along: 1500, off: 30),
            Self.placed(5, along: 2500, off: 10),
            Self.placed(6, along: 3500, off: 20),
        ]
        let authors = Dictionary(uniqueKeysWithValues: (run + heldBack).map { ($0.pageID, "Road") })

        let shown = CommonsTrailPhotos.chosen(run + heldBack, authors: authors, limit: 4, over: 4000)

        #expect(shown.map(\.pageID) == [1, 2, 3, 5], "three stretches stand empty and there is room for one")
    }

    @Test("a file whose page names nobody is nobody's, and is never held back")
    func unnamedFilesAreNeverCapped() {
        let unnamed = (1...6).map { Self.placed($0, along: Double($0 * 1500), off: 1) }

        let shown = CommonsTrailPhotos.chosen(unnamed, authors: [:], limit: 6, over: 10_000)

        #expect(shown.count == 6)
    }

    // MARK: - The circles asked about

    @Test("a day hike is asked about in small circles that reach past the line")
    func dayHikeAreas() throws {
        let areas = CommonsTrailPhotos.areas(along: Self.route)

        #expect(areas.count > 1, "one circle around ten kilometres would lose its far edge to the cap")
        #expect(areas.count <= CommonsTrailPhotos.maximumAreas)
        let first = try #require(areas.first)
        #expect(first.radiusMeters >= CommonsTrailPhotos.corridorMeters)
        #expect(first.radiusMeters <= CommonsTrailPhotos.stretchRadiusMeters + CommonsTrailPhotos.corridorMeters)
    }

    @Test("a long route grows its circles rather than multiplying them, up to the service's ceiling")
    func longRouteAreas() {
        let long = (0...300).map { step in
            RouteCoordinate(latitude: Self.startLatitude + Double(step) * Self.kilometer, longitude: Self.longitude)
        }
        let areas = CommonsTrailPhotos.areas(along: long)

        #expect(areas.count <= CommonsTrailPhotos.maximumAreas)
        #expect(areas.allSatisfy { $0.radiusMeters <= CommonsTrailPhotos.maximumRadiusMeters })
    }
}
