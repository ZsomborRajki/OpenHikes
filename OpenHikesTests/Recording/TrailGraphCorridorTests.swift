//
//  TrailGraphCorridorTests.swift
//  OpenHikesTests
//
//  The densified corridor that gets a walking graph downloaded for ground a
//  recording never reported a fix from.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesShared
import Testing

@Suite("Trail graph corridor")
struct TrailGraphCorridorTests {
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    private func point(
        _ latitude: Double,
        _ longitude: Double,
        at offset: TimeInterval
    ) -> RecordingPoint {
        RecordingPoint(
            latitude: latitude,
            longitude: longitude,
            timestamp: start.addingTimeInterval(offset),
            horizontalAccuracy: 8
        )
    }

    @Test("a densely recorded route contributes no corridor at all")
    func denseRouteHasNoCorridor() {
        let points = (0..<20).map { step in
            point(47.63 + Double(step) * 0.0005, 12.86, at: Double(step) * 10)
        }

        #expect(TrailGraphCorridor.coordinates(bridging: points).isEmpty)
    }

    @Test("an unobserved stretch is sampled finely enough to hit every region")
    func gapIsSampledBelowRegionWidth() {
        // Roughly 11 km apart, an hour of silence between them.
        let points = [
            point(47.6300, 12.8600, at: 0),
            point(47.7300, 12.8600, at: 3600),
        ]

        let corridor = TrailGraphCorridor.coordinates(bridging: points)

        #expect(!corridor.isEmpty)
        // Interior samples only: the fixes themselves are already covered by
        // the caller's own coordinate list.
        #expect(corridor.allSatisfy { sample in
            sample.latitude > 47.6300 && sample.latitude < 47.7300
        })
        var previous = points[0].coordinate
        for sample in corridor + [points[1].coordinate] {
            let step = RouteGeometry.distanceMeters(from: previous, to: sample)
            #expect(step <= TrailGraphCorridor.samplingIntervalMeters + 1)
            previous = sample
        }
    }

    @Test("a corrupt pair of fixes cannot produce an unbounded corridor")
    func absurdGapIsBounded() {
        let points = [
            point(-33.86, 151.20, at: 0),
            point(51.50, -0.12, at: 7200),
        ]

        let corridor = TrailGraphCorridor.coordinates(bridging: points)

        #expect(corridor.count <= TrailGraphCorridor.maximumSamplesPerGap)
    }

    @Test("a deliberate pause contributes no corridor")
    func resumedLegIsNotBridged() {
        var resumed = point(47.7300, 12.8600, at: 3600)
        resumed.flags.insert(.resumed)

        #expect(
            TrailGraphCorridor
                .coordinates(bridging: [point(47.6300, 12.8600, at: 0), resumed])
                .isEmpty
        )
    }

    @Test("prefetch coordinates are deduplicated by region and capped")
    func prefetchCoordinatesAreCapped() {
        let provider = StubTrailGraphProvider(graph: .empty)
        // Far more distinct regions than the cap allows, in order.
        let corridor = (0..<40).map { step in
            CLLocationCoordinate2D(
                latitude: 47.63,
                longitude: 12.0 + Double(step) * 0.5
            )
        }

        let selected = TrailGraphCorridor.prefetchCoordinates(
            for: corridor,
            provider: provider
        )

        #expect(selected.count == TrailGraphCorridor.maximumGapRegions)
        let regions = selected.compactMap(provider.region(containing:))
        #expect(Set(regions).count == selected.count)
    }

    @Test("a region's neighbours surround it without repeating it")
    func neighbouringRegionsSurroundTheOriginal() throws {
        let provider = SlippyRegionProvider()
        let here = CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86)
        let origin = try #require(provider.region(containing: here))

        let neighbours = provider
            .neighbouringRegionCoordinates(around: here)
            .compactMap(provider.region(containing:))

        #expect(neighbours.count == 8)
        #expect(!neighbours.contains(origin))
        #expect(Set(neighbours).count == 8)
        #expect(neighbours.allSatisfy { region in
            abs(region.x - origin.x) <= 1 && abs(region.y - origin.y) <= 1
        })
    }

    @Test("the top row has no neighbours above it")
    func polarRegionIsClamped() {
        let provider = SlippyRegionProvider()
        // Inside the topmost z12 row, which Web Mercator caps at ~85.05°N.
        let nearThePole = CLLocationCoordinate2D(
            latitude: (
                SlippyTileMath.lat(y: 0, z: SlippyRegionProvider.zoom)
                    + SlippyTileMath.lat(y: 1, z: SlippyRegionProvider.zoom)
            ) / 2,
            longitude: 0
        )

        let neighbours = provider
            .neighbouringRegionCoordinates(around: nearThePole)
            .compactMap(provider.region(containing:))

        // Two rows instead of three: its own and the one below it.
        #expect(provider.region(containing: nearThePole)?.y == 0)
        #expect(neighbours.count == 5)
        #expect(Set(neighbours.map(\.y)) == [0, 1])
    }

    @Test("neighbours across the antimeridian wrap rather than disappear")
    func antimeridianNeighboursWrap() throws {
        let provider = SlippyRegionProvider()
        let here = CLLocationCoordinate2D(latitude: 0, longitude: 179.99)
        let origin = try #require(provider.region(containing: here))

        let neighbours = provider
            .neighbouringRegionCoordinates(around: here)
            .compactMap(provider.region(containing:))

        #expect(neighbours.count == 8)
        #expect(neighbours.contains { $0.x == 0 })
        #expect(origin.x == (1 << origin.zoom) - 1)
    }

    @Test("an unrepresentable coordinate has no neighbours to prefetch")
    func unrepresentableCoordinateHasNoNeighbours() {
        let provider = StubTrailGraphProvider(graph: .empty)
        let nowhere = CLLocationCoordinate2D(latitude: .nan, longitude: .nan)

        #expect(provider.neighbouringRegionCoordinates(around: nowhere).isEmpty)
    }
}

/// A provider whose only real behaviour is the z12 slippy-tile grid the app
/// actually uses, so the neighbour arithmetic is tested against the coordinate
/// system it ships with rather than against a stub's convenient one.
private struct SlippyRegionProvider: TrailGraphProviding {
    static let zoom = 12

    func region(
        containing coordinate: CLLocationCoordinate2D
    ) -> TrailGraphRegion? {
        guard Mercator.isRepresentable(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        ) else { return nil }
        let indices = (
            x: SlippyTileMath.tileX(coordinate.longitude, z: Self.zoom),
            y: SlippyTileMath.tileY(coordinate.latitude, z: Self.zoom)
        )
        return TrailGraphRegion(zoom: Self.zoom, x: indices.x, y: indices.y)
    }

    // Only the region arithmetic is under test here; nothing fetches.
    func prefetch(around coordinate: CLLocationCoordinate2D) {
        // Deliberately inert.
    }

    func cachedGraph(
        covering coordinates: [CLLocationCoordinate2D]
    ) -> TrailGraph? { nil }

    func hasCompleteCachedGraph(
        covering coordinates: [CLLocationCoordinate2D]
    ) -> Bool { true }
}
