//
//  PMTilesFile.swift
//  OpenHikes
//
//  The PMTiles v3 format, as far as a downloaded country needs it: the
//  header, the directories, the tile ids along their Hilbert curve, gzip, and
//  the layout a writer gives an archive. The format is
//  github.com/protomaps/PMTiles/blob/main/spec/v3/spec.md, and the tile
//  server's own reader (`worker.js` in the OpenHikesTiles repository) is the
//  same code in JavaScript, held byte for byte to Protomaps' library.
//
//  The tool that cuts the countries out of the planet
//  (`Scripts/offline-countries.sh`) compiles this file as it stands, beside
//  `PackedBytes.swift`, and so does the one that writes the trail maker's
//  archive (`Scripts/trail-cells.sh`), so it imports Foundation and nothing
//  of the app's and says `nonisolated` on every declaration.
//
//  Every count, offset and length is read from a file that came over the
//  network, so each is checked against the bytes that are there before it is
//  used.
//

import Foundation

/// Why some bytes are not a PMTiles archive this reader takes.
nonisolated enum PMTilesError: Error, Equatable {
    /// A directory, an offset or a length says something no writer would.
    case corrupt
    case notPMTiles
    /// Directories nested deeper than the format allows.
    case tooDeep
    /// The file ends before what its header says is in it.
    case truncated
    case unsupportedCompression(UInt8)
    case unsupportedVersion(UInt8)
}

/// How a directory, the metadata or a tile is packed.
nonisolated enum PMTilesCompression: UInt8, Sendable {
    case brotli = 3
    case gzip = 2
    /// The format's `none`, named so it is never read as an optional's.
    case uncompressed = 1
    case unknown = 0
    case zstd = 4
}

// MARK: - The header

/// The archive's first 127 bytes: where everything else is, and what the
/// tiles are.
nonisolated struct PMTilesHeader: Equatable, Sendable {
    static let byteCount = 127
    /// The header and the root directory always fit in this much of the
    /// start of an archive, so one read finds both.
    static let rootReadBytes = 16_384
    static let magic = Array("PMTiles".utf8)
    static let version: UInt8 = 3

    var rootDirectoryOffset: UInt64 = 0
    var rootDirectoryLength: UInt64 = 0
    var metadataOffset: UInt64 = 0
    var metadataLength: UInt64 = 0
    var leafDirectoryOffset: UInt64 = 0
    var leafDirectoryLength: UInt64 = 0
    var tileDataOffset: UInt64 = 0
    var tileDataLength: UInt64 = 0
    var addressedTiles: UInt64 = 0
    var tileEntries: UInt64 = 0
    var tileContents: UInt64 = 0
    var isClustered = false
    var internalCompression = PMTilesCompression.uncompressed.rawValue
    var tileCompression = PMTilesCompression.uncompressed.rawValue
    var tileType: UInt8 = 0
    var minimumZoom: UInt8 = 0
    var maximumZoom: UInt8 = 0
    /// West, south, east and north, in ten-millionths of a degree.
    var bounds: [Int32] = [0, 0, 0, 0]
    var centerZoom: UInt8 = 0
    /// Longitude and latitude, in ten-millionths of a degree.
    var center: [Int32] = [0, 0]

    init() {
        // Every field has its default; a writer fills them in.
    }

    /// Reads the header at the start of `bytes`.
    init(bytes: [UInt8]) throws(PMTilesError) {
        guard bytes.count >= Self.byteCount else { throw .truncated }
        var reader = PMTilesLittleEndian(bytes: bytes)
        guard reader.read(count: Self.magic.count) == Self.magic else { throw .notPMTiles }
        let found = reader.readByte()
        guard found == Self.version else { throw .unsupportedVersion(found) }
        rootDirectoryOffset = reader.read64()
        rootDirectoryLength = reader.read64()
        metadataOffset = reader.read64()
        metadataLength = reader.read64()
        leafDirectoryOffset = reader.read64()
        leafDirectoryLength = reader.read64()
        tileDataOffset = reader.read64()
        tileDataLength = reader.read64()
        addressedTiles = reader.read64()
        tileEntries = reader.read64()
        tileContents = reader.read64()
        isClustered = reader.readByte() == 1
        internalCompression = reader.readByte()
        tileCompression = reader.readByte()
        tileType = reader.readByte()
        minimumZoom = reader.readByte()
        maximumZoom = reader.readByte()
        bounds = (0..<4).map { _ in reader.read32() }
        centerZoom = reader.readByte()
        center = (0..<2).map { _ in reader.read32() }
    }

    /// The header as an archive starts with it.
    var bytes: [UInt8] {
        var writer = PMTilesLittleEndian(bytes: Self.magic)
        writer.bytes.append(Self.version)
        for value in [
            rootDirectoryOffset, rootDirectoryLength, metadataOffset, metadataLength,
            leafDirectoryOffset, leafDirectoryLength, tileDataOffset, tileDataLength,
            addressedTiles, tileEntries, tileContents,
        ] {
            writer.write64(value)
        }
        writer.bytes.append(contentsOf: [
            isClustered ? 1 : 0, internalCompression, tileCompression, tileType, minimumZoom, maximumZoom,
        ])
        bounds.forEach { writer.write32($0) }
        writer.bytes.append(centerZoom)
        center.forEach { writer.write32($0) }
        return writer.bytes
    }
}

