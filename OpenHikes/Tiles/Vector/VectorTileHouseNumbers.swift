//
//  VectorTileHouseNumbers.swift
//  OpenHikes
//
//  House numbers, as OpenStreetMap Carto writes them from zoom 17
//  (`addressing.mss`): small and gray, centred where the address is, and
//  only where nothing placed before them stands. The archive keeps every
//  address as a point in its `buildings` layer, kind `address`, from zoom 15,
//  a building's at its centre, and keeps `addr_housenumber` alone: the house
//  names, units and flats Carto adds to a number are not in it.
//
//  Numbers claim room after the points' names, where Carto's layer of
//  addresses comes, and each keeps Carto's margin from everything placed
//  before it. They are placed as the points' names are
//  (``VectorTilePoints/Names``), so a number belongs to the tile its point
//  lies in, and is moved inward rather than cut at the tile's edge. It keeps
//  the margin from the edge too, because the number across it is placed by
//  another tile, and two numbers either side of the edge would run together.
//

import CoreGraphics
import Foundation

nonisolated enum VectorTileHouseNumbers {
    /// Carto writes house numbers from this zoom.
    static let minimumZ = 17
    /// Carto's `text-margin`: the room a number keeps from everything placed
    /// before it, and here from the tile's edge, in the pixels of a 256-pixel
    /// tile.
    static let margin: CGFloat = 3

    /// The house numbers `tile` offers at `target`'s zoom whose points lie on
    /// the picture of it, in the archive's order. A point beyond is the
    /// neighbouring tile's to number.
    static func candidates(
        in tile: MapboxVectorTile,
        source: VectorTileAddress,
        target: VectorTileAddress
    ) -> [VectorTilePoints.Candidate] {
        guard target.z >= minimumZ, let layer = tile.layers["buildings"] else { return [] }
        let side = CGFloat(VectorTileRasterizer.pixelSize)
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let geometry = VectorTileGeometry(extent: layer.extent, source: source, target: target)
        let look = look(z: target.z)
        var found: [VectorTilePoints.Candidate] = []
        for feature in layer.features where feature.type == .point && feature.string("kind") == "address" {
            guard let number = feature.string("addr_housenumber").map(shortened), !number.isEmpty else { continue }
            for point in geometry.points(of: feature) where bounds.contains(point) {
                found.append(VectorTilePoints.Candidate(
                    anchor: point,
                    lines: [number],
                    look: look,
                    rank: VectorTilePoints.Rank(
                        order: 0,
                        height: -.infinity,
                        minimumZoom: .infinity,
                        name: number,
                        x: point.x,
                        y: point.y
                    )
                ))
            }
        }
        return found
    }

    /// A list of numbers longer than ten characters written as its first and
    /// last, as Carto's `carto_shorten_list` writes it: `1;3;5;7;9;11` as
    /// `1…11`, never broken between the two. A list of two, or one that mixes
    /// commas and semicolons, is written whole.
    static func shortened(_ number: String) -> String {
        guard number.count > longestUnshortened else { return number }
        let separators = listSeparators.filter { number.contains($0) }
        guard separators.count == 1, let separator = separators.first else { return number }
        let parts = number.split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count > 2, let first = parts.first, let last = parts.last else { return number }
        return "\(first)\u{2026}\u{2060}\(last)"
    }

    /// How a house number is written at zoom `z`: Carto's figures, with a
    /// wider halo from zoom 18.
    static func look(z: Int) -> VectorTilePointStyle.Look {
        VectorTilePointStyle.Look(
            lowPriority: false,
            stationOrder: nil,
            showsElevation: false,
            icons: [],
            text: VectorTilePointStyle.Text(
                size: size,
                color: ink,
                halo: halo,
                haloRadius: z >= VectorTileStyle.z18 ? deepHaloRadius : haloRadius,
                offset: 0,
                wrapWidth: wrapWidth,
                lineSpacing: lineSpacing,
                face: .regular,
                opacity: 1
            )
        )
    }

    private static let size: CGFloat = 10
    private static let ink = VectorTileStyle.color("#666666")
    private static let halo = VectorTileStyle.color("#FFFFFF99")
    private static let haloRadius: CGFloat = 1
    private static let deepHaloRadius: CGFloat = 1.25
    private static let wrapWidth: CGFloat = 30
    private static let lineSpacing: CGFloat = -1.5
    private static let longestUnshortened = 10
    private static let listSeparators: [Character] = [",", ";"]
}
