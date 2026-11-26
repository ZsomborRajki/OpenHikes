//
//  CopernicusTile.swift
//  trail-cells
//
//  One tile of the Copernicus DEM, read out of the cloud-optimized GeoTIFF it
//  is published as: a degree of the Earth's heights, as `build-elevation`
//  files them into squares (`ElevationBuild.swift`).
//
//  A reader of exactly the files Copernicus publishes and nothing else, so it
//  needs no library: a little-endian TIFF whose first image is the full
//  resolution, one 32-bit float a post, in tiles of DEFLATE with the
//  floating-point predictor (TIFF Technical Note 3), placed by a tie point at
//  the tile's north-west post (`PixelIsPoint`) and a step per post. The
//  overviews after the first image are never read. A file of any other shape
//  is refused with the tag that differs, rather than read approximately: a
//  height filed a post away from where it was measured looks right and is
//  not.
//

import Compression
import Foundation

struct CopernicusTile {
    /// Rows of posts, north to south: 3,600 in every tile.
    let rows: Int
    /// Columns of posts, west to east: as many as the tile's band keeps.
    let columns: Int
    /// The longitude and latitude of the north-west post.
    let west: Double
    let north: Double
    /// Degrees between two posts, east and south.
    let columnStep: Double
    let rowStep: Double
    /// Every post's height in metres, row by row from the north-west post.
    let heights: [Float]

    init(file: Data) throws {
        let bytes = [UInt8](file)
        guard bytes.count >= Self.headerBytes, bytes[0] == Self.littleEndian, bytes[1] == Self.littleEndian,
              Self.uint16(bytes, 2) == Self.classicTIFF
        else { throw CopernicusTileError.notLittleEndianTIFF }
        let directory = try Directory(bytes: bytes, offset: Int(Self.uint32(bytes, 4)))

        columns = try directory.integer(.imageWidth)
        rows = try directory.integer(.imageLength)
        try directory.require(.bitsPerSample, equals: Self.floatBits)
        try directory.require(.sampleFormat, equals: Self.ieeeFloat)
        try directory.require(.samplesPerPixel, equals: 1)
        try directory.require(.predictor, equals: Self.floatingPointPredictor)
        let compression = try directory.integer(.compression)
        guard Self.deflateCompressions.contains(compression) else {
            throw CopernicusTileError.unexpected(tag: Tag.compression.rawValue, value: compression)
        }
        let tileWidth = try directory.integer(.tileWidth)
        let tileLength = try directory.integer(.tileLength)
        let offsets = try directory.integers(.tileOffsets)
        let counts = try directory.integers(.tileByteCounts)
        let tilesAcross = (columns + tileWidth - 1) / tileWidth
        let tilesDown = (rows + tileLength - 1) / tileLength
        guard offsets.count == tilesAcross * tilesDown, counts.count == offsets.count else {
            throw CopernicusTileError.tileCount(offsets.count)
        }

        let scale = try directory.doubles(.modelPixelScale)
        let tiePoint = try directory.doubles(.modelTiePoint)
        guard scale.count >= 2, tiePoint.count >= Self.tiePointValues, tiePoint[0] == 0, tiePoint[1] == 0 else {
            throw CopernicusTileError.placement
        }
        columnStep = scale[0]
        rowStep = scale[1]
        west = tiePoint[3]
        north = tiePoint[4]
        let geoKeys = try directory.integers(.geoKeyDirectory)
        guard Self.rasterType(in: geoKeys) == Self.pixelIsPoint else { throw CopernicusTileError.notPixelIsPoint }

        var heights = [Float](repeating: .nan, count: rows * columns)
        let tileBytes = tileWidth * tileLength * MemoryLayout<Float>.size
        var inflated = [UInt8](repeating: 0, count: tileBytes)
        var shuffled = [UInt8](repeating: 0, count: tileWidth * MemoryLayout<Float>.size)
        for tileRow in 0..<tilesDown {
            for tileColumn in 0..<tilesAcross {
                let index = tileRow * tilesAcross + tileColumn
                let start = offsets[index]
                let end = start + counts[index]
                guard start >= 0, end <= bytes.count, counts[index] > Self.zlibHeaderBytes else {
                    throw CopernicusTileError.truncated
                }
                try Self.inflate(bytes[(start + Self.zlibHeaderBytes)..<end], into: &inflated)
                Self.write(
                    inflated, shuffled: &shuffled, tileWidth: tileWidth, tileLength: tileLength,
                    at: (row: tileRow * tileLength, column: tileColumn * tileWidth),
                    into: &heights, rows: rows, columns: columns
                )
            }
        }
        self.heights = heights
    }

    // MARK: - Tiles

