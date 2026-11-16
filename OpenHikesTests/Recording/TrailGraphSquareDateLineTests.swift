//
//  TrailGraphSquareDateLineTests.swift
//  OpenHikesTests
//
//  The trail graph's squares across the antimeridian, from both sides of the
//  seam: the squares the tool files a trail under, and the regions the
//  library reads it into. OpenStreetMap writes a step across the date line
//  from 179.9° to −179.9°, which read as plain numbers runs 359.8° the long
//  way round, through Greenwich. Both sides read it the short way, by the one
//  rule `TrailGraphSquareGrid` keeps for them, and the last case holds the
//  squares a trail is filed under to every region it is read into: a region
//  whose square lacks a trail it crosses answers, from a complete set, with
//  the trail missing and no reason to ask Overpass.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Trail graph squares across the date line")
struct TrailGraphSquareDateLineTests {
    // MARK: - Fixtures

    /// The regions at either edge of the map just north of the equator, and
    /// the one at Greenwich in the same row.
    static let eastEdge = TrailGraphRegion(zoom: 12, x: 4095, y: 2047)
    static let westEdge = TrailGraphRegion(zoom: 12, x: 0, y: 2047)
    static let greenwich = TrailGraphRegion(zoom: 12, x: 2048, y: 2047)

    /// The region over `OverpassGraphFixture.alpineRoute`, far from the line.
    static let alpine = TrailGraphRegion(zoom: 12, x: 2194, y: 1430)

    /// A trail across the line either way, and one that runs on beside it
    /// before it crosses: the three shapes the tool's fixtures build too.
    static let eastward = way(500, [(0.01, 179.5), (0.01, -179.5)])
    static let westward = way(501, [(-0.01, -179.5), (-0.01, 179.5)])
    static let runningOn = way(502, [(-16.8, 178), (-16.8, 179.9), (-16.8, -179.9)])

    static func way(_ id: Int64, _ points: [(Double, Double)]) -> TrailGraphSquareFile.Way {
        let scale = Double(TrailGraphSquareFile.standardCoordinateScale)
        return TrailGraphSquareFile.Way(
            id: id,
            highway: "path",
            tags: [:],
            nodes: points.enumerated().map { index, point in
                TrailGraphSquareFile.Node(
                    id: id * 10 + Int64(index),
                    latitude: Int32((point.0 * scale).rounded()),
                    longitude: Int32((point.1 * scale).rounded())
                )
            }
        )
    }

    static func crosses(_ start: (Double, Double), _ end: (Double, Double), _ region: TrailGraphRegion) -> Bool {
        TrailGraphSquareLibrary.crosses(
            from: CLLocationCoordinate2D(latitude: start.0, longitude: start.1),
            to: CLLocationCoordinate2D(latitude: end.0, longitude: end.1),
            TrailGraphSquareLibrary.bounds(of: region)
        )
    }

    static func graph(of ways: [TrailGraphSquareFile.Way], in region: TrailGraphRegion) -> TrailGraph {
        TrailGraphSquareLibrary.graph(
            of: TrailGraphSquareFile(ways: ways),
            crossing: TrailGraphSquareLibrary.bounds(of: region)
        )
    }

    static func filed(_ way: TrailGraphSquareFile.Way) -> Set<TrailGraphSquare> {
        Set(TrailGraphSquareGrid.squares(
            touching: way.nodes,
            coordinateScale: TrailGraphSquareFile.standardCoordinateScale
        ))
    }

    static func squares(row: Int, columns: [Int]) -> Set<TrailGraphSquare> {
        Set(columns.map { TrailGraphSquare(x: $0, y: row) })
    }

    // MARK: - Reading a region

