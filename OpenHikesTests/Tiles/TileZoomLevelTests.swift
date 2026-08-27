//
//  TileZoomLevelTests.swift
//  OpenHikesTests
//
//  `zoomLevel(for:tileWidth:)` picks which level of the tile pyramid gets
//  drawn for a given `MKZoomScale`. It is the input to every other decision
//  the renderer makes — which path is fetched, which ancestor an overzoomed
//  tile crops out of, how many tiles a pan costs — and it fails silently:
//  one level too shallow is a map that is blurry everywhere, one too deep
//  fetches four times the tiles it needs, and neither throws, logs or
//  crashes. Nothing else observes it, so it is pinned here.
//
//  The expected levels below are written out rather than recomputed, because
//  a test that reruns the implementation's own formula asserts only that
//  `log2` is deterministic. This suite touches no cache and no disk: the
//  function reads nothing but its two arguments.
//

import Foundation
import MapKit
@testable import OpenHikes
import Testing

@Suite("Tile zoom level")
struct TileZoomLevelTests {
    /// One row of the table: a scale MapKit could hand the renderer, and the
    /// level it must answer with.
    struct ZoomCase: Sendable, CustomStringConvertible {
        let scale: Double
        let level: Int
        var description: String { "zoomScale \(scale) → z\(level)" }
    }

    /// `MKTileOverlay`'s default tile size, which `TileOverlay` never
    /// overrides — so this is the only width the app itself ever passes.
    nonisolated static let standardTileWidth: CGFloat = 256

    /// The world is 2^28 map points across and a tile is 2^8 of them wide, so
    /// a scale of 1 draws z20 and each halving of the scale takes one level
    /// off. Every scale here is an exact power of two, and therefore an exact
    /// `Double`: no row is decided by a rounding tie.
    ///
    /// The range is the whole useful one — z0 is the single world tile and
    /// nothing here declares a `maximumZ` past 22.
    nonisolated static let table: [ZoomCase] = [
        ZoomCase(scale: 0.000000476837158203125, level: 0),   // 2^-21, clamped up from -1
        ZoomCase(scale: 0.00000095367431640625, level: 0),    // 2^-20
        ZoomCase(scale: 0.0000019073486328125, level: 1),     // 2^-19
        ZoomCase(scale: 0.000003814697265625, level: 2),      // 2^-18
        ZoomCase(scale: 0.00000762939453125, level: 3),       // 2^-17
        ZoomCase(scale: 0.0000152587890625, level: 4),        // 2^-16
        ZoomCase(scale: 0.000030517578125, level: 5),         // 2^-15
        ZoomCase(scale: 0.00006103515625, level: 6),          // 2^-14
        ZoomCase(scale: 0.0001220703125, level: 7),           // 2^-13
        ZoomCase(scale: 0.000244140625, level: 8),            // 2^-12
        ZoomCase(scale: 0.00048828125, level: 9),             // 2^-11
        ZoomCase(scale: 0.0009765625, level: 10),             // 2^-10
        ZoomCase(scale: 0.001953125, level: 11),              // 2^-9
        ZoomCase(scale: 0.00390625, level: 12),               // 2^-8
        ZoomCase(scale: 0.0078125, level: 13),                // 2^-7
        ZoomCase(scale: 0.015625, level: 14),                 // 2^-6
        ZoomCase(scale: 0.03125, level: 15),                  // 2^-5
        ZoomCase(scale: 0.0625, level: 16),                   // 2^-4
        ZoomCase(scale: 0.125, level: 17),                    // 2^-3
        ZoomCase(scale: 0.25, level: 18),                     // 2^-2
        ZoomCase(scale: 0.5, level: 19),                      // 2^-1
        ZoomCase(scale: 1.0, level: 20),                      // 2^0, one screen point per tile pixel
        ZoomCase(scale: 2.0, level: 21),                      // 2^1
        ZoomCase(scale: 4.0, level: 22),                      // 2^2
    ]

    /// Scales MapKit actually produces are not powers of two, so the table is
    /// checked off its own grid too.
    nonisolated static let offGridTable: [ZoomCase] = [
        ZoomCase(scale: 0.0000001, level: 0),
        ZoomCase(scale: 0.001, level: 10),
        ZoomCase(scale: 0.01, level: 13),
        ZoomCase(scale: 0.1, level: 17),
        ZoomCase(scale: 0.3, level: 18),
        ZoomCase(scale: 0.75, level: 20),
        ZoomCase(scale: 1.5, level: 21),
        ZoomCase(scale: 3.0, level: 22),
    ]

