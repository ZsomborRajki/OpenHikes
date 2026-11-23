//
//  Extract.swift
//  offline-countries
//
//  Cuts the tiles of one coverage out of an archive into an archive of their
//  own: what `pmtiles extract` does, written out here so the tool needs
//  nothing installed. The source's directories are walked only where the
//  coverage has tiles, its tile data is read in large ranges in the order it
//  lies, and each distinct tile is written once, in that order, so a
//  clustered source gives a clustered country.
//

import Foundation

/// A tile of the coverage, where the source keeps its bytes.
struct LocatedTile {
    let id: UInt64
    let offset: UInt64
    let length: UInt64
}

final class Extractor: Sendable {
    let source: any RangeSource
    let header: PMTilesHeader
    private let root: [PMTilesEntry]
    /// Requests out at once, for the directories and the data alike.
    static let concurrency = 12
    /// Gaps up to this between two tiles wanted are read rather than asked
    /// for twice; a range stops growing at ``largestRange``.
    static let largestGap: UInt64 = 256 * 1024
    static let largestRange: UInt64 = 32 * 1024 * 1024

    init(source: any RangeSource) async throws {
        self.source = source
        let start = try await source.read(offset: 0, length: min(UInt64(PMTilesHeader.rootReadBytes), source.size))
        header = try PMTilesHeader(bytes: start)
        let rootBytes = try await source.read(offset: header.rootDirectoryOffset, length: header.rootDirectoryLength)
        root = try PMTilesDirectory.entries(from: PMTilesGzip.unpacked(rootBytes, compression: header.internalCompression))
    }

    func metadata() async throws -> [UInt8] {
        let bytes = try await source.read(offset: header.metadataOffset, length: header.metadataLength)
        return try PMTilesGzip.unpacked(bytes, compression: header.internalCompression)
    }

    /// Where the source keeps each of `wanted`, sorted, that it has at all.
    func locate(_ wanted: [UInt64]) async throws -> [LocatedTile] {
        try await locate(wanted[...], in: root, depth: 0).sorted { $0.id < $1.id }
    }

    private func locate(_ wanted: ArraySlice<UInt64>, in entries: [PMTilesEntry], depth: Int) async throws
        -> [LocatedTile] {
        guard depth < PMTilesArchive.maximumDirectoryDepth else { throw PMTilesError.tooDeep }
        var found: [LocatedTile] = []
        var leaves: [(PMTilesEntry, ArraySlice<UInt64>)] = []
        var next = wanted.startIndex
        for (index, entry) in entries.enumerated() {
            let end = entry.isLeaf
                ? (index + 1 < entries.count ? entries[index + 1].tileID : UInt64.max)
                : entry.tileID + entry.runLength
            while next < wanted.endIndex, wanted[next] < entry.tileID { next += 1 }
            var past = next
            while past < wanted.endIndex, wanted[past] < end { past += 1 }
            guard past > next else { continue }
            if entry.isLeaf {
                leaves.append((entry, wanted[next..<past]))
            } else {
                found += wanted[next..<past].map { LocatedTile(id: $0, offset: entry.offset, length: entry.length) }
            }
            next = past
        }
        for batch in stride(from: 0, to: leaves.count, by: Self.concurrency) {
            let slice = leaves[batch..<min(batch + Self.concurrency, leaves.count)]
            found += try await withThrowingTaskGroup(of: [LocatedTile].self) { group in
                for (entry, ids) in slice {
                    group.addTask {
                        let bytes = try await self.source.read(
                            offset: self.header.leafDirectoryOffset + entry.offset,
                            length: entry.length
                        )
                        let leaf = try PMTilesDirectory.entries(
                            from: PMTilesGzip.unpacked(bytes, compression: self.header.internalCompression)
                        )
                        return try await self.locate(ids, in: leaf, depth: depth + 1)
                    }
                }
                return try await group.reduce(into: []) { $0 += $1 }
            }
        }
        return found
    }

    struct Written {
        let addressed: Int
        let entries: Int
        let contents: Int
        let bytes: UInt64
    }

