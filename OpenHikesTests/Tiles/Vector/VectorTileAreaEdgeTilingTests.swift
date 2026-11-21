//
//  VectorTileAreaEdgeTilingTests.swift
//  OpenHikesTests
//
//  How the tiles share a protected area's edge and the names along it: the
//  archive's cut around its tile is never named as an edge and the edge in
//  its buffer is, a name stands where the edge crosses the world's grid, the
//  tile its name falls in names it, and two tiles keep it 250 pixels from
//  itself across the seam between them. Tiles are written by
//  `VectorTileFixture`.
//

import CoreGraphics
import Foundation
@testable import OpenHikes
import Testing

@Suite("Vector tile area edges across tiles")
struct VectorTileAreaEdgeTilingTests {
    private let grid = VectorTileFixture.grid
    private let side = CGFloat(VectorTileRasterizer.pixelSize)
    private var frame: CGRect { CGRect(x: 0, y: 0, width: side, height: side) }

    // MARK: The archive's cut

    /// The archive cuts an area that runs past its tile along a square its
    /// buffer outside the tile: 16 of the picture's pixels at the archive's
    /// zoom, two to each of a 256-pixel tile's.
    private var cut: CGRect { frame.insetBy(dx: -16, dy: -16) }

    private func stretches(of ring: [CGPoint]) -> [[CGPoint]] {
        VectorTileLineLabels.stretches(of: ring, cutAlong: cut, within: 0.5)
    }

    @Test("an area that covers the archive's tile has no edge on it")
    func coveringAreaHasNoEdge() {
        let around = [
            CGPoint(x: -16, y: -16), CGPoint(x: side + 16, y: -16),
            CGPoint(x: side + 16, y: side + 16), CGPoint(x: -16, y: side + 16),
        ]

        #expect(stretches(of: around).isEmpty)
    }

    /// The edge runs on in the buffer, outside the tile, and only the sides
    /// along the cut are left out.
    @Test("an edge that leaves the archive's tile is named up to the cut")
    func edgeCutAtTheTile() {
        let corner = [
            CGPoint(x: -16, y: -16), CGPoint(x: 100, y: -16), CGPoint(x: 100, y: 100), CGPoint(x: -16, y: 100),
        ]

        #expect(stretches(of: corner) == [[CGPoint(x: 100, y: -16), CGPoint(x: 100, y: 100), CGPoint(x: -16, y: 100)]])
    }

    /// An edge in the buffer that runs beside the cut is still an edge.
    @Test("a side in the buffer that does not lie along the cut is an edge")
    func edgeBesideTheCut() {
        let strip = [
            CGPoint(x: -16, y: -2), CGPoint(x: side + 16, y: -2),
            CGPoint(x: side + 16, y: side + 16), CGPoint(x: -16, y: side + 16),
        ]

        #expect(stretches(of: strip) == [[CGPoint(x: -16, y: -2), CGPoint(x: side + 16, y: -2)]])
    }

    @Test("a stretch that runs on across the ring's first point is one stretch")
    func stretchAcrossTheStart() {
        let ring = [
            CGPoint(x: 50, y: 50), CGPoint(x: side + 16, y: 50), CGPoint(x: side + 16, y: 100), CGPoint(x: 50, y: 100),
        ]

        let expected = [
            CGPoint(x: side + 16, y: 100), CGPoint(x: 50, y: 100), CGPoint(x: 50, y: 50), CGPoint(x: side + 16, y: 50),
        ]
        #expect(stretches(of: ring) == [expected])
    }

    @Test("a ring wholly inside the tile is one stretch, back to its start")
    func ringInside() {
        let ring = [CGPoint(x: 50, y: 50), CGPoint(x: 150, y: 50), CGPoint(x: 150, y: 150)]

        #expect(stretches(of: ring) == [ring + [CGPoint(x: 50, y: 50)]])
    }

    // MARK: The world's grid