    @Test("a step across the date line, either way, crosses the regions at both edges of the map and none at Greenwich")
    func aStepAcrossTheLineCrossesBothEdges() {
        let east = (0.01, 179.9)
        let west = (0.01, -179.9)
        for (start, end) in [(east, west), (west, east)] {
            let direction = "from \(start.1) to \(end.1)"
            #expect(Self.crosses(start, end, Self.eastEdge), "the region east of 179.9°, \(direction)")
            #expect(Self.crosses(start, end, Self.westEdge), "the region west of −179.9°, \(direction)")
            #expect(!Self.crosses(start, end, Self.greenwich), "Greenwich, \(direction)")
            #expect(!Self.crosses(start, end, TrailGraphRegion(zoom: 12, x: 2, y: 2047)), "past its end, \(direction)")
            #expect(!Self.crosses(start, end, TrailGraphRegion(zoom: 12, x: 4093, y: 2047)), "before it, \(direction)")
        }
    }

    @Test("a step beside the date line meets no region across it")
    func aStepBesideTheLineStaysOnItsSide() {
        #expect(Self.crosses((0.01, 179.95), (0.01, 179.99), Self.eastEdge))
        #expect(!Self.crosses((0.01, 179.95), (0.01, 179.99), Self.westEdge))
        #expect(Self.crosses((0.01, -179.99), (0.01, -179.95), Self.westEdge))
        #expect(!Self.crosses((0.01, -179.99), (0.01, -179.95), Self.eastEdge))
    }

