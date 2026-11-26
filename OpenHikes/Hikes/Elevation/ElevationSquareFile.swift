//
//  ElevationSquareFile.swift
//  OpenHikes
//
//  One square of heights, as the tile server holds it: Copernicus' posts in
//  whole metres, packed small enough that a valley's worth arrives in a
//  second. See ``ElevationSquareGrid`` for which posts a square holds.
//
//  ## Whole metres
//
//  A profile's climb and its steepness colors are read off differences of
//  tens of metres between readings a hundred metres apart, and the vertical
//  accuracy Copernicus states is a few metres, so a fraction of a metre is
//  noise the file would pay for: half-metres made the world 27% larger. The
//  service the app used before answered in whole metres too.
//
//  ## Packed as the plane they lie on
//
//  Each post is written as how far it is from the plane through its three
//  neighbors to the west, the north and the north-west (`west + north −
//  north-west`), which on a slope is a few metres or none. Those differences,
//  zigzagged so that small ones of either sign are small numbers, go in as
//  two planes — every low byte, then every high byte — and the envelope
//  deflates the lot (``PackedEnvelope``). Measured on four tiles (the Alps
//  twice, the Rockies, the Netherlands), the plane made the mountains 10–13%
//  smaller than a difference from the western post alone, and the flat one
//  7% larger, which is the right way round: the mountains are most of the
//  bytes, and the hikes.
//
//  The arithmetic wraps at 16 bits, both ways, so a post with no height
//  beside one with a height is a difference like any other and every square
//  reads back exactly as it was written.
//
//  ## No height
//
//  ``unknown`` is a post with no height: a square of nothing else stands for
//  ground whose heights Copernicus does not give away — see
//  `Scripts/lib/trail-cells/ElevationBuild.swift`. A height read from any
//  post that has none is no height, never a guess.
//
//  ## Compiled twice
//
//  By the app and by the tool that writes the squares, like
//  ``ElevationSquareGrid``.
//

import Foundation

nonisolated struct ElevationSquareFile: Equatable, Sendable {
    static let formatVersion: UInt8 = 1

    /// A post with no height.
    static let unknown = Int16.min

    /// Rows of posts, north to south.
    let rows: Int
    /// Columns of posts, west to east.
    let columns: Int
    /// Every post's height in whole metres, row by row from the north-west
    /// post, or ``unknown``.
    let heights: [Int16]

    /// - Precondition: `heights` holds `rows × columns` posts.
    init(rows: Int, columns: Int, heights: [Int16]) {
        precondition(rows > 0 && columns > 0 && heights.count == rows * columns, "a square holds every post")
        self.rows = rows
        self.columns = columns
        self.heights = heights
    }

    /// The height of the post at `index`, row by row, or `nil` for one with
    /// none.
    func height(at index: Int) -> Double? {
        let height = heights[index]
        return height == Self.unknown ? nil : Double(height)
    }

    /// Whether every post is at sea level, which the archive holds as no
    /// square at all.
    var isSeaLevel: Bool { heights.allSatisfy { $0 == 0 } }

    private static let magic: [UInt8] = Array("OHEL".utf8)
    private static let planeCount = 2
    private static let byteBits = 8
    private static let byteMask: UInt16 = 0xFF
}

// MARK: - Writing

nonisolated extension ElevationSquareFile {
    func encoded() -> Data {
        PackedEnvelope.file(magic: Self.magic, version: Self.formatVersion, body: encodedBody())
    }

    /// The body before the envelope packs it: the size, then the two planes.
    func encodedBody() -> Data {
        let count = heights.count
        var body = Data(PackedVarint.bytes(of: UInt64(rows)))
        body.append(contentsOf: PackedVarint.bytes(of: UInt64(columns)))
        var planes = [UInt8](repeating: 0, count: count * Self.planeCount)
        heights.withUnsafeBufferPointer { posts in
            for index in 0..<count {
                let residual = posts[index] &- Self.predicted(index, in: posts, columns: columns)
                let zigzag = UInt16(bitPattern: (residual &<< 1) ^ (residual >> 15))
                planes[index] = UInt8(zigzag & Self.byteMask)
                planes[count + index] = UInt8(zigzag >> Self.byteBits)
            }
        }
        body.append(contentsOf: planes)
        return body
    }

    /// What the posts already written say the post at `index` is: the plane
    /// through its western, northern and north-western neighbors, or the one
    /// neighbor it has along an edge.
    private static func predicted(_ index: Int, in posts: UnsafeBufferPointer<Int16>, columns: Int) -> Int16 {
        let column = index % columns
        switch (index < columns, column == 0) {
        case (true, true): return 0
        case (true, false): return posts[index - 1]
        case (false, true): return posts[index - columns]
        case (false, false): return posts[index - 1] &+ posts[index - columns] &- posts[index - columns - 1]
        }
    }
}

// MARK: - Reading

nonisolated extension ElevationSquareFile {
    /// Reads a square. Bytes that are not one — of another format or
    /// version, cut short, or naming more posts than they hold — throw, as
    /// every square's reader does: what arrives here came over a network.
    init(decoding file: Data) throws {
        let body = try PackedEnvelope.body(of: file, magic: Self.magic, version: Self.formatVersion)
        var reader = PackedReader(bytes: body)
        let rows = try reader.readCount(atMost: Self.maximumSide)
        let columns = try reader.readCount(atMost: Self.maximumSide)
        let count = rows * columns
        let planes = reader.remainder
        guard rows > 0, columns > 0, planes.count == count * Self.planeCount else {
            throw PackedFileError.corrupt
        }
        var heights = [Int16](repeating: 0, count: count)
        heights.withUnsafeMutableBufferPointer { posts in
            planes.withUnsafeBufferPointer { planes in
                for index in 0..<count {
                    let zigzag = UInt16(planes[index]) | UInt16(planes[count + index]) << Self.byteBits
                    let residual = Int16(bitPattern: (zigzag >> 1) ^ (0 &- (zigzag & 1)))
                    posts[index] = residual &+ Self.predicted(index, in: UnsafeBufferPointer(posts), columns: columns)
                }
            }
        }
        self.init(rows: rows, columns: columns, heights: heights)
    }

    /// The most posts a side of a square can have: Copernicus' rows of a
    /// tile. A file claiming more is not one.
    private static let maximumSide = ElevationSquareGrid.postsPerDegreeOfLatitude
}
