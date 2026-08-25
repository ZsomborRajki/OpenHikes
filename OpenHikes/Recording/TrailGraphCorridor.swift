//
//  TrailGraphCorridor.swift
//  OpenHikes
//
//  The coordinates a recording has to name for its trail graph to cover the
//  ground it never observed, and the regions worth having on disk before it
//  gets there.
//
//  Prefetching during a walk can only ever request the region a fix arrived
//  in. That is the wrong set for exactly the case that most needs a mapped
//  route: a phone in a pack, a suspended app, a wooded valley. The stretch
//  with no fixes is also the stretch no region was requested for, so the
//  matcher reaches it with nothing to route through and draws a straight line
//  — which is what a spotty recording looks like from the far side.
//

import CoreLocation
import Foundation
import OpenHikesShared

nonisolated enum TrailGraphCorridor {
    /// How far apart samples along an unobserved stretch are placed.
    ///
    /// A cache region is a z12 tile: about 9.8 km across at the equator,
    /// narrowing with latitude to roughly 4.9 km at 60°N and 3.3 km at 70°N.
    /// Sampling has to be fine enough that a straight line cannot step over a
    /// region without landing inside it, so this sits below half the narrowest
    /// tile a hike is plausibly recorded in.
    static let samplingIntervalMeters: CLLocationDistance = 2000

    /// Ceiling on the samples one stretch contributes, so a corrupt pair of
    /// fixes on opposite sides of the world cannot become an unbounded list.
    /// The regions those samples resolve to are bounded separately by
    /// ``maximumGapRegions``; this bounds the arithmetic done before reaching
    /// that.
    static let maximumSamplesPerGap = 32

    /// Highest number of regions one recording will download to close its
    /// gaps. Deliberately below ``TrailGraphProviding/maximumPrefetchRegions``,
    /// because unlike a hike being opened for analysis this runs while the
    /// walker waits for Stop to finish.
    static let maximumGapRegions = 8

    /// Points along the stretches `points` lost its fixes across, and nothing
    /// else.
    ///
    /// Empty for a recording that never dropped a fix, which is what keeps the
    /// download this feeds off the path of an ordinary hike.
    static func coordinates(
        bridging points: [RecordingPoint]
    ) -> [CLLocationCoordinate2D] {
        guard points.count > 1 else { return [] }
        var result: [CLLocationCoordinate2D] = []
        for index in 1..<points.count
        where TrailMatcher.isGap(from: points[index - 1], to: points[index]) {
            result.append(
                contentsOf: samples(
                    from: points[index - 1].coordinate,
                    to: points[index].coordinate
                )
            )
        }
        return result
    }

    /// Interior samples along the straight line between two fixes.
    ///
    /// The endpoints are left out on purpose: they are fixes, so the regions
    /// containing them are already named by the recording itself.
    static func samples(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> [CLLocationCoordinate2D] {
        let distance = RouteGeometry.distanceMeters(from: start, to: end)
        guard distance > samplingIntervalMeters else { return [] }
        let steps = min(
            maximumSamplesPerGap,
            Int(distance / samplingIntervalMeters)
        )
        guard steps > 0 else { return [] }
        return (1...steps).map { step in
            RouteGeometry.interpolate(
                from: start,
                to: end,
                fraction: Double(step) / Double(steps + 1)
            )
        }
    }

    /// The distinct regions `coordinates` fall in, in first-seen order and
    /// capped at `limit`, paired with a coordinate inside each.
    ///
    /// Returns coordinates rather than regions because that is what
    /// ``TrailGraphProviding/prefetch(around:)`` takes — a provider that keys
    /// its cache differently, or not at all, stays free to.
    static func prefetchCoordinates(
        for coordinates: [CLLocationCoordinate2D],
        provider: any TrailGraphProviding,
        limit: Int = maximumGapRegions
    ) -> [CLLocationCoordinate2D] {
        var seen: Set<TrailGraphRegion> = []
        var result: [CLLocationCoordinate2D] = []
        for coordinate in coordinates {
            guard let region = provider.region(containing: coordinate),
                  seen.insert(region).inserted else { continue }
            result.append(coordinate)
            if result.count >= limit { break }
        }
        return result
    }
}

// MARK: - Neighbouring regions

nonisolated extension TrailGraphProviding {
    /// A coordinate inside each of the eight regions surrounding the one
    /// containing `coordinate`.
    ///
    /// This is the only way a graph reaches the disk *before* it is needed.
    /// The per-fix prefetch requests the region a fix arrived in, which is one
    /// region too late for a boundary crossed while the app was suspended, and
    /// no use whatsoever once the connection is gone — the walk into the dead
    /// zone is exactly when the download can no longer be made.
    ///
    /// Rows are clamped and columns wrapped, because latitude is bounded and
    /// longitude is not: there is no region north of the top row, but there is
    /// one west of column zero.
    ///
    /// Empty for a provider with no regions to speak of — a bundled fixture
    /// covers wherever it covers, and has no neighbours to fetch.
    func neighbouringRegionCoordinates(
        around coordinate: CLLocationCoordinate2D
    ) -> [CLLocationCoordinate2D] {
        guard let region = region(containing: coordinate) else { return [] }
        let count = 1 << region.zoom
        var result: [CLLocationCoordinate2D] = []
        for deltaY in -1...1 {
            let row = region.y + deltaY
            guard row >= 0, row < count else { continue }
            for deltaX in -1...1 where deltaX != 0 || deltaY != 0 {
                result.append(
                    Self.regionCentre(
                        zoom: region.zoom,
                        x: SlippyTileMath.wrap(region.x + deltaX, to: count),
                        y: row
                    )
                )
            }
        }
        return result
    }

    /// The centre of a slippy tile, taken in unit-Mercator space so it is the
    /// tile's own middle rather than the midpoint of its corner latitudes.
    static func regionCentre(
        zoom: Int,
        x: Int,
        y: Int
    ) -> CLLocationCoordinate2D {
        let side = Double(1 << zoom)
        return CLLocationCoordinate2D(
            latitude: Mercator.latitude(unitY: (Double(y) + 0.5) / side),
            longitude: Mercator.longitude(unitX: (Double(x) + 0.5) / side)
        )
    }
}