    /// The table minus its clamped floor: below z1 the level stops tracking
    /// the scale, so the two step relations below — which say what happens
    /// *between* levels — are only meaningful above it.
    nonisolated static let unclampedTable: [ZoomCase] = Self.table.filter { $0.level > 0 }

    @Test("each zoom scale draws its documented level", arguments: Self.table + Self.offGridTable)
    func level(for zoomCase: ZoomCase) {
        let level = CachingTileOverlayRenderer.zoomLevel(
            for: MKZoomScale(zoomCase.scale),
            tileWidth: Self.standardTileWidth
        )
        #expect(level == zoomCase.level)
    }

    /// The only way a display scale reaches this function: it reads no
    /// `contentScaleFactor`, because a retina screen is served the *same*
    /// level at twice the pixel density — `@2x` is chosen in the tile path and
    /// the URL, not here. A provider that genuinely served 512-point tiles
    /// would be one level shallower at every scale, and one serving 128-point
    /// tiles one level deeper.
    @Test("doubling the tile width takes exactly one level off", arguments: Self.unclampedTable)
    func tileWidth(_ zoomCase: ZoomCase) {
        let wide = CachingTileOverlayRenderer.zoomLevel(for: MKZoomScale(zoomCase.scale), tileWidth: 512)
        let narrow = CachingTileOverlayRenderer.zoomLevel(for: MKZoomScale(zoomCase.scale), tileWidth: 128)
        #expect(wide == zoomCase.level - 1)
        #expect(narrow == zoomCase.level + 1)
    }

    /// The property a future "small" change is most likely to break, and the
    /// one no single row can catch: a finer sweep than the table, asserting
    /// only that the sequence never goes backwards.
    @Test("zooming in never returns a shallower level")
    func monotonic() {
        var previous = 0
        for step in 0...800 {
            let scale = pow(2.0, -22.0 + Double(step) * 0.05)
            let level = CachingTileOverlayRenderer.zoomLevel(
                for: MKZoomScale(scale),
                tileWidth: Self.standardTileWidth
            )
            #expect(level >= previous, "z\(level) at scale \(scale) is shallower than z\(previous)")
            #expect(level <= CachingTileOverlayRenderer.maximumZoomLevel)
            previous = level
        }
        #expect(previous > 0)
    }

    /// Twice the scale is twice as many tiles across the world, which is
    /// exactly one more level — the invariant the whole pyramid rests on.
    @Test("doubling the scale adds exactly one level", arguments: Self.unclampedTable)
    func doubling(_ zoomCase: ZoomCase) {
        let doubled = CachingTileOverlayRenderer.zoomLevel(
            for: MKZoomScale(zoomCase.scale * 2),
            tileWidth: Self.standardTileWidth
        )
        #expect(doubled == zoomCase.level + 1)
    }

    /// Zoomed further out than a single world tile, there is no shallower
    /// answer to give.
    @Test("scales below the whole world clamp to z0", arguments: [1e-9, 1e-12, 1e-30, Double.leastNormalMagnitude])
    func clampsLow(_ scale: Double) {
        let level = CachingTileOverlayRenderer.zoomLevel(
            for: MKZoomScale(scale),
            tileWidth: Self.standardTileWidth
        )
        #expect(level == 0)
    }

    /// The upper clamp is not a map decision — no provider declares anything
    /// near it — but `draw` shifts `1 << zoom` to count tiles, and a level
    /// past `Int`'s width makes that zero, which is the divisor in
    /// `SlippyTileMath.wrap(_:to:)`.
    @Test("absurd scales clamp instead of overflowing the tile count")
    func clampsHigh() {
        let level = CachingTileOverlayRenderer.zoomLevel(
            for: MKZoomScale(pow(2.0, 60)),
            tileWidth: Self.standardTileWidth
        )
        #expect(level == CachingTileOverlayRenderer.maximumZoomLevel)
        #expect(1 << level > 0)
    }

