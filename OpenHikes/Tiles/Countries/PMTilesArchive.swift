//
//  PMTilesArchive.swift
//  OpenHikes
//
//  One PMTiles archive on the device, read where it lies: the header and the
//  root directory once, a leaf directory when a tile first needs it, and each
//  tile's bytes straight out of the file. A downloaded country is one of
//  these, or two with its extras, and nothing of it is unpacked into the tile
//  cache. The format is in `PMTilesFile.swift`.
//
//  Safe from any thread, because MapKit draws on several. A read holds the
//  lock that guards the file handle and the leaf directories kept, which is
//  microseconds beside the drawing it feeds.
//
//  `Scripts/offline-countries.sh` compiles this file into its tool too, which
//  reads every country back through it before the country is listed.
//

import Foundation
import Synchronization

nonisolated final class PMTilesArchive: Sendable {
    /// Leaf directories kept in memory. A country's are tens of kilobytes
    /// each, and a screen of tiles needs a handful.
    static let keptLeafDirectories = 64
    /// The format's own limit on how deep leaf directories nest.
    static let maximumDirectoryDepth = 4

    let header: PMTilesHeader
    private let fileSize: UInt64
    private let root: [PMTilesEntry]
    private let state: Mutex<State>

    private struct State {
        let handle: FileHandle
        var leaves: [UInt64: [PMTilesEntry]] = [:]
        var leafOrder: [UInt64] = []
    }

    /// Opens the archive at `url`, reading its header and root directory.
    init(contentsOf url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let start = try handle.read(upToCount: PMTilesHeader.rootReadBytes) ?? Data()
        let parsed = try PMTilesHeader(bytes: Array(start))
        guard Self.fits(parsed.tileDataOffset, parsed.tileDataLength, in: size),
              Self.fits(parsed.leafDirectoryOffset, parsed.leafDirectoryLength, in: size),
              Self.fits(parsed.rootDirectoryOffset, parsed.rootDirectoryLength, in: size)
        else { throw PMTilesError.truncated }
        let rootEnd = Int(parsed.rootDirectoryOffset + parsed.rootDirectoryLength)
        let rootBytes: [UInt8]
        if rootEnd <= start.count {
            rootBytes = Array(start[Int(parsed.rootDirectoryOffset)..<rootEnd])
        } else {
            rootBytes = try Self.read(parsed.rootDirectoryOffset, parsed.rootDirectoryLength, from: handle, size: size)
        }
        header = parsed
        fileSize = size
        root = try PMTilesDirectory.entries(
            from: PMTilesGzip.unpacked(rootBytes, compression: parsed.internalCompression)
        )
        state = Mutex(State(handle: handle))
    }

    /// The tile's bytes, unpacked, or `nil` where the archive has none.
    func tile(z: Int, x: Int, y: Int) throws(PMTilesError) -> Data? {
        guard z >= Int(header.minimumZoom), z <= Int(header.maximumZoom), z <= PMTilesTileID.maximumZoom,
              x >= 0, y >= 0, x < 1 << z, y < 1 << z
        else { return nil }
        let id = PMTilesTileID.id(z: z, x: x, y: y)
        return try state.withLock { state throws(PMTilesError) -> Data? in
            var entries = root
            for _ in 0..<Self.maximumDirectoryDepth {
                guard let entry = PMTilesDirectory.entry(holding: id, in: entries) else { return nil }
                guard entry.isLeaf else {
                    let bytes = try bytes(at: header.tileDataOffset, entry, in: &state)
                    return Data(try PMTilesGzip.unpacked(bytes, compression: header.tileCompression))
                }
                entries = try leaf(at: header.leafDirectoryOffset, entry, in: &state)
            }
            throw .tooDeep
        }
    }

    private func leaf(at base: UInt64, _ entry: PMTilesEntry, in state: inout State) throws(PMTilesError)
        -> [PMTilesEntry] {
        let offset = base + entry.offset
        if let kept = state.leaves[offset] { return kept }
        let bytes = try bytes(at: base, entry, in: &state)
        let entries = try PMTilesDirectory.entries(
            from: PMTilesGzip.unpacked(bytes, compression: header.internalCompression)
        )
        state.leaves[offset] = entries
        state.leafOrder.append(offset)
        if state.leafOrder.count > Self.keptLeafDirectories {
            state.leaves[state.leafOrder.removeFirst()] = nil
        }
        return entries
    }

    /// The bytes `entry` points at, from `base`, checked against the section
    /// the header gives them before anything is read.
    private func bytes(at base: UInt64, _ entry: PMTilesEntry, in state: inout State) throws(PMTilesError)
        -> [UInt8] {
        let (offset, overflow) = base.addingReportingOverflow(entry.offset)
        guard !overflow, entry.length <= UInt64(PackedEnvelope.maximumBodyBytes) else { throw .corrupt }
        do {
            return try Self.read(offset, entry.length, from: state.handle, size: fileSize)
        } catch let error as PMTilesError {
            throw error
        } catch {
            throw .truncated
        }
    }

    private static func fits(_ offset: UInt64, _ length: UInt64, in size: UInt64) -> Bool {
        let (end, overflow) = offset.addingReportingOverflow(length)
        return !overflow && end <= size
    }

    private static func read(_ offset: UInt64, _ length: UInt64, from handle: FileHandle, size: UInt64) throws
        -> [UInt8] {
        guard fits(offset, length, in: size) else { throw PMTilesError.truncated }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: Int(length)) ?? Data()
        guard data.count == Int(length) else { throw PMTilesError.truncated }
        return Array(data)
    }
}
