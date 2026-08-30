//
//  TrailBasemapTests.swift
//  OpenHikesSharedTests
//
//  The widget's basemap geometry: framing a trail into a region to render,
//  recovering that region from a finished snapshot, and getting the trail
//  back onto the right pixels afterwards. All of it fails silently if it's
//  wrong — a trail drawn next to the valley it's in still looks like a map —
//  so it's checked end to end here rather than left to be noticed on a home
//  screen.
//

import CoreGraphics
import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Trail basemaps")
struct TrailBasemapTests {
    /// A ~2 km trail with bends in both axes, near Cupertino.
    static let trail: [SharedTrailSnapshot.CodableCoordinate] = [
        .init(latitude: 37.3349, longitude: -122.0140),
        .init(latitude: 37.3372, longitude: -122.0098),
        .init(latitude: 37.3358, longitude: -122.0050),
        .init(latitude: 37.3400, longitude: -122.0020),
        .init(latitude: 37.3440, longitude: -122.0060),
    ]

    static var coverage: UnitMercatorRect {
        UnitMercatorRect(bounding: trail) ?? UnitMercatorRect(originX: 0, originY: 0, width: 0, height: 0)
    }

    /// A short walk on Taveuni, which the 180th meridian runs straight
    /// through — the shape a bounding box has to answer the short way round.
    static let antimeridianTrail: [SharedTrailSnapshot.CodableCoordinate] = [
        .init(latitude: -16.7500, longitude: 179.9800),
        .init(latitude: -16.7600, longitude: 179.9950),
        .init(latitude: -16.7700, longitude: -179.9900),
        .init(latitude: -16.7800, longitude: -179.9750),
    ]

    /// Real widget point sizes, so variant selection is exercised against
    /// what the system actually hands the view.
    static let widgetSizes: [(name: String, size: CGSize)] = [
        ("small", CGSize(width: 158, height: 158)),
        ("medium", CGSize(width: 338, height: 158)),
        ("large", CGSize(width: 338, height: 354)),
        ("extraLarge", CGSize(width: 715, height: 354)),
    ]

    // MARK: Bounding

    @Test("bounding box contains every point")
    func boundingContainsTrail() throws {
        let trailCoverage = try #require(UnitMercatorRect(bounding: Self.trail))
        for point in Self.trail {
            let normalized = trailCoverage.normalizedPoint(latitude: point.latitude, longitude: point.longitude)
            #expect((-1e-9...(1 + 1e-9)).contains(normalized.x))
            #expect((-1e-9...(1 + 1e-9)).contains(normalized.y))
        }
    }

    @Test("empty input has no bounding box")
    func boundingEmpty() {
        #expect(UnitMercatorRect(bounding: []) == nil)
    }

    // MARK: Framing

    @Test("framing hits the requested shape", arguments: TrailBasemapVariant.allCases)
    func framedAspect(variant: TrailBasemapVariant) {
        let framed = Self.coverage.framed(toAspectRatio: variant.aspectRatio)
        #expect(abs(framed.width / framed.height - variant.aspectRatio) < 1e-9)
    }

    @Test("framing never crops the trail", arguments: TrailBasemapVariant.allCases)
    func framedContainsTrail(variant: TrailBasemapVariant) {
        let trailCoverage = Self.coverage
        let framed = trailCoverage.framed(toAspectRatio: variant.aspectRatio)
        #expect(framed.originX <= trailCoverage.originX)
        #expect(framed.originY <= trailCoverage.originY)
        #expect(framed.originX + framed.width >= trailCoverage.originX + trailCoverage.width)
        #expect(framed.originY + framed.height >= trailCoverage.originY + trailCoverage.height)
    }

    @Test("a single point still gets a legible region", arguments: TrailBasemapVariant.allCases)
    func framedDegenerate(variant: TrailBasemapVariant) throws {
        let point = try #require(UnitMercatorRect(bounding: [Self.trail[0]]))
        #expect(point.width == 0 && point.height == 0)

        let framed = point.framed(toAspectRatio: variant.aspectRatio)
        let heightMeters = framed.height * Mercator.metersPerUnit(atLatitude: framed.centerLatitude)
        #expect(heightMeters > 300)
        #expect(heightMeters < 5000)
    }

