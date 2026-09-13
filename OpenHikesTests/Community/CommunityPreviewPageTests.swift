//
//  CommunityPreviewPageTests.swift
//  OpenHikesTests
//
//  What a shared hike's preview is measured from, and what it can therefore
//  draw.
//
//  The screen reuses the hike detail screen's own views — the elevation chart,
//  the stat grid, the surface and difficulty sections — and hands them values
//  `CommunityHikeView.prepare(_:)` computes. Two of those computations are
//  invisible in the picture they produce, which is what makes them worth
//  pinning here rather than in a simulator.
//
//  The first is *which* distance the page states. A page built off
//  ``CommunityListing/distanceMeters`` renders perfectly; it is wrong only
//  against the hike the Add button is about to create, which measures its own
//  route. Nobody sees that disagreement until both numbers are on screen, on
//  two screens, minutes apart.
//
//  The second is the difference between *not yet* and *none*. The chart's
//  empty state says "no elevation data", and saying that about a route still
//  being walked would be an answer the screen has not got — which is why
//  `prepare` hands back one optional rather than a profile plus an array, and
//  why the number of plotted samples is what chooses between the chart and the
//  placeholder.
//

import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Community preview page")
struct CommunityPreviewPageTests {
    /// The same formatting ``HikeDetailPreparation`` puts on the Distance
    /// tile, so what is compared is the string a hiker reads rather than a
    /// double nobody is shown.
    nonisolated private static func formatted(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    private static func detail(
        listing: CommunityListing = .stub(),
        route: [RouteCoordinate] = Fixture.ridgeRoute
    ) -> CommunityHikeDetail {
        CommunityHikeDetail(
            listing: listing,
            route: route,
            trackDescription: "A ridge walk",
            photoPins: [],
            photoFileURLs: []
        )
    }

    private static func distanceStat(
        of page: HikeDetailPreparedContent
    ) -> String? {
        page.stats.first { $0.label == "Distance" }?.value
    }

    /// The two screens a hiker compares have to state the same length, and the
    /// listing's own figure is the one that can disagree: it is typed by a
    /// reviewer in the CloudKit Console, while both the preview and the
    /// imported hike measure the route that was actually uploaded.
    ///
    /// Asserted against the imported hike rather than against
    /// ``CommunityImport/routeLength(of:)`` directly, because agreeing with
    /// that function is not the claim — agreeing with the hike the Add button
    /// makes is.
    @Test("the page states the route's length, not the listing's")
    func statedDistanceMatchesTheImportedHike() async throws {
        let context = try Fixture.modelContext()
        // A listing claiming a wildly different length from its own route,
        // exactly as a mistyped Console field would.
        let listing = CommunityListing.stub(distanceMeters: 999_999)
        let detail = Self.detail(listing: listing)

        let page = try #require(await CommunityHikeView.prepare(detail))
        let outcome = await CommunityImport.importHike(detail, into: context)
        let hike = try #require(outcome.hike)

        #expect(Self.distanceStat(of: page) == Self.formatted(hike.distanceMeters))
        // Without this the expectation above would also pass on a page that
        // copied the listing, in the case where the listing happened to be
        // right.
        #expect(Self.distanceStat(of: page) != Self.formatted(listing.distanceMeters))
    }

    /// The chart is drawn off the plotted samples, so a route carrying
    /// elevations has to produce more than one of them — a profile of a single
    /// point is a chart with nothing to interpolate between, and the screen
    /// treats it as no elevation data at all.
    @Test("a route with elevations gives the chart something to plot")
    func aRouteWithElevationsIsPlotted() async throws {
        let page = try #require(await CommunityHikeView.prepare(Self.detail()))

        #expect(page.profile.samples.count > 1)
        #expect(page.profile.elevationRange != nil)
    }

    /// The half that decides the placeholder. A shared route with no
    /// elevations still prepares — the stat tiles and the page around them are
    /// fine — and what is missing is only the chart, which is a thing the
    /// screen can say rather than a failure it has to hide.
    @Test("a route without elevations prepares, and plots nothing")
    func aRouteWithoutElevationsIsAnAnswer() async throws {
        let flat = Fixture.ridgeRoute.map { point in
            RouteCoordinate(
                latitude: point.latitude,
                longitude: point.longitude,
                timestamp: point.timestamp
            )
        }

        let page = try #require(
            await CommunityHikeView.prepare(Self.detail(route: flat))
        )

        // Prepared, not absent: `nil` back from `prepare` means the walk was
        // cancelled, and a screen showing the placeholder for that would be
        // reporting "no elevation data" about a hiker who backed out.
        #expect(page.profile.samples.isEmpty)
        #expect(Self.distanceStat(of: page) != nil)
    }
}