/// Little-endian fields, read in order from a buffer already checked to be
/// long enough, or written in order.
nonisolated struct PMTilesLittleEndian {
    var bytes: [UInt8]
    private var offset = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func readByte() -> UInt8 {
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func read(count: Int) -> [UInt8] {
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    mutating func read64() -> UInt64 {
        read(count: UInt64.bitWidth / UInt8.bitWidth).reversed().reduce(0) { $0 << UInt8.bitWidth | UInt64($1) }
    }

    mutating func read32() -> Int32 {
        let raw = read(count: UInt32.bitWidth / UInt8.bitWidth).reversed().reduce(UInt32(0)) { value, byte in
            value << UInt8.bitWidth | UInt32(byte)
        }
        return Int32(bitPattern: raw)
    }

    mutating func write64(_ value: UInt64) {
        for index in 0..<UInt64.bitWidth / UInt8.bitWidth {
            bytes.append(UInt8(truncatingIfNeeded: value >> (index * UInt8.bitWidth)))
        }
    }

    mutating func write32(_ value: Int32) {
        let raw = UInt32(bitPattern: value)
        for index in 0..<UInt32.bitWidth / UInt8.bitWidth {
            bytes.append(UInt8(truncatingIfNeeded: raw >> (index * UInt8.bitWidth)))
        }
    }
}

// MARK: - Directories

/// One row of a directory: a run of tiles with the same bytes, or, with a
/// run length of zero, a leaf directory that holds the tiles from its id on.
nonisolated struct PMTilesEntry: Equatable, Sendable {
    var tileID: UInt64
    /// From the start of the tile data, or of the leaf directories for a leaf.
    var offset: UInt64
    var length: UInt64
    var runLength: UInt64

    var isLeaf: Bool { runLength == 0 }
}

nonisolated enum PMTilesDirectory {
    /// The entries a directory's bytes, unpacked, hold: four columns of
    /// varints — tile id steps, run lengths, lengths, then offsets, where zero
    /// means straight after the entry before and anything else is offset + 1.
    static func entries(from bytes: [UInt8]) throws(PMTilesError) -> [PMTilesEntry] {
        do {
            var reader = PackedReader(bytes: bytes)
            // Each entry is four varints, at least a byte each.
            let count = try reader.readCount(atMost: bytes.count / 4)
            var entries: [PMTilesEntry] = []
            entries.reserveCapacity(count)
            var tileID: UInt64 = 0
            for _ in 0..<count {
                let (next, overflow) = tileID.addingReportingOverflow(try reader.readVarint())
                guard !overflow else { throw PMTilesError.corrupt }
                tileID = next
                entries.append(PMTilesEntry(tileID: tileID, offset: 0, length: 0, runLength: 0))
            }
            for index in entries.indices { entries[index].runLength = try reader.readVarint() }
            for index in entries.indices { entries[index].length = try reader.readVarint() }
            for index in entries.indices {
                let value = try reader.readVarint()
                if value == 0, index > 0 {
                    let previous = entries[index - 1]
                    let (follows, overflow) = previous.offset.addingReportingOverflow(previous.length)
                    guard !overflow else { throw PMTilesError.corrupt }
                    entries[index].offset = follows
                } else {
                    guard value > 0 else { throw PMTilesError.corrupt }
                    entries[index].offset = value - 1
                }
            }
            return entries
        } catch {
            throw .corrupt
        }
    }

    /// `entries`, sorted by tile id, as a directory's bytes before packing.
    static func bytes(of entries: [PMTilesEntry]) -> [UInt8] {
        var writer = PackedWriter()
        writer.write(UInt64(entries.count))
        var previousID: UInt64 = 0
        for entry in entries {
            writer.write(entry.tileID - previousID)
            previousID = entry.tileID
        }
        entries.forEach { writer.write($0.runLength) }
        entries.forEach { writer.write($0.length) }
        for (index, entry) in entries.enumerated() {
            let previous = index > 0 ? entries[index - 1] : nil
            if let previous, entry.offset == previous.offset + previous.length {
                writer.write(0)
            } else {
                writer.write(entry.offset + 1)
            }
        }
        return writer.bytes
    }

    /// The entry that holds tile `id`, or the leaf directory that would: the
    /// last entry at or before it, if it reaches it.
    static func entry(holding id: UInt64, in entries: [PMTilesEntry]) -> PMTilesEntry? {
        var low = 0
        var high = entries.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let tileID = entries[middle].tileID
            if tileID < id {
                low = middle + 1
            } else if tileID > id {
                high = middle - 1
            } else {
                return entries[middle]
            }
        }
        guard high >= 0 else { return nil }
        let entry = entries[high]
        return entry.isLeaf || id - entry.tileID < entry.runLength ? entry : nil
    }
}

// MARK: - Tile ids

nonisolated enum PMTilesTileID {
    /// The deepest zoom whose ids fit the format's 64 bits.
    static let maximumZoom = 31

    /// Tiles of every zoom above `z`, then the tile's place along a Hilbert
    /// curve at `z`.
    static func id(z: Int, x: Int, y: Int) -> UInt64 {
        precondition((0...maximumZoom).contains(z), "zoom \(z) is outside the format's range")
        // (4^z − 1) / 3: one, four, sixteen … tiles above.
        var id = ((UInt64(1) << UInt64(2 * z)) - 1) / 3
        var column = UInt64(x)
        var row = UInt64(y)
        var size: UInt64 = z == 0 ? 0 : UInt64(1) << UInt64(z - 1)
        while size >= 1 {
            let right: UInt64 = column & size == 0 ? 0 : 1
            let down: UInt64 = row & size == 0 ? 0 : 1
            id += size * size * ((3 * right) ^ down)
            if down == 0 {
                // Only the bits below `size` are read from here on, so the
                // flip is taken within them, where it cannot go negative.
                if right == 1 {
                    column = (size - 1) - (column & (size - 1))
                    row = (size - 1) - (row & (size - 1))
                }
                swap(&column, &row)
            }
            size >>= 1
        }
        return id
    }
}

// MARK: - Gzip

/// RFC 1952: a ten-byte header, optional fields, a raw DEFLATE stream, then
/// the CRC-32 and the unpacked length.
nonisolated enum PMTilesGzip {
    private static let firstSignatureByte: UInt8 = 0x1F
    private static let secondSignatureByte: UInt8 = 0x8B
    private static let signature = [firstSignatureByte, secondSignatureByte]
    private static let deflateMethod: UInt8 = 8
    private static let fixedHeaderBytes = 10
    private static let trailerBytes = 8
    private static let hasHeaderCRC: UInt8 = 2
    private static let hasExtra: UInt8 = 4
    private static let hasName: UInt8 = 8
    private static let hasComment: UInt8 = 16

    /// `bytes` unpacked, refusing anything that unpacks past
    /// ``PackedEnvelope/maximumBodyBytes``.
    static func inflated(_ bytes: [UInt8]) throws(PMTilesError) -> [UInt8] {
        guard bytes.count >= fixedHeaderBytes + trailerBytes,
              Array(bytes.prefix(signature.count)) == signature,
              bytes[signature.count] == deflateMethod
        else { throw .corrupt }
        let flags = bytes[signature.count + 1]
        var start = fixedHeaderBytes
        let end = bytes.count - trailerBytes
        if flags & hasExtra != 0 {
            guard start + 2 <= end else { throw .corrupt }
            start += 2 + (Int(bytes[start]) | Int(bytes[start + 1]) << UInt8.bitWidth)
        }
        for flag in [hasName, hasComment] where flags & flag != 0 {
            guard let terminator = bytes[min(start, end)..<end].firstIndex(of: 0) else { throw .corrupt }
            start = terminator + 1
        }
        if flags & hasHeaderCRC != 0 { start += 2 }
        guard start < end else { throw .corrupt }
        var trailer = PMTilesLittleEndian(bytes: Array(bytes[end + trailerBytes / 2..<bytes.count]))
        let size = Int(UInt32(bitPattern: trailer.read32()))
        guard size <= PackedEnvelope.maximumBodyBytes else { throw .corrupt }
        do {
            return try PackedDeflate.decompressed(Array(bytes[start..<end]), count: size)
        } catch {
            throw .corrupt
        }
    }

    /// `bytes` as stored with `compression`, unpacked.
    static func unpacked(_ bytes: [UInt8], compression: UInt8) throws(PMTilesError) -> [UInt8] {
        guard let method = PMTilesCompression(rawValue: compression) else {
            throw .unsupportedCompression(compression)
        }
        switch method {
        case .uncompressed, .unknown: return bytes
        case .gzip: return try inflated(bytes)
        case .brotli, .zstd: throw .unsupportedCompression(compression)
        }
    }
}

// MARK: - Writing

/// How a writer lays an archive out: the header, the root directory, the
/// metadata, the leaf directories, then the tile data, which the writer
/// appends itself. Directories and metadata are written unpacked, which the
/// format allows and every reader takes; beside a country's tiles they are a
/// rounding error.
nonisolated enum PMTilesLayout {
    /// The first leaf size tried. Doubled until the root fits.
    static let leafEntries = 4096

    /// Everything before the tile data: `header` with its offsets and
    /// lengths filled in for `entries`, sorted by tile id, and `metadata`.
    static func prefix(
        header template: PMTilesHeader,
        entries: [PMTilesEntry],
        metadata: [UInt8],
        tileDataLength: UInt64
    ) -> [UInt8] {
        let (root, leaves) = directories(for: entries)
        var header = template
        header.internalCompression = PMTilesCompression.uncompressed.rawValue
        header.rootDirectoryOffset = UInt64(PMTilesHeader.byteCount)
        header.rootDirectoryLength = UInt64(root.count)
        header.metadataOffset = header.rootDirectoryOffset + header.rootDirectoryLength
        header.metadataLength = UInt64(metadata.count)
        header.leafDirectoryOffset = header.metadataOffset + header.metadataLength
        header.leafDirectoryLength = UInt64(leaves.count)
        header.tileDataOffset = header.leafDirectoryOffset + header.leafDirectoryLength
        header.tileDataLength = tileDataLength
        return header.bytes + root + metadata + leaves
    }

    /// The root directory's bytes, and the leaf directories' after one
    /// another: no leaves at all when every entry fits the root.
    static func directories(for entries: [PMTilesEntry]) -> (root: [UInt8], leaves: [UInt8]) {
        let rootLimit = PMTilesHeader.rootReadBytes - PMTilesHeader.byteCount
        let whole = PMTilesDirectory.bytes(of: entries)
        if whole.count <= rootLimit { return (whole, []) }
        var size = leafEntries
        while true {
            var leaves: [UInt8] = []
            var pointers: [PMTilesEntry] = []
            for start in stride(from: 0, to: entries.count, by: size) {
                let leaf = PMTilesDirectory.bytes(of: Array(entries[start..<min(start + size, entries.count)]))
                pointers.append(
                    PMTilesEntry(
                        tileID: entries[start].tileID,
                        offset: UInt64(leaves.count),
                        length: UInt64(leaf.count),
                        runLength: 0
                    )
                )
                leaves.append(contentsOf: leaf)
            }
            let root = PMTilesDirectory.bytes(of: pointers)
            if root.count <= rootLimit { return (root, leaves) }
            size *= 2
        }
    }
}