    /// A straight edge 45 degrees across the grid crosses a line down it and
    /// a line across it 141 pixels apart near the corner at (1,500, 1,500),
    /// and the crossing of the line across gives way. A tile that sees only
    /// the stretch past the line down takes the edge to run on straight to
    /// it.
    @Test("near a corner of the grid, an edge's crossing of a line across gives way to a line down")
    func crossingsNearACorner() {
        let whole = [CGPoint(x: 1100, y: 2000), CGPoint(x: 2100, y: 1000)]
        let pastTheLineDown = [CGPoint(x: 1540, y: 1560), CGPoint(x: 2100, y: 1000)]

        let crossings = VectorTileLineLabels.edgeCrossings(of: whole, origin: .zero, every: 1500, clearance: 400)
        let seen = VectorTileLineLabels.edgeCrossings(
            of: pastTheLineDown,
            origin: .zero,
            every: 1500,
            clearance: 400
        )

        #expect(crossings.map { ($0 * 10).rounded() / 10 } == [565.7], "the line down, at (1,500, 1,600)")
        #expect(VectorTileShields.crossings(of: whole, origin: .zero, every: 1500).count == 2)
        #expect(seen.isEmpty, "the line across, at (1,600, 1,500)")
    }

    /// An edge that runs down the map crosses no line down it, and is named
    /// where it crosses the lines across.
    @Test("an edge that runs down the map is named where it crosses the lines across")
    func edgeRunningDown() {
        let down = [CGPoint(x: 1450, y: 100), CGPoint(x: 1460, y: 3200)]

        let crossings = VectorTileLineLabels.edgeCrossings(of: down, origin: .zero, every: 1500, clearance: 400)

        #expect(crossings.count == 2)
    }

    /// Carto spaces the names 750 pixels apart along the whole edge. A tile
    /// sees only its stretch, so a name stands where the edge crosses the
    /// world's grid: a straight edge across six tiles, 1,536 of a 256-pixel
    /// tile's pixels, crosses it three times, and the tiles agree on where.
    @Test("an edge's name stands about every 750 pixels, however the tiles cut the edge")
    func namesFollowTheWorldsGrid() {
        let placed = (0..<6).map { column in
            let line = VectorTileLineLabels.NamedLine(
                category: .protectedArea,
                name: "Narodni park",
                points: [CGPoint(x: 0, y: 256), CGPoint(x: side, y: 256)]
            )
            return VectorTileLineLabels.Layout(
                [line],
                target: VectorTileAddress(z: 13, x: column, y: 0),
                unit: 2,
                bounds: frame,
                occupied: [],
                language: "sl"
            )
            .count
        }

        #expect(placed == [1, 0, 1, 0, 0, 1])
    }

    /// An edge one pixel north of the seam between two tiles has its name
    /// 10 pixels inside the southern one, where the northern tile cannot set
    /// it. The southern tile holds the edge in the archive's buffer, and
    /// names it from there.
    @Test("an edge just outside the tile is named by the tile its name falls in")
    func edgeInTheBuffer() throws {
        let buffer = grid * Int(VectorTileLineLabels.areaEdgeBuffer) / Int(VectorTileRasterizer.styleTileSize)
        let pixel = grid / Int(VectorTileRasterizer.styleTileSize)
        let north = VectorTileAddress(z: 13, x: 2, y: 0)
        let south = VectorTileAddress(z: 13, x: 2, y: 1)
        let inNorth = area("Narodni park", size: size(250_000, atZ: 13), y: grid - pixel...grid + buffer, cut: buffer)
        let inSouth = area("Narodni park", size: size(250_000, atZ: 13), y: -pixel...grid + buffer, cut: buffer)

        #expect(try placed(inNorth, at: north) == 0, "the name would stand in the southern tile")
        #expect(try placed(inSouth, at: south) == 1)
    }