    /// Writes `tiles` to `url` as an archive of their own, with `template`'s
    /// zooms, bounds and center and the source's tile type and compression.
    /// Each tile of `filled` the source does not have is written as `fill`,
    /// once, after the source's: bytes already in the source's compression.
    func write(
        _ tiles: [LocatedTile],
        filling filled: [UInt64] = [],
        with fill: [UInt8] = [],
        to url: URL,
        header template: PMTilesHeader,
        metadata: [UInt8]
    ) async throws -> Written {
        // Each distinct tile once, in the order the source keeps them.
        var lengths: [UInt64: UInt64] = [:]
        for tile in tiles { lengths[tile.offset] = tile.length }
        let offsets = lengths.keys.sorted()
        var moved: [UInt64: UInt64] = [:]
        var total: UInt64 = 0
        for offset in offsets {
            moved[offset] = total
            total += lengths[offset] ?? 0
        }
        let copied = total
        let filling = Set(filled).subtracting(tiles.map(\.id))
        var placed = tiles.map { (id: $0.id, offset: moved[$0.offset] ?? 0, length: $0.length) }
        if !filling.isEmpty {
            placed += filling.map { (id: $0, offset: copied, length: UInt64(fill.count)) }
            placed.sort { $0.id < $1.id }
            total += UInt64(fill.count)
        }
        var entries: [PMTilesEntry] = []
        for tile in placed {
            if let last = entries.last, last.tileID + last.runLength == tile.id,
               last.offset == tile.offset, last.length == tile.length {
                entries[entries.count - 1].runLength += 1
            } else {
                entries.append(PMTilesEntry(tileID: tile.id, offset: tile.offset, length: tile.length, runLength: 1))
            }
        }
        var header = template
        header.tileCompression = self.header.tileCompression
        header.tileType = self.header.tileType
        header.addressedTiles = UInt64(placed.count)
        header.tileEntries = UInt64(entries.count)
        header.tileContents = UInt64(offsets.count + (filling.isEmpty ? 0 : 1))
        header.isClustered = Self.isClustered(entries)
        let prefix = PMTilesLayout.prefix(header: header, entries: entries, metadata: metadata, tileDataLength: total)

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        try output.truncate(atOffset: 0)
        try output.write(contentsOf: Data(prefix))

        let ranges = Self.ranges(of: offsets, lengths: lengths)
        var written: UInt64 = 0
        for batch in stride(from: 0, to: ranges.count, by: Self.concurrency) {
            let slice = Array(ranges[batch..<min(batch + Self.concurrency, ranges.count)])
            let read = try await withThrowingTaskGroup(of: (Int, [UInt8]).self) { group in
                for (index, range) in slice.enumerated() {
                    group.addTask {
                        (index, try await self.source.read(
                            offset: self.header.tileDataOffset + range.start,
                            length: range.end - range.start
                        ))
                    }
                }
                return try await group.reduce(into: [Int: [UInt8]]()) { $0[$1.0] = $1.1 }
            }
            for (index, range) in slice.enumerated() {
                guard let bytes = read[index] else { throw SourceError.shortRead(expected: 0, got: 0) }
                var chunk = Data()
                for offset in range.offsets {
                    let start = Int(offset - range.start)
                    chunk.append(contentsOf: bytes[start..<start + Int(lengths[offset] ?? 0)])
                }
                try output.write(contentsOf: chunk)
                written += UInt64(chunk.count)
            }
            if batch / Self.concurrency % 20 == 0 {
                let share = Double(written) / Double(max(total, 1)) * 100
                print(String(format: "  %@: %.0f%% of %.2f GB", url.lastPathComponent, share, Double(total) / 1e9))
            }
        }
        guard written == copied else { throw SourceError.shortRead(expected: copied, got: Int(written)) }
        if !filling.isEmpty { try output.write(contentsOf: Data(fill)) }
        return Written(
            addressed: placed.count,
            entries: entries.count,
            contents: Int(header.tileContents),
            bytes: UInt64(prefix.count) + total
        )
    }

    private struct ReadRange {
        let start: UInt64
        var end: UInt64
        var offsets: [UInt64]
    }

    private static func ranges(of offsets: [UInt64], lengths: [UInt64: UInt64]) -> [ReadRange] {
        var ranges: [ReadRange] = []
        for offset in offsets {
            let end = offset + (lengths[offset] ?? 0)
            if var last = ranges.last, offset <= last.end + largestGap, end - last.start <= largestRange {
                last.end = max(last.end, end)
                last.offsets.append(offset)
                ranges[ranges.count - 1] = last
            } else {
                ranges.append(ReadRange(start: offset, end: end, offsets: [offset]))
            }
        }
        return ranges
    }

    /// Whether, in tile order, every tile's bytes either follow on from the
    /// last new ones or repeat bytes already written: the format's clustered.
    static func isClustered(_ entries: [PMTilesEntry]) -> Bool {
        var next: UInt64 = 0
        for entry in entries {
            if entry.offset == next {
                next += entry.length
            } else if entry.offset > next {
                return false
            }
        }
        return true
    }
}
