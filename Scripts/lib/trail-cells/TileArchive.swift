//
//  TileArchive.swift
//  trail-cells
//
//  A PMTiles archive written a tile at a time, and read back a tile at a
//  time by its own directories, as the tile server reads it: the trail
//  maker's graph (`RoutingBuild.swift`) and the squares of the other three
//  sets (`Pack.swift`) are each one, kept in the tile server's bucket. See
//  `SquareArchive.swift` for which tile a square is.
//
//  The archive's root directory has to be in its first 16 KiB, and its size
//  is known only once every tile is written. So the first 16 KiB are held
//  open, the tiles written after them, the metadata and the leaf directories
//  after the tiles, and the header and the root written last into the space
//  held for them. The tile server reads every section by its offset.
//
//  Every tile goes in as it is, and is served as it is: a square's file is
//  already packed in its own envelope, and its type is none PMTiles names,
//  which the server answers as `application/octet-stream`.
//

import Foundation

/// A PMTiles archive written tile by tile: the first 16 KiB held for the
/// header and the root directory, the tiles after them, then the metadata
/// and the leaf directories, and the header and the root written last.
final class TileArchiveWriter {
    static let tileDataOffset = UInt64(PMTilesHeader.rootReadBytes)

    private let handle: FileHandle
    private let zooms: ClosedRange<Int>
    private var entries: [PMTilesEntry] = []
    private var tileDataLength: UInt64 = 0
    /// Whether every tile came after the one before it along the curve,
    /// which is what makes the data's order the directory's.
    private(set) var isClustered = true

    /// - Parameter zooms: The zooms the archive's tiles are at, which its
    ///   header says and the tile server holds every request to.
    init(url: URL, zooms: ClosedRange<Int>) throws {
        self.zooms = zooms
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(count: PMTilesHeader.rootReadBytes))
    }

    func append(_ bytes: Data, tileID: UInt64) throws {
        if let last = entries.last, last.tileID >= tileID { isClustered = false }
        entries.append(PMTilesEntry(tileID: tileID, offset: tileDataLength, length: UInt64(bytes.count), runLength: 1))
        try handle.write(contentsOf: bytes)
        tileDataLength += UInt64(bytes.count)
    }

    /// Writes the rest and closes the file. Returns how long it is.
    func finish(metadata: Data) throws -> UInt64 {
        if !isClustered { entries.sort { $0.tileID < $1.tileID } }
        for (earlier, later) in zip(entries, entries.dropFirst()) where earlier.tileID == later.tileID {
            throw TileArchiveError.tileWrittenTwice(earlier.tileID)
        }
        let (root, leaves) = PMTilesLayout.directories(for: entries)
        var header = PMTilesHeader()
        header.rootDirectoryOffset = UInt64(PMTilesHeader.byteCount)
        header.rootDirectoryLength = UInt64(root.count)
        header.tileDataOffset = Self.tileDataOffset
        header.tileDataLength = tileDataLength
        header.metadataOffset = Self.tileDataOffset + tileDataLength
        header.metadataLength = UInt64(metadata.count)
        header.leafDirectoryOffset = header.metadataOffset + header.metadataLength
        header.leafDirectoryLength = UInt64(leaves.count)
        header.addressedTiles = UInt64(entries.count)
        header.tileEntries = UInt64(entries.count)
        header.tileContents = UInt64(entries.count)
        header.isClustered = isClustered
        header.internalCompression = PMTilesCompression.uncompressed.rawValue
        // Each tile is a file in its own envelope, packed already.
        header.tileCompression = PMTilesCompression.uncompressed.rawValue
        // Not a type PMTiles names, which the tile server serves as it is.
        header.tileType = 0
        header.minimumZoom = UInt8(zooms.lowerBound)
        header.maximumZoom = UInt8(zooms.upperBound)
        header.bounds = [-1_800_000_000, -850_511_287, 1_800_000_000, 850_511_287]
        header.centerZoom = UInt8(zooms.lowerBound)
        header.center = [0, 0]
        let prefix = header.bytes + root
        guard prefix.count <= PMTilesHeader.rootReadBytes else { throw TileArchiveError.rootTooLarge(root.count) }
        try handle.write(contentsOf: metadata)
        try handle.write(contentsOf: Data(leaves))
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(prefix))
        try handle.close()
        return header.leafDirectoryOffset + header.leafDirectoryLength
    }
}

/// An archive `TileArchiveWriter` wrote, read back by its directories, as
/// the tile server reads it. A leaf directory is read once however many of
/// its tiles are asked for.
final class TileArchiveReader {
    let header: PMTilesHeader
    private let handle: FileHandle
    private let root: [PMTilesEntry]
    private var leaves: [UInt64: [PMTilesEntry]] = [:]

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        header = try PMTilesHeader(bytes: Self.read(handle, 0, UInt64(PMTilesHeader.byteCount)))
        root = try PMTilesDirectory.entries(
            from: Self.read(handle, header.rootDirectoryOffset, header.rootDirectoryLength)
        )
    }

    deinit {
        try? handle.close()
    }

    /// The tile at `z`/`x`/`y`, or `nil` where the archive holds none.
    func tile(z: Int, x: Int, y: Int) throws -> Data? {
        try tile(id: PMTilesTileID.id(z: z, x: x, y: y))
    }

    func tile(id: UInt64) throws -> Data? {
        var entries = root
        while let entry = PMTilesDirectory.entry(holding: id, in: entries) {
            guard entry.isLeaf else {
                return Data(try Self.read(handle, header.tileDataOffset + entry.offset, entry.length))
            }
            entries = try leaf(at: entry)
        }
        return nil
    }

    /// How many tiles the directories hold, leaves and runs counted out.
    func tileCount() throws -> UInt64 {
        var count: UInt64 = 0
        for entry in root {
            if entry.isLeaf {
                count += try leaf(at: entry).reduce(0) { $0 + $1.runLength }
            } else {
                count += entry.runLength
            }
        }
        return count
    }

    private func leaf(at entry: PMTilesEntry) throws -> [PMTilesEntry] {
        if let read = leaves[entry.offset] { return read }
        let read = try PMTilesDirectory.entries(
            from: Self.read(handle, header.leafDirectoryOffset + entry.offset, entry.length)
        )
        leaves[entry.offset] = read
        return read
    }

    private static func read(_ handle: FileHandle, _ offset: UInt64, _ length: UInt64) throws -> [UInt8] {
        try handle.seek(toOffset: offset)
        let bytes = try handle.read(upToCount: Int(length)) ?? Data()
        guard bytes.count == Int(length) else { throw PMTilesError.truncated }
        return Array(bytes)
    }
}

enum TileArchiveError: Error, CustomStringConvertible {
    case tileWrittenTwice(UInt64)
    case rootTooLarge(Int)

    var description: String {
        switch self {
        case .tileWrittenTwice(let id):
            "tile \(id) was written twice."
        case .rootTooLarge(let bytes):
            "the root directory is \(bytes) bytes, past the archive's first \(PMTilesHeader.rootReadBytes)."
        }
    }
}