    @Test("a trail at the top of the world gets a shifted window, not one off the edge")
    func framedNearPole() throws {
        let arctic = try #require(UnitMercatorRect(bounding: [
            .init(latitude: 84.9, longitude: 10.0),
            .init(latitude: 85.0, longitude: 10.1),
        ]))
        let framed = arctic.framed(toAspectRatio: 1)
        #expect(framed.originY >= 0)
        #expect(framed.originY + framed.height <= 1 + 1e-12)
    }

    @Test("a degenerate aspect ratio is refused rather than propagated")
    func framedInvalidAspect() {
        let trailCoverage = Self.coverage
        #expect(trailCoverage.framed(toAspectRatio: .nan) == trailCoverage)
        #expect(trailCoverage.framed(toAspectRatio: 0) == trailCoverage)
    }

    // MARK: Registration

    /// Stands in for `MKMapSnapshotter.Snapshot.point(for:)`: renders
    /// `actual` into an image of `size`, in a coordinate space whose y may
    /// point either way (UIKit vs AppKit).
    private func projector(
        actual: UnitMercatorRect,
        size: CGSize,
        flipped: Bool
    ) -> (Double, Double) -> CGPoint {
        { latitude, longitude in
            let unit = Mercator.unitPoint(latitude: latitude, longitude: longitude)
            let x = (unit.x - actual.originX) / actual.width * size.width
            let y = (unit.y - actual.originY) / actual.height * size.height
            return CGPoint(x: x, y: flipped ? size.height - y : y)
        }
    }

    /// The core claim: measuring a snapshot from two reference points
    /// recovers the region it really covers — even when the snapshotter
    /// rendered something other than what it was asked for, and whichever
    /// way its y axis points.
    @Test(
        "registration recovers the rendered region",
        arguments: [
            (0.0, false), (0.07, false), (-0.05, false), (0.0, true), (0.07, true),
        ]
    )
    func registration(drift: Double, flipped: Bool) throws {
        let size = TrailBasemapVariant.square.pointSize
        let requested = Self.coverage.framed(toAspectRatio: TrailBasemapVariant.square.aspectRatio)
        let actual = UnitMercatorRect(
            originX: requested.originX + requested.width * drift,
            originY: requested.originY - requested.height * drift,
            width: requested.width * (1 + drift),
            height: requested.height * (1 + drift)
        )
        let pointFor = projector(actual: actual, size: size, flipped: flipped)

        let northWest = (
            latitude: Mercator.latitude(unitY: requested.originY),
            longitude: Mercator.longitude(unitX: requested.originX)
        )
        let southEast = (
            latitude: Mercator.latitude(unitY: requested.originY + requested.height),
            longitude: Mercator.longitude(unitX: requested.originX + requested.width)
        )
        let pointNW = pointFor(northWest.latitude, northWest.longitude)
        let pointSE = pointFor(southEast.latitude, southEast.longitude)

        let measured = try #require(UnitMercatorRect(
            imageWidth: Double(size.width),
            imageHeight: Double(size.height),
            .init(
                latitude: northWest.latitude,
                longitude: northWest.longitude,
                x: Double(pointNW.x),
                y: Double(pointNW.y)
            ),
            .init(
                latitude: southEast.latitude,
                longitude: southEast.longitude,
                x: Double(pointSE.x),
                y: Double(pointSE.y)
            )
        ))

        // Always top-left-origin with a positive extent, whatever came in.
        #expect(measured.width > 0)
        #expect(measured.height > 0)
        #expect(measured.isEquivalent(to: actual, tolerance: 1e-9))

        // And every trail point lands where the image put it.
        for point in Self.trail {
            let normalized = measured.normalizedPoint(latitude: point.latitude, longitude: point.longitude)
            let drawn = CGPoint(x: normalized.x * size.width, y: normalized.y * size.height)
            let truth = pointFor(point.latitude, point.longitude)
            let expected = flipped ? CGPoint(x: truth.x, y: size.height - truth.y) : truth
            #expect(hypot(Double(drawn.x - expected.x), Double(drawn.y - expected.y)) < 0.001)
        }
    }

    @Test("two references too close together are refused")
    func registrationDegenerate() {
        #expect(UnitMercatorRect(
            imageWidth: 320,
            imageHeight: 320,
            .init(latitude: 37.33, longitude: -122.01, x: 10, y: 10),
            .init(latitude: 37.34, longitude: -122.02, x: 10.5, y: 300)
        ) == nil)
    }

    @Test("a zero-sized image is refused")
    func registrationEmptyImage() {
        #expect(UnitMercatorRect(
            imageWidth: 0,
            imageHeight: 0,
            .init(latitude: 37.34, longitude: -122.02, x: 0, y: 0),
            .init(latitude: 37.33, longitude: -122.01, x: 320, y: 320)
        ) == nil)
    }

    // MARK: Variant selection and cropping

    @Test("each widget size picks a sensible variant")
    func variantSelection() {
        #expect(TrailBasemapVariant.best(forAspectRatio: 158.0 / 158) == .square)
        #expect(TrailBasemapVariant.best(forAspectRatio: 338.0 / 354) == .square)
        #expect(TrailBasemapVariant.best(forAspectRatio: 338.0 / 158) == .wide)
        #expect(TrailBasemapVariant.best(forAspectRatio: 715.0 / 354) == .wide)
        #expect(TrailBasemapVariant.best(forAspectRatio: .nan) == .square)
        #expect(TrailBasemapVariant.best(forAspectRatio: 0) == .square)
    }

    /// The padding is only worth having if it's what the aspect-fill crop
    /// eats. At every real widget size, the whole trail has to survive.
    @Test("the trail survives the crop at every widget size")
    func trailSurvivesCrop() {
        for (name, viewSize) in Self.widgetSizes {
            let variant = TrailBasemapVariant.best(forAspectRatio: viewSize.width / viewSize.height)
            let framed = Self.coverage.framed(toAspectRatio: variant.aspectRatio)
            let imageRect = TrailMapView.aspectFillRect(aspectRatio: variant.aspectRatio, in: viewSize)

            // Fill, not fit: no gaps at any edge.
            #expect(imageRect.minX <= 0.001, "\(name) leaves a gap")
            #expect(imageRect.minY <= 0.001, "\(name) leaves a gap")
            #expect(imageRect.maxX >= viewSize.width - 0.001, "\(name) leaves a gap")
            #expect(imageRect.maxY >= viewSize.height - 0.001, "\(name) leaves a gap")

            for point in Self.trail {
                let normalized = framed.normalizedPoint(latitude: point.latitude, longitude: point.longitude)
                let drawn = CGPoint(
                    x: imageRect.minX + normalized.x * imageRect.width,
                    y: imageRect.minY + normalized.y * imageRect.height
                )
                #expect((0...viewSize.width).contains(drawn.x), "\(name) crops the trail horizontally")
                #expect((0...viewSize.height).contains(drawn.y), "\(name) crops the trail vertically")
            }
        }
    }

    // MARK: Staleness

    @Test("only a real move triggers a re-render")
    func staleness() throws {
        let trailCoverage = Self.coverage
        #expect(trailCoverage.isEquivalent(to: trailCoverage))

        let nudged = UnitMercatorRect(
            originX: trailCoverage.originX + trailCoverage.width * 0.005,
            originY: trailCoverage.originY,
            width: trailCoverage.width,
            height: trailCoverage.height
        )
        #expect(trailCoverage.isEquivalent(to: nudged))

        let moved = UnitMercatorRect(
            originX: trailCoverage.originX + trailCoverage.width * 0.5,
            originY: trailCoverage.originY,
            width: trailCoverage.width,
            height: trailCoverage.height
        )
        #expect(!trailCoverage.isEquivalent(to: moved))

        let elsewhere = try #require(UnitMercatorRect(bounding: [
            .init(latitude: 47.6, longitude: -122.3),
        ]))
        #expect(!trailCoverage.isEquivalent(to: elsewhere))

        // A trail extended by a mile is a different region to render.
        let extended = try #require(UnitMercatorRect(bounding: Self.trail + [
            .init(latitude: 37.36, longitude: -121.99),
        ]))
        #expect(!trailCoverage.isEquivalent(to: extended))
    }

    // MARK: Image selection

    @Test("image lookup falls back rather than coming up empty")
    func imageFallback() {
        let rect = Self.coverage
        func basemap(_ variant: TrailBasemapVariant, _ appearance: TrailBasemapAppearance) -> TrailBasemap {
            TrailBasemap(
                fileName: "\(variant.rawValue)-\(appearance.rawValue).jpg",
                variant: variant,
                appearance: appearance,
                pixelWidth: Int(variant.pointSize.width * 2),
                pixelHeight: Int(variant.pointSize.height * 2),
                visibleRect: rect
            )
        }

        let complete = TrailBasemapSet(
            hikeID: UUID(),
            coverage: rect,
            images: TrailBasemapVariant.allCases.flatMap { variant in
                TrailBasemapAppearance.allCases.map { basemap(variant, $0) }
            }
        )
        #expect(complete.image(forAspectRatio: 1, appearance: .dark)?.fileName == "square-dark.jpg")
        #expect(complete.image(forAspectRatio: 2.1, appearance: .light)?.fileName == "wide-light.jpg")

        // Only light rendered (a dark pass failed): still draws.
        let lightOnly = TrailBasemapSet(
            hikeID: UUID(),
            coverage: rect,
            images: [basemap(.square, .light)]
        )
        #expect(lightOnly.image(forAspectRatio: 1, appearance: .dark)?.fileName == "square-light.jpg")
        #expect(lightOnly.image(forAspectRatio: 2.1, appearance: .dark)?.fileName == "square-light.jpg")

        #expect(
            TrailBasemapSet(hikeID: UUID(), coverage: rect, images: [])
                .image(forAspectRatio: 1, appearance: .light) == nil
        )
    }

    @Test("aspect ratio comes from pixels, and survives a nonsense one")
    func basemapAspect() {
        let rect = Self.coverage
        let wide = TrailBasemap(
            fileName: "w",
            variant: .wide,
            appearance: .light,
            pixelWidth: 760,
            pixelHeight: 360,
            visibleRect: rect
        )
        #expect(abs(wide.aspectRatio - 760.0 / 360) < 1e-12)

        let broken = TrailBasemap(
            fileName: "b",
            variant: .wide,
            appearance: .light,
            pixelWidth: 760,
            pixelHeight: 0,
            visibleRect: rect
        )
        #expect(broken.aspectRatio == 1)
    }

    // MARK: Codable

    @Test("a basemap set survives a round trip through the App Group")
    func codableRoundTrip() throws {
        let set = TrailBasemapSet(
            hikeID: UUID(),
            coverage: Self.coverage,
            images: [
                TrailBasemap(
                    fileName: "a.jpg",
                    variant: .wide,
                    appearance: .dark,
                    pixelWidth: 760,
                    pixelHeight: 360,
                    visibleRect: Self.coverage
                ),
            ]
        )
        let decoded = try JSONDecoder().decode(TrailBasemapSet.self, from: JSONEncoder().encode(set))
        #expect(decoded == set)
    }
}

