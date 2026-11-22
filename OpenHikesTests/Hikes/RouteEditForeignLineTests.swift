//
//  RouteEditForeignLineTests.swift
//  OpenHikesTests
//
//  *Edit Route* on a drawn trail a 1.6 build has had its hands on, which
//  writes the line and how it was drawn but knows nothing of an edit record.
//
//  Its maker can replace the line of a trail this build has trimmed, leaving
//  the trim's record describing a line the hike no longer has; the editor
//  then works from the line the hike has, and the history goes. And its
//  maker marked a trail edited while it was shared in the plan it kept,
//  which is where this build reads that the shared copy is out of date.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@MainActor
@Suite("Route edit after a 1.6 build")
struct RouteEditForeignLineTests {
    private enum Line {
        static let latitude = 47.63
        static let longitude = 12.86
        /// A thousandth of a degree of latitude between points, about 111 m.
        static let spacing = 0.001
        static let pointCount = 11
        /// How far east the 1.6 maker's line runs: well clear of the first.
        static let redrawnLongitude = 12.90
        static let submission = "submission-1"
    }

    /// A drawn line of eleven points north, with no times.
    private static func line(at longitude: Double) -> [RouteCoordinate] {
        (0..<Line.pointCount).map { index in
            RouteCoordinate(latitude: Line.latitude + Double(index) * Line.spacing, longitude: longitude)
        }
    }

    /// `route` cut to its middle third.
    private static func middleThird(of route: [RouteCoordinate]) throws -> EditedLine {
        let distances = RouteTrim.distances(along: route)
        let length = try #require(distances.last)
        return try #require(EditedLine(
            whole: route,
            distances: distances,
            cuts: EditedLine.Cuts(range: length / 3...length * 2 / 3),
            replacing: route
        ))
    }

    /// What a 1.6 build's maker kept of how it drew a trail, as that build
    /// encodes it, with the submission it was last edited under.
    private static func plan(editedUnder submission: String?) -> Data {
        var json = #"{"waypoints":[{"latitude":47.63,"longitude":12.86},{"latitude":47.64,"longitude":12.86}],"#
            + #""waypointNames":["Start",""],"travelMode":"hiking","snapsToPaths":true,"chosenLegs":[]"#
        if let submission { json += #","editedUnderSubmissionID":"\#(submission)""# }
        return Data((json + "}").utf8)
    }

    /// A trail drawn in 1.6, trimmed here, then redrawn by a 1.6 maker: the
    /// line replaced and the plan written back, the trim's record untouched.
    private func trimmedThenRedrawn(in context: ModelContext) throws -> Hike {
        let drawn = Self.line(at: Line.longitude)
        let hike = Fixture.hike(in: context, route: drawn)
        hike.drawnRouteData = Self.plan(editedUnder: nil)
        try context.save()
        let trimmed = RouteEditSave.write(try Self.middleThird(of: drawn), to: hike, replacing: drawn, in: context)
        try #require(trimmed.isSaved)
        try #require(hike.drawnRouteData == nil, "the trim cleared the 1.6 plan")

        hike.replaceRoute(with: Self.line(at: Line.redrawnLongitude))
        hike.drawnRouteData = Self.plan(editedUnder: nil)
        try context.save()
        return hike
    }

    // MARK: A line another build replaced

    @Test("the editor opens on the line a 1.6 maker saved, not on the history before it")
    func theEditorOpensOnTheRedrawnLine() async throws {
        let context = try Fixture.modelContext()
        let hike = try trimmedThenRedrawn(in: context)
        let redrawn = Self.line(at: Line.redrawnLongitude)

        let sources = await RouteEditSources.reading(hike, drawn: hike.route, in: context.container)

        #expect(sources.saved == redrawn)
        #expect(sources.whole.route == redrawn, "not the first line, trimmed")
        #expect(sources.edit?.original == nil, "no original to revert to")
        #expect(sources.edit?.trim == nil)
    }

    @Test("an edit of that line cuts it, and keeps it as the original")
    func anEditCutsTheRedrawnLine() throws {
        let context = try Fixture.modelContext()
        let hike = try trimmedThenRedrawn(in: context)
        let redrawn = Self.line(at: Line.redrawnLongitude)

        let outcome = RouteEditSave.write(try Self.middleThird(of: redrawn), to: hike, replacing: redrawn, in: context)

        #expect(outcome.isSaved)
        #expect(hike.route.allSatisfy { $0.longitude == Line.redrawnLongitude }, "the 1.6 line, cut")
        #expect(hike.originalRoute == redrawn)
        #expect(hike.routeEdit?.describes(hike.route) == true)
        #expect(hike.drawnRouteData == nil)
    }

    @Test("reverting over that line to the history before it is refused")
    func aRevertOverTheRedrawnLineIsRefused() throws {
        let context = try Fixture.modelContext()
        let hike = try trimmedThenRedrawn(in: context)
        let redrawn = Self.line(at: Line.redrawnLongitude)

        #expect(RouteEditSave.revert(hike, from: redrawn, in: context) == .refused(.noOriginal))
        #expect(hike.route == redrawn)
    }

    @Test("a line nothing else has written keeps its history")
    func anUntouchedLineKeepsItsHistory() async throws {
        let context = try Fixture.modelContext()
        let drawn = Self.line(at: Line.longitude)
        let hike = Fixture.hike(in: context, route: drawn)
        try context.save()
        let trimmed = RouteEditSave.write(try Self.middleThird(of: drawn), to: hike, replacing: drawn, in: context)
        try #require(trimmed.isSaved)

        let sources = await RouteEditSources.reading(hike, drawn: hike.route, in: context.container)

        #expect(sources.saved == drawn)
        #expect(sources.edit?.original != nil)
        #expect(sources.edit?.trim != nil)
    }

    // MARK: A shared trail a 1.6 maker edited

    @Test("a trail a 1.6 maker edited while shared says its shared copy is out of date, until a later share")
    func a16EditKeepsTheSharedCopyNotice() throws {
        let context = try Fixture.modelContext()
        let drawn = Self.line(at: Line.longitude)
        let hike = Fixture.hike(in: context, route: drawn)
        hike.communitySubmissionID = Line.submission
        hike.drawnRouteData = Self.plan(editedUnder: Line.submission)
        try context.save()
        #expect(hike.isSharedCopyOutOfDate)

        let trimmed = RouteEditSave.write(try Self.middleThird(of: drawn), to: hike, replacing: drawn, in: context)
        try #require(trimmed.isSaved)
        #expect(hike.drawnRouteData == nil)
        #expect(hike.isSharedCopyOutOfDate, "the edit here keeps the notice")

        hike.communitySubmissionID = "submission-2"
        #expect(!hike.isSharedCopyOutOfDate, "a fresh share is the edited route")
    }

    @Test("a plan edited under an earlier share says nothing about the current one")
    func anEarlierShareSaysNothing() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: Self.line(at: Line.longitude))
        hike.communitySubmissionID = "submission-2"
        hike.drawnRouteData = Self.plan(editedUnder: Line.submission)

        #expect(!hike.isSharedCopyOutOfDate)
    }
}
