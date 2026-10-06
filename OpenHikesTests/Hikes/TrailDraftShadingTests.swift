//
//  TrailDraftShadingTests.swift
//  OpenHikesTests
//
//  The trail being drawn, coloured by difficulty and by steepness: what is
//  measured, when the maker's *Color By* section is offered, and that an
//  answer about a line that has since moved is never drawn over the new one.
//
//  The grades are measured against the bundled trail-tag fixture, as
//  `RouteShadingTests` measures a saved hike's, so the maker and the hike it
//  saves are coloured from one answer about the same ground. How the map
//  draws them is `MapCoordinatorTests+TrailDraftShading.swift`.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Synchronization
import Testing

@MainActor
@Suite("Trail draft shading")
struct TrailDraftShadingTests {
    /// A graph that is never complete in the cache, and counts every time it
    /// is asked to download.
    nonisolated private final class UncachedProvider: TrailGraphProviding, @unchecked Sendable {
        private let prefetches = Mutex(0)
        var prefetchCount: Int { prefetches.withLock { $0 } }

        func region(containing coordinate: CLLocationCoordinate2D) -> TrailGraphRegion? { nil }

        func prefetch(around coordinate: CLLocationCoordinate2D) {
            prefetches.withLock { $0 += 1 }
        }

        func cachedGraph(covering coordinates: [CLLocationCoordinate2D]) -> TrailGraph? { nil }

        func hasCompleteCachedGraph(covering coordinates: [CLLocationCoordinate2D]) -> Bool { false }
    }

    private enum Line {
        static let longitude: Double = 12.86
        static let south: Double = 47.6300
        static let north: Double = 47.6400
        /// About 1.1 km apart, so a hundred metres between them is a 9%
        /// grade: the scale's second step.
        static let low: Double = 600
        static let high: Double = 700
    }

    private static func straightDraft() -> TrailDraft {
        let draft = TrailDraft()
        draft.append(CLLocationCoordinate2D(latitude: Line.south, longitude: Line.longitude))
        draft.append(CLLocationCoordinate2D(latitude: Line.north, longitude: Line.longitude))
        return draft
    }

    /// Heights read at every point of `draft`'s line, as the maker's
    /// elevation source would hand them over.
    private static func heights(for draft: TrailDraft, _ metres: [Double]) -> RouteHeightSamples {
        let route = draft.routeCoordinates
        return RouteHeightSamples(
            routePointCount: route.count,
            indexes: Array(route.indices),
            coordinates: route,
            heights: metres
        )
    }

    /// A draft drawn point by point along the fixture GPX, which is the
    /// geometry the fixture graph was tagged on.
    private static func fixtureDraft() throws -> TrailDraft {
        let url = try #require(
            Bundle.main.url(forResource: UITestTrailTagFixture.gpxName, withExtension: "gpx"),
            "the app bundle should carry the GPX fixture UI tests import"
        )
        let draft = TrailDraft()
        for point in try GPXImport.load(from: url).route {
            draft.append(point.clCoordinate)
        }
        return draft
    }

    @Test("heights colour a hiking line by steepness, and offer Elevation")
    func heightsColourByElevation() async {
        let draft = Self.straightDraft()
        let shading = TrailDraftShading(draft: draft, provider: nil)

        shading.heightsDidLand(Self.heights(for: draft, [Line.low, Line.high]))
        await shading.measurement?.value

        #expect(shading.stretches(for: .elevation).map(\.shade) == [.easy])
        #expect(shading.stretches(for: .difficulty).isEmpty)
        #expect(shading.stretches(for: .off).isEmpty)
        #expect(shading.offered == [.elevation])
    }

    @Test("a line along graded paths is coloured by difficulty from the cached graph")
    func gradedPathsColourByDifficulty() async throws {
        let draft = try Self.fixtureDraft()
        let provider = try #require(BundledTrailGraphProvider(fixtureName: UITestTrailTagFixture.trailGraphName))
        let shading = TrailDraftShading(draft: draft, provider: provider)

        shading.drawingDidChange()
        await shading.measurement?.value

        #expect(!shading.stretches(for: .difficulty).isEmpty)
        #expect(shading.offered == [.difficulty])
    }

    /// Every leg landing asks again, and a line still being drawn is not
    /// worth an Overpass request — see `HikeTrailAnalysis.difficultyRuns`.
    @Test("grading the drawn line never downloads the trail graph")
    func gradingNeverDownloads() async {
        let provider = UncachedProvider()
        let shading = TrailDraftShading(draft: Self.straightDraft(), provider: provider)

        shading.drawingDidChange()
        await shading.measurement?.value

        #expect(provider.prefetchCount == 0)
        #expect(shading.stretches(for: .difficulty).isEmpty)
        #expect(shading.offered.isEmpty)
    }

    /// The colours go with the line, but the section stays: otherwise it
    /// would hide and come back with every point put down.
    @Test("a moved line drops its colours and keeps the offer, until the drawing is cleared")
    func movingKeepsTheOfferAndClearingDropsIt() async {
        let draft = Self.straightDraft()
        let shading = TrailDraftShading(draft: draft, provider: nil)
        shading.heightsDidLand(Self.heights(for: draft, [Line.low, Line.high]))
        await shading.measurement?.value
        let measured = shading.revision

        shading.drawingDidChange()

        #expect(shading.stretches(for: .elevation).isEmpty)
        #expect(shading.revision != measured, "the map has to be told the colours went")
        #expect(shading.offered == [.elevation])

        shading.clear()

        #expect(shading.offered.isEmpty)
    }

    @Test("an answer about a line that has since moved is dropped")
    func staleAnswersAreDropped() async throws {
        let draft = Self.straightDraft()
        let shading = TrailDraftShading(draft: draft, provider: nil)
        shading.heightsDidLand(Self.heights(for: draft, [Line.low, Line.high]))
        let stale = try #require(shading.measurement)

        draft.append(CLLocationCoordinate2D(latitude: Line.north + 0.01, longitude: Line.longitude))
        shading.drawingDidChange()
        await stale.value

        #expect(shading.stretches(for: .elevation).isEmpty)
        #expect(shading.offered.isEmpty)
    }

    @Test("heights read for another line colour nothing")
    func heightsForAnotherLineAreRefused() {
        let draft = Self.straightDraft()
        let shading = TrailDraftShading(draft: draft, provider: nil)
        let samples = Self.heights(for: draft, [Line.low, Line.high])

        draft.append(CLLocationCoordinate2D(latitude: Line.north + 0.01, longitude: Line.longitude))
        shading.heightsDidLand(samples)

        #expect(shading.measurement == nil)
    }

    /// Apple's directions run along roads, where neither a SAC grade nor the
    /// grade of a footpath is what a line is read for.
    @Test("a line drawn for another travel mode is not coloured")
    func otherTravelModesAreNotColoured() throws {
        let draft = Self.straightDraft()
        draft.setTravelMode(.walking)
        let provider = try #require(BundledTrailGraphProvider(fixtureName: UITestTrailTagFixture.trailGraphName))
        let shading = TrailDraftShading(draft: draft, provider: provider)

        shading.drawingDidChange()
        shading.heightsDidLand(Self.heights(for: draft, [Line.low, Line.high]))

        #expect(shading.measurement == nil)
    }
}