// MARK: - Across the antimeridian

extension TrailBasemapTests {
    /// A route crossing ±180° is the one case where a plain min/max of unit x
    /// answers with the rest of the world instead of the route: the two ends
    /// sit at either edge of the projection, so the box that "contains" them
    /// spans very nearly the whole globe — and that box is what the widget's
    /// basemap gets rendered at, leaving a continent-wide map with a trail
    /// too small to see. Measured in metres, because that is the claim: the
    /// box is as wide as the walk, not as wide as the earth.
    @Test("a trail across the antimeridian is bounded the short way round")
    func boundingAcrossTheAntimeridian() throws {
        let box = try #require(UnitMercatorRect(bounding: Self.antimeridianTrail))
        let widthMeters = box.width * Mercator.metersPerUnit(atLatitude: box.centerLatitude)
        #expect(widthMeters > 1000)
        #expect(widthMeters < 20_000)

        // West edge inside the world, east edge past it — the shape that says
        // "crosses the antimeridian" rather than "starts a lap short of it".
        #expect((0..<1).contains(box.originX))
        #expect(box.originX + box.width > 1)

        for point in Self.antimeridianTrail {
            let normalized = box.normalizedPoint(latitude: point.latitude, longitude: point.longitude)
            #expect((-1e-9...(1 + 1e-9)).contains(normalized.x), "\(point.longitude)° fell outside the box")
            #expect((-1e-9...(1 + 1e-9)).contains(normalized.y))
        }
    }