    /// A tile's DEFLATE stream, its two-byte zlib header already skipped,
    /// into a buffer exactly a tile long.
    private static func inflate(_ packed: ArraySlice<UInt8>, into buffer: inout [UInt8]) throws {
        let capacity = buffer.count
        let written = packed.withUnsafeBufferPointer { source in
            buffer.withUnsafeMutableBufferPointer { destination in
                compression_decode_buffer(
                    destination.baseAddress!, capacity, source.baseAddress!, source.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == capacity else { throw CopernicusTileError.inflate(written, capacity) }
    }

    /// One inflated tile into the heights: each of its rows summed back from
    /// the byte differences the predictor took, its bytes put back together
    /// from the four planes it split them into, the most significant first,
    /// then copied in as far as the image reaches — a tile on the east or
    /// south edge is padded past it.
    private static func write(
        _ tile: [UInt8],
        shuffled: inout [UInt8],
        tileWidth: Int,
        tileLength: Int,
        at origin: (row: Int, column: Int),
        into heights: inout [Float],
        rows: Int,
        columns: Int
    ) {
        let rowBytes = tileWidth * MemoryLayout<Float>.size
        let width = min(tileWidth, columns - origin.column)
        let length = min(tileLength, rows - origin.row)
        tile.withUnsafeBufferPointer { tile in
            shuffled.withUnsafeMutableBufferPointer { row in
                heights.withUnsafeMutableBufferPointer { heights in
                    for line in 0..<length {
                        var sum: UInt8 = 0
                        for byte in 0..<rowBytes {
                            sum &+= tile[line * rowBytes + byte]
                            row[byte] = sum
                        }
                        let target = (origin.row + line) * columns + origin.column
                        for post in 0..<width {
                            let bits = UInt32(row[3 * tileWidth + post])
                                | UInt32(row[2 * tileWidth + post]) << 8
                                | UInt32(row[tileWidth + post]) << 16
                                | UInt32(row[post]) << 24
                            heights[target + post] = Float(bitPattern: bits)
                        }
                    }
                }
            }
        }
    }

    // MARK: - The file's directory

    private enum Tag: UInt16 {
        case imageWidth = 256
        case imageLength = 257
        case bitsPerSample = 258
        case compression = 259
        case samplesPerPixel = 277
        case predictor = 317
        case tileWidth = 322
        case tileLength = 323
        case tileOffsets = 324
        case tileByteCounts = 325
        case sampleFormat = 339
        case modelPixelScale = 33550
        case modelTiePoint = 33922
        case geoKeyDirectory = 34735
    }

    /// The first image's tags, read as the TIFF types Copernicus' files use.
    private struct Directory {
        let bytes: [UInt8]
        var entries: [UInt16: (type: UInt16, count: Int, valueOffset: Int)] = [:]

        init(bytes: [UInt8], offset: Int) throws {
            self.bytes = bytes
            guard offset + 2 <= bytes.count else { throw CopernicusTileError.truncated }
            let count = Int(CopernicusTile.uint16(bytes, offset))
            guard offset + 2 + count * CopernicusTile.entryBytes <= bytes.count else {
                throw CopernicusTileError.truncated
            }
            for index in 0..<count {
                let entry = offset + 2 + index * CopernicusTile.entryBytes
                let type = CopernicusTile.uint16(bytes, entry + 2)
                let values = Int(CopernicusTile.uint32(bytes, entry + 4))
                let size = try CopernicusTile.size(of: type) * values
                // A value of four bytes or fewer is in the entry itself.
                let valueOffset = size <= 4 ? entry + 8 : Int(CopernicusTile.uint32(bytes, entry + 8))
                guard valueOffset + size <= bytes.count else { throw CopernicusTileError.truncated }
                entries[CopernicusTile.uint16(bytes, entry)] = (type, values, valueOffset)
            }
        }

        func integers(_ tag: Tag) throws -> [Int] {
            guard let entry = entries[tag.rawValue] else { throw CopernicusTileError.missing(tag: tag.rawValue) }
            return try (0..<entry.count).map { index in
                switch entry.type {
                case CopernicusTile.shortType:
                    Int(CopernicusTile.uint16(bytes, entry.valueOffset + 2 * index))
                case CopernicusTile.longType:
                    Int(CopernicusTile.uint32(bytes, entry.valueOffset + 4 * index))
                default:
                    throw CopernicusTileError.unexpectedType(tag: tag.rawValue, type: entry.type)
                }
            }
        }

        func integer(_ tag: Tag) throws -> Int {
            guard let value = try integers(tag).first else { throw CopernicusTileError.missing(tag: tag.rawValue) }
            return value
        }

        func require(_ tag: Tag, equals expected: Int) throws {
            let value = try integer(tag)
            guard value == expected else { throw CopernicusTileError.unexpected(tag: tag.rawValue, value: value) }
        }

        func doubles(_ tag: Tag) throws -> [Double] {
            guard let entry = entries[tag.rawValue] else { throw CopernicusTileError.missing(tag: tag.rawValue) }
            guard entry.type == CopernicusTile.doubleType else {
                throw CopernicusTileError.unexpectedType(tag: tag.rawValue, type: entry.type)
            }
            return (0..<entry.count).map { index in
                let start = entry.valueOffset + 8 * index
                let bits = (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[start + $1]) << (8 * $1) }
                return Double(bitPattern: bits)
            }
        }
    }

    /// GTRasterTypeGeoKey's value in a GeoKeyDirectory: a header of four
    /// shorts, then four for each key.
    private static func rasterType(in keys: [Int]) -> Int? {
        guard keys.count >= 4 else { return nil }
        let keyCount = keys[3]
        for index in 0..<keyCount {
            let entry = 4 + index * 4
            guard entry + 3 < keys.count else { return nil }
            if keys[entry] == rasterTypeKey, keys[entry + 1] == 0 { return keys[entry + 3] }
        }
        return nil
    }

    private static func size(of type: UInt16) throws -> Int {
        switch type {
        case byteType, asciiType: 1
        case shortType: 2
        case longType: 4
        case doubleType: 8
        default: throw CopernicusTileError.unexpectedType(tag: 0, type: type)
        }
    }

    fileprivate static func uint16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    fileprivate static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private static let headerBytes = 8
    private static let littleEndian = UInt8(ascii: "I")
    private static let classicTIFF: UInt16 = 42
    fileprivate static let entryBytes = 12
    private static let floatBits = 32
    private static let ieeeFloat = 3
    private static let floatingPointPredictor = 3
    /// Adobe's DEFLATE code, and the older one some writers still use.
    private static let deflateCompressions: Set<Int> = [8, 32946]
    private static let zlibHeaderBytes = 2
    private static let tiePointValues = 6
    private static let rasterTypeKey = 1025
    private static let pixelIsPoint = 2
    private static let byteType: UInt16 = 1
    private static let asciiType: UInt16 = 2
    fileprivate static let shortType: UInt16 = 3
    fileprivate static let longType: UInt16 = 4
    fileprivate static let doubleType: UInt16 = 12
}

enum CopernicusTileError: Error, CustomStringConvertible {
    case notLittleEndianTIFF
    case truncated
    case missing(tag: UInt16)
    case unexpected(tag: UInt16, value: Int)
    case unexpectedType(tag: UInt16, type: UInt16)
    case tileCount(Int)
    case placement
    case notPixelIsPoint
    case inflate(Int, Int)

    var description: String {
        switch self {
        case .notLittleEndianTIFF: "not a little-endian TIFF"
        case .truncated: "the file stops short of what its directory names"
        case .missing(let tag): "no tag \(tag)"
        case .unexpected(let tag, let value): "tag \(tag) is \(value), which a Copernicus DEM tile never is"
        case .unexpectedType(let tag, let type): "tag \(tag) is of TIFF type \(type)"
        case .tileCount(let count): "\(count) tiles do not cover the image"
        case .placement: "the tie point or the scale is not a north-west post and a step"
        case .notPixelIsPoint: "the posts are not PixelIsPoint"
        case .inflate(let written, let expected): "a tile inflated to \(written) bytes, not \(expected)"
        }
    }
}

// MARK: - A tile for the script tests

extension CopernicusTile {
    /// A tile laid out exactly as Copernicus lays theirs out — little-endian,
    /// float posts in 1024-post tiles of DEFLATE with the floating-point
    /// predictor, a tie point on the north-west post and `PixelIsPoint` —
    /// whose height at row `r` and column `c` is `height(r, c)`. What
    /// `Scripts/run-script-tests.sh` builds an archive from, so the build and
    /// the reader are exercised with no network; the reader itself was
    /// checked against real tiles, post for post.
    static func fixture(south: Int, west: Int, height: (Int, Int) -> Float) throws -> Data {
        let rows = ElevationSquareGrid.postsPerDegreeOfLatitude
        let columns = ElevationSquareGrid.postsPerDegreeOfLongitude(tileSouth: south)
        let side = 1024
        let across = (columns + side - 1) / side
        let down = (rows + side - 1) / side
        var tiles: [Data] = []
        for tileRow in 0..<down {
            for tileColumn in 0..<across {
                var raw = [UInt8](repeating: 0, count: side * side * 4)
                for line in 0..<side {
                    var planes = [UInt8](repeating: 0, count: side * 4)
                    for post in 0..<side {
                        let row = min(tileRow * side + line, rows - 1)
                        let column = min(tileColumn * side + post, columns - 1)
                        let bits = height(row, column).bitPattern
                        for byte in 0..<4 {
                            planes[byte * side + post] = UInt8(truncatingIfNeeded: bits >> (24 - 8 * byte))
                        }
                    }
                    // The predictor's differences, each byte from the one
                    // before it along the row.
                    for index in stride(from: planes.count - 1, to: 0, by: -1) {
                        planes[index] = planes[index] &- planes[index - 1]
                    }
                    raw.replaceSubrange((line * side * 4)..<((line + 1) * side * 4), with: planes)
                }
                tiles.append(try zlibStream(raw))
            }
        }

        // The directory, its values after it, then the tiles.
        var file = Data([UInt8(ascii: "I"), UInt8(ascii: "I"), 42, 0, 8, 0, 0, 0])
        let geoKeys: [UInt16] = [1, 1, 0, 3, 1024, 0, 1, 2, 1025, 0, 1, 2, 2048, 0, 1, 4326]
        let scale = [1 / Double(columns), 1 / Double(rows), 0]
        let tiePoint = [0, 0, 0, Double(west), Double(south + 1), 0]
        let entryCount = 14
        let valuesStart = 8 + 2 + entryCount * entryBytes + 4
        var values = Data()
        var entries: [(tag: UInt16, type: UInt16, count: Int, value: Data)] = []
        func entry(_ tag: UInt16, _ type: UInt16, _ count: Int, _ bytes: Data) {
            entries.append((tag, type, count, bytes))
        }
        let tileStart = valuesStart + 2 * 4 * tiles.count + 8 * (scale.count + tiePoint.count) + 2 * geoKeys.count
        var offset = tileStart
        var offsets = Data()
        var counts = Data()
        for tile in tiles {
            offsets.append(le32(offset))
            counts.append(le32(tile.count))
            offset += tile.count
        }
        entry(256, longType, 1, le32(columns))
        entry(257, longType, 1, le32(rows))
        entry(258, shortType, 1, le16(32))
        entry(259, shortType, 1, le16(8))
        entry(277, shortType, 1, le16(1))
        entry(317, shortType, 1, le16(3))
        entry(322, shortType, 1, le16(side))
        entry(323, shortType, 1, le16(side))
        entry(324, longType, tiles.count, offsets)
        entry(325, longType, tiles.count, counts)
        entry(339, shortType, 1, le16(3))
        entry(33550, doubleType, scale.count, scale.reduce(into: Data()) { $0.append(le64($1.bitPattern)) })
        entry(33922, doubleType, tiePoint.count, tiePoint.reduce(into: Data()) { $0.append(le64($1.bitPattern)) })
        entry(34735, shortType, geoKeys.count, geoKeys.reduce(into: Data()) { $0.append(le16(Int($1))) })
        precondition(entries.count == entryCount, "the values start where the directory ends")
        file.append(le16(entries.count))
        for item in entries {
            file.append(le16(Int(item.tag)))
            file.append(le16(Int(item.type)))
            file.append(le32(item.count))
            if item.value.count <= 4 {
                file.append(item.value + Data(count: 4 - item.value.count))
            } else {
                file.append(le32(valuesStart + values.count))
                values.append(item.value)
            }
        }
        file.append(le32(0))
        file.append(values)
        precondition(file.count == tileStart, "the tiles start where the directory says")
        for tile in tiles { file.append(tile) }
        return file
    }

    /// A zlib stream: its two-byte header, the DEFLATE body, and the Adler-32
    /// of what it holds.
    private static func zlibStream(_ bytes: [UInt8]) throws -> Data {
        var packed = [UInt8](repeating: 0, count: bytes.count + 1024)
        let written = bytes.withUnsafeBufferPointer { source in
            packed.withUnsafeMutableBufferPointer { destination in
                compression_encode_buffer(
                    destination.baseAddress!, destination.count, source.baseAddress!, source.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { throw CopernicusTileError.inflate(0, bytes.count) }
        var adlerA: UInt32 = 1
        var adlerB: UInt32 = 0
        for byte in bytes {
            adlerA = (adlerA + UInt32(byte)) % 65521
            adlerB = (adlerB + adlerA) % 65521
        }
        var stream = Data([0x78, 0x9C])
        stream.append(contentsOf: packed[..<written])
        let adler = adlerB << 16 | adlerA
        stream.append(contentsOf: [UInt8(adler >> 24), UInt8(truncatingIfNeeded: adler >> 16),
                                   UInt8(truncatingIfNeeded: adler >> 8), UInt8(truncatingIfNeeded: adler)])
        return stream
    }

    private static func le16(_ value: Int) -> Data { Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]) }
    private static func le32(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) } }
    private static func le64(_ value: UInt64) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
}