    /// An edge across the grid's lines near a corner crosses a line down it
    /// and a line across it close together, and two tiles either side of the
    /// seam between would each set the name at its own crossing. Each tile
    /// sees only its own stretch of the edge, cut a little outside it.
    @Test("an edge's names stand 250 pixels apart across tiles, near a corner of the grid too")
    func repeatDistanceAcrossTiles() throws {
        // In the pictures' pixels at zoom 13, two to a style pixel: the
        // grid's lines are 1,500 apart, and the edge passes the corner at
        // (1,500, 1,500) running north-east.
        let start = CGPoint(x: 500, y: 2600)
        let end = CGPoint(x: 2600, y: 500)
        var middles: [CGPoint] = []
        for column in 0...5 {
            for row in 0...5 {
                let corner = CGPoint(x: CGFloat(column) * side, y: CGFloat(row) * side)
                let seen = frame.insetBy(dx: -16, dy: -16).offsetBy(dx: corner.x, dy: corner.y)
                let stretch = clipped(from: start, to: end, inside: seen).map { point in
                    CGPoint(x: point.x - corner.x, y: point.y - corner.y)
                }
                guard !stretch.isEmpty else { continue }
                let layout = VectorTileLineLabels.Layout(
                    [.init(category: .protectedArea, name: "Narodni park", points: stretch)],
                    target: VectorTileAddress(z: 13, x: column, y: row),
                    unit: 2,
                    bounds: frame,
                    occupied: [],
                    language: "sl"
                )
                guard layout.count > 0 else { continue }
                try #require(layout.count == 1)
                let boxes = layout.taken
                let count = CGFloat(boxes.count)
                middles.append(CGPoint(
                    x: boxes.map(\.midX).reduce(0, +) / count + corner.x,
                    y: boxes.map(\.midY).reduce(0, +) / count + corner.y
                ))
            }
        }

        #expect(!middles.isEmpty)
        for (index, first) in middles.enumerated() {
            for second in middles.dropFirst(index + 1) {
                #expect(hypot(first.x - second.x, first.y - second.y) >= 2 * 250, "\(first), \(second)")
            }
        }
    }

    // MARK: Helpers

    /// A protected area whose top edge runs across the tile at `y`, cut by
    /// the archive `cut` outside the tile everywhere else, as the archive
    /// cuts one.
    private func area(
        _ name: String,
        size: Double,
        y: ClosedRange<Int>,
        cut: Int
    ) -> VectorTileFixture.Feature {
        .init(
            type: .polygon,
            properties: ["kind": .string("protected_area"), "name": .string(name), "area": .double(size)],
            geometry: VectorTileFixture.rectangle(x: -cut...grid + cut, y: y)
        )
    }

    /// How many names `feature` places on the tile at `address`.
    private func placed(_ feature: VectorTileFixture.Feature, at address: VectorTileAddress) throws -> Int {
        let tile = try protectedAreas([feature])
        let lines = VectorTileLineLabels.lines(in: tile, source: address, target: address, language: "sl")
        return VectorTileLineLabels.Layout(
            lines,
            target: address,
            unit: 2,
            bounds: frame,
            occupied: [],
            language: "sl"
        )
        .count
    }

    /// The part of the straight line from `start` to `end` inside `rect`.
    private func clipped(from start: CGPoint, to end: CGPoint, inside rect: CGRect) -> [CGPoint] {
        var enters: CGFloat = 0
        var leaves: CGFloat = 1
        for (from, to, low, high) in [(start.x, end.x, rect.minX, rect.maxX), (start.y, end.y, rect.minY, rect.maxY)] {
            let first = (low - from) / (to - from)
            let second = (high - from) / (to - from)
            enters = max(enters, min(first, second))
            leaves = min(leaves, max(first, second))
        }
        guard enters < leaves else { return [] }
        return [enters, leaves].map { share in
            CGPoint(x: start.x + (end.x - start.x) * share, y: start.y + (end.y - start.y) * share)
        }
    }

    /// An area's size in the extras' unit that covers `pixels` at zoom `z`.
    private func size(_ pixels: Double, atZ z: Int) -> Double {
        pixels / pow(4, Double(z))
    }

    private func protectedAreas(_ features: [VectorTileFixture.Feature]) throws -> MapboxVectorTile {
        try VectorTileFixture.decoded([.init(name: VectorTileRasterizer.protectedAreasLayer, features: features)])
    }
}