    /// The same route framed for a real widget shape still has to be a walk
    /// rather than a hemisphere — framing is what the renderer actually hands
    /// the snapshotter.
    @Test("framing a trail across the antimeridian stays tight", arguments: TrailBasemapVariant.allCases)
    func framedAcrossTheAntimeridian(variant: TrailBasemapVariant) throws {
        let box = try #require(UnitMercatorRect(bounding: Self.antimeridianTrail))
        let framed = box.framed(toAspectRatio: variant.aspectRatio)
        #expect(framed.width < 0.01, "the frame grew to \(framed.width) of the world")
        #expect((0..<1).contains(framed.originX))

        for point in Self.antimeridianTrail {
            let normalized = framed.normalizedPoint(latitude: point.latitude, longitude: point.longitude)
            #expect((0...1).contains(normalized.x), "\(point.longitude)° was framed out of the image")
            #expect((0...1).contains(normalized.y))
        }
    }

    /// The control. Every route that does *not* cross ±180° has to keep the
    /// box it always had — a cyclic span is only an improvement if it agrees
    /// with the ordinary answer everywhere else, including a route that
    /// straddles the prime meridian, where the wrap does not apply.
    @Test("an ordinary trail is bounded exactly as before")
    func boundingIsUnchangedAwayFromTheAntimeridian() throws {
        let greenwich: [SharedTrailSnapshot.CodableCoordinate] = [
            .init(latitude: 51.4780, longitude: -0.0050),
            .init(latitude: 51.4790, longitude: 0.0000),
            .init(latitude: 51.4800, longitude: 0.0060),
        ]
        let box = try #require(UnitMercatorRect(bounding: greenwich))
        #expect(abs(box.originX - Mercator.unitX(longitude: -0.0050)) < 1e-15)
        #expect(abs(box.width - (0.0110 / 360)) < 1e-12)

        let cupertino = try #require(UnitMercatorRect(bounding: Self.trail))
        #expect(abs(cupertino.originX - Mercator.unitX(longitude: -122.0140)) < 1e-15)
        #expect(abs(cupertino.width - (0.0120 / 360)) < 1e-12)
    }
}