    /// The clamp has to sit *below* the shift and *above* every real map, or
    /// it would silently shorten a provider that declares more levels than it.
    @Test("the clamp is deeper than any provider and still a valid shift")
    func clampCoversEveryProvider() {
        let deepest = TileProvider.all.map(\.maximumZ).max() ?? 0
        #expect(CachingTileOverlayRenderer.maximumZoomLevel > deepest)
        #expect(1 << CachingTileOverlayRenderer.maximumZoomLevel > 0)
    }

    /// Rounding is half-*up*, so a level owns `[2^(k-0.5), 2^(k+0.5))`: the
    /// boundary scale itself belongs to the deeper level, and the shallower
    /// one ends just below it. The offsets are relative rather than a single
    /// ULP because the sum inside the function has a coarser ULP than the
    /// scale does, so an absolute one-step nudge does not always cross.
    @Test(
        "a level boundary belongs to the deeper level",
        arguments: [
            (boundary: 0.35355339059327379, shallow: 18, deep: 19),   // 2^-1.5
            (boundary: 0.70710678118654757, shallow: 19, deep: 20),   // 2^-0.5
            (boundary: 1.4142135623730951, shallow: 20, deep: 21),    // 2^0.5
            (boundary: 2.8284271247461903, shallow: 21, deep: 22),    // 2^1.5
        ]
    )
    func boundary(_ testCase: (boundary: Double, shallow: Int, deep: Int)) {
        let below = CachingTileOverlayRenderer.zoomLevel(
            for: MKZoomScale(testCase.boundary * (1 - 1e-9)),
            tileWidth: Self.standardTileWidth
        )
        let at = CachingTileOverlayRenderer.zoomLevel(
            for: MKZoomScale(testCase.boundary),
            tileWidth: Self.standardTileWidth
        )
        let above = CachingTileOverlayRenderer.zoomLevel(
            for: MKZoomScale(testCase.boundary * (1 + 1e-9)),
            tileWidth: Self.standardTileWidth
        )
        #expect(below == testCase.shallow)
        #expect(at == testCase.deep)
        #expect(above == testCase.deep)
    }

    /// None of these can come from MapKit, but `Int(_:)` traps on a
    /// non-finite `Double` and every one of them reaches it as one — so the
    /// difference between an answer and a crash is a single guard. A level is
    /// always somewhere on the pyramid.
    @Test(
        "a degenerate input answers instead of trapping",
        arguments: [
            (scale: 0.0, width: CGFloat(256), level: 0),
            (scale: -1.0, width: CGFloat(256), level: 0),
            (scale: -Double.infinity, width: CGFloat(256), level: 0),
            (scale: Double.nan, width: CGFloat(256), level: 0),
            (scale: 1.0, width: CGFloat.nan, level: 0),
            (scale: 1.0, width: CGFloat(-256), level: 0),
            (scale: Double.infinity, width: CGFloat(256), level: CachingTileOverlayRenderer.maximumZoomLevel),
            (scale: 1.0, width: CGFloat(0), level: CachingTileOverlayRenderer.maximumZoomLevel),
        ]
    )
    func degenerate(_ testCase: (scale: Double, width: CGFloat, level: Int)) {
        let level = CachingTileOverlayRenderer.zoomLevel(
            for: MKZoomScale(testCase.scale),
            tileWidth: testCase.width
        )
        #expect(level == testCase.level)
        #expect((0...CachingTileOverlayRenderer.maximumZoomLevel).contains(level))
    }

    /// What the level is *for*: a level deeper than the provider serves is
    /// not an error, it is an overzoom, and `fetchPath` folds it onto the
    /// deepest real ancestor covering the same ground. Pairing the two here
    /// is what makes the clamp above harmless — even at 30, nothing asks OSM
    /// for a tile it does not have.
    @Test("a level past the provider's deepest is fetched as an ancestor", arguments: [19, 22, 30])
    func overzoomHandoff(_ zoom: Int) throws {
        let provider = TileProvider.openStreetMap
        let path = MKTileOverlayPath(x: 1 << (zoom - 1), y: 1 << (zoom - 1), z: zoom, contentScaleFactor: 2)
        let resolved = try #require(
            CachingTileOverlayRenderer.fetchPath(
                drawing: path,
                maximumZ: provider.maximumZ,
                isCached: { _ in false }
            )
        )
        #expect(resolved.z == min(zoom, provider.maximumZ))
        #expect(resolved.x == path.x >> (zoom - resolved.z))
        #expect(resolved.y == path.y >> (zoom - resolved.z))
    }
}
