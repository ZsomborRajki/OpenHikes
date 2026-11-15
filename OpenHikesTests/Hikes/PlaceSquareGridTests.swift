//
//  PlaceSquareGridTests.swift
//  OpenHikesTests
//
//  Which square a place is filed under, which squares a search reads, and what
//  their records are called — a storage contract, because every installed
//  build asks for the names it knows.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Place square grid")
struct PlaceSquareGridTests {
    /// The square a hiker in the Berchtesgaden valley reads: a degree each
    /// way, counted from the south pole and the antimeridian.
    @Test("a place is filed under the degree it stands in")
    func aPlaceIsFiledWhereItStands() {
        let square = PlaceSquareGrid.square(containingLatitude: 47.62, longitude: 12.97)

        #expect(square == PlaceSquare(row: 137, column: 192))
        #expect(PlaceSquareGrid.recordName(for: square) == "places1_137_192")
    }

    @Test("the poles and the antimeridian are inside the grid")
    func theEdgesAreInside() {
        #expect(PlaceSquareGrid.square(containingLatitude: 90, longitude: 0).row == 179)
        #expect(PlaceSquareGrid.square(containingLatitude: -90, longitude: 0).row == 0)
        #expect(PlaceSquareGrid.square(containingLatitude: 0, longitude: 180).column == 0)
        #expect(PlaceSquareGrid.square(containingLatitude: 0, longitude: -180).column == 0)
        #expect(PlaceSquareGrid.square(containingLatitude: 0, longitude: 539.5).column == 359)
    }

    /// A place is a point and reaches out of nothing, so a search reads the
    /// squares its box touches and not one more.
    @Test("a search reads the squares its box touches, and no others")
    func aSearchReadsWhatItTouches() {
        let inside = TrailCellBounds(south: 47.598, west: 12.86675, north: 47.642, east: 12.93325)
        let straddling = TrailCellBounds(south: 47.9, west: 12.9, north: 48.1, east: 13.1)

        #expect(PlaceSquareGrid.squares(covering: inside) == [PlaceSquare(row: 137, column: 192)])
        #expect(Set(PlaceSquareGrid.squares(covering: straddling)) == [
            PlaceSquare(row: 137, column: 192), PlaceSquare(row: 137, column: 193),
            PlaceSquare(row: 138, column: 192), PlaceSquare(row: 138, column: 193),
        ])
    }

    @Test("a box past the antimeridian wraps, and a box that is not one reads nothing")
    func wrappedAndBrokenBoxes() {
        let wrapping = TrailCellBounds(south: -17.5, west: 179.5, north: -17.2, east: 180.5)
        let inverted = TrailCellBounds(south: 48, west: 13, north: 47, east: 12)
        let infinite = TrailCellBounds(south: 47, west: -.infinity, north: 48, east: 13)
        let wholeWorld = TrailCellBounds(south: 0, west: -360, north: 0.5, east: 360)

        #expect(PlaceSquareGrid.squares(covering: wrapping).map(\.column) == [359, 0])
        #expect(PlaceSquareGrid.squares(covering: inverted).isEmpty)
        #expect(PlaceSquareGrid.squares(covering: infinite).isEmpty)
        #expect(PlaceSquareGrid.squares(covering: wholeWorld).count == PlaceSquareGrid.columnCount)
    }

    @Test("a record name reads back as its square, and nothing else does")
    func recordNamesReadBack() {
        let square = PlaceSquare(row: 137, column: 192)

        #expect(PlaceSquareGrid.square(named: PlaceSquareGrid.recordName(for: square)) == square)
        #expect(PlaceSquareGrid.manifestRecordName == "places1_manifest")
        #expect(PlaceSquareGrid.square(named: PlaceSquareGrid.manifestRecordName) == nil)
        #expect(PlaceSquareGrid.square(named: "trails1_137_192") == nil, "the day hikes' names are theirs")
        #expect(PlaceSquareGrid.square(named: "routes1_z14_137_192") == nil, "and so are the layer's")
        #expect(PlaceSquareGrid.square(named: "places1_180_0") == nil, "past the last row")
        #expect(PlaceSquareGrid.square(named: "places1_0_360") == nil, "past the last column")
        #expect(PlaceSquareGrid.square(named: "places1_-1_0") == nil)
    }
}