    @Test("an ordinary step crosses a region through it or onto its edge, and not past it")
    func ordinaryStepsAreReadAsBefore() {
        let bounds = TrailGraphSquareLibrary.bounds(of: Self.alpine)
        let middle = (bounds.south + bounds.north) / 2

        #expect(Self.crosses((middle, bounds.west - 0.01), (middle, bounds.east + 0.01), Self.alpine), "through it")
        #expect(Self.crosses((middle, bounds.west - 0.01), (middle, bounds.west), Self.alpine), "onto its west edge")
        #expect(
            Self.crosses((bounds.north, bounds.west - 0.01), (bounds.north, bounds.east + 0.01), Self.alpine),
            "along its north edge"
        )
        #expect(!Self.crosses((bounds.north + 0.001, bounds.west), (bounds.north + 0.001, bounds.east), Self.alpine))
        // Its box overlaps the region's, and the step itself goes round the
        // north-west corner.
        let corner = ((bounds.north - 0.01, bounds.west - 0.03), (bounds.north + 0.03, bounds.west + 0.01))
        #expect(!Self.crosses(corner.0, corner.1, Self.alpine), "past its corner")
    }

    /// No node of it is in either region: only its step across the line is.
    @Test("a trail across the date line is read whole into the regions at both edges of the map")
    func aTrailAcrossTheLineIsReadWhole() throws {
        let trail = Self.way(600, [(0.01, 179.9), (0.01, -179.9), (0.01, -179.85)])

        for region in [Self.eastEdge, Self.westEdge] {
            let graph = Self.graph(of: [trail], in: region)
            #expect(graph.nodes.map(\.id) == [6000, 6001, 6002], "every node, in region \(region.x)")
            #expect(graph.edges.map(\.id.segmentIndex) == [0, 1], "every segment, in region \(region.x)")
            let across = try #require(graph.edges.first)
            #expect((22_000...22_500).contains(across.lengthMeters), "0.2° across the line, not round the world")
        }
        #expect(Self.graph(of: [trail], in: Self.greenwich).edges.isEmpty)
    }

    // MARK: - Filing a trail

    @Test("a trail across the date line, either way, is filed under every square it crosses")
    func aTrailAcrossTheLineIsFiledWhereItRuns() {
        #expect(Self.filed(Self.eastward) == Self.squares(row: 511, columns: [1022, 1023, 0, 1]))
        #expect(Self.filed(Self.westward) == Self.squares(row: 512, columns: [1022, 1023, 0, 1]))
    }

    @Test("a trail that runs on before it crosses the date line is filed under every square of its run")
    func aTrailRunningOnIsFiledAlongItsRun() {
        #expect(Self.filed(Self.runningOn) == Self.squares(row: 560, columns: [1018, 1019, 1020, 1021, 1022, 1023, 0]))
    }

    /// Written either way, the line is the west edge of column 0 and the
    /// east edge of column 1023, and a box that reaches an edge touches the
    /// square beyond it.
    @Test("a trail that reaches the date line is filed on both sides of it")
    func aTrailOnTheLineIsFiledOnBothSides() {
        let both = Self.squares(row: 511, columns: [1023, 0])

        #expect(Self.filed(Self.way(800, [(0.01, 179.95), (0.01, 180)])) == both, "written as 180°")
        #expect(Self.filed(Self.way(801, [(0.01, -180), (0.01, -179.95)])) == both, "written as −180°")
        #expect(Self.filed(Self.way(802, [(0.01, 179.95), (0.01, -180)])) == both, "stepping onto it across it")
    }

    @Test("a trail that keeps off the date line is filed under the squares of its box")
    func aTrailOffTheLineIsFiledByItsBox() {
        let trails = [
            Self.way(700, [(47.62, 12.65), (47.63, 12.66)]),
            Self.way(701, [(51.47, -0.1), (51.48, 0.1)]),
            Self.way(702, [(-16.8, 179.5), (-16.79, 179.95), (-16.81, 179.6)]),
            Self.way(703, [(-16.8, -179.95), (-16.8, -179.5)]),
        ]
        for trail in trails {
            let latitudes = trail.nodes.map { Double($0.latitude) / 1_000_000 }
            let longitudes = trail.nodes.map { Double($0.longitude) / 1_000_000 }
            let box = TrailGraphSquareGrid.squares(
                touchingSouth: latitudes.min() ?? 0,
                west: longitudes.min() ?? 0,
                north: latitudes.max() ?? 0,
                east: longitudes.max() ?? 0
            )

            #expect(Self.filed(trail) == Set(box), "way \(trail.id)")
            #expect(Self.filed(trail).count == box.count, "way \(trail.id), each square once")
        }
        #expect(Self.filed(trails[0]) == Self.squares(row: 357, columns: [547, 548]))
        #expect(Self.filed(trails[1]).map(\.x).sorted() == [511, 512], "across Greenwich")
        #expect(Self.filed(trails[2]).map(\.x).sorted() == [1022, 1023], "beside the line, west of it")
        #expect(Self.filed(trails[3]).map(\.x).sorted() == [0, 1], "beside the line, east of it")
    }

    // MARK: - Both sides of the seam

    /// The contract between the tool and the library: a region is answered
    /// from its square alone, so every region a trail is read into has to be
    /// in a square the trail is filed under.
    @Test("every region a trail is read into lies in a square it is filed under")
    func everyRegionReadIsInASquareFiled() {
        let columns = Array(4064..<4096) + Array(0..<32) + Array(2040..<2056)
        for trail in [Self.eastward, Self.westward, Self.runningOn] {
            let rows = Set(trail.nodes.map { TrailGraphSquareGrid.tileY(Double($0.latitude) / 1_000_000, zoom: 12) })
            let filed = Self.filed(trail)
            var read: [TrailGraphRegion] = []
            for row in rows.flatMap({ [$0 - 1, $0, $0 + 1] }) {
                for column in columns {
                    let region = TrailGraphRegion(zoom: 12, x: column, y: row)
                    guard !Self.graph(of: [trail], in: region).edges.isEmpty else { continue }
                    read.append(region)
                    let square = TrailGraphSquareGrid.square(forRegionX: column, y: row, zoom: 12)
                    #expect(square.map(filed.contains) == true, "way \(trail.id), region \(column), \(row)")
                }
            }
            #expect(read.contains { $0.x == 4095 } && read.contains { $0.x == 0 }, "way \(trail.id) at both edges")
            #expect(!read.contains { (2040..<2056).contains($0.x) }, "way \(trail.id) at Greenwich")
        }
    }
}
