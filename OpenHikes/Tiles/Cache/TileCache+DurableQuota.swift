//
//  TileCache+DurableQuota.swift
//  OpenHikes
//
//  Enforces the per-provider ceiling on durably stored tiles that
//  ``TileProvider/durableByteLimit`` declares.
//
//  This exists because of one clause. Stadia's terms of service permit bulk
//  downloading only "for the purpose of caching small amounts of data for
//  offline use in a mobile application, not to exceed 100MB cached at a time
//  per device". That is a promise to the tile host in exactly the way
//  ``TileProvider/supportsBulkDownload`` is, so it is kept by the code that
//  does the writing rather than by the UI that offers it — and it is
//  device-wide, so it cannot be kept by any per-hike cap.
//
//  The policy splits by intent. Auto-save *refuses*: at the ceiling a passively
//  browsed tile is simply not promoted — it stays in the browsing tier, still
//  draws, and still expires on the normal TTL. Nothing a user asked for is
//  deleted by something they didn't. An explicit offline download may
//  *reclaim*, because at 100 MB the ceiling is roughly one route's worth and
//  refusing would mean the second map a user tried to save silently got
//  nothing at all — but only after a confirmation that names the cost, and
//  never touching the tiles of the download being made. See
//  ``reclaimDurableBytes(forProviderID:protecting:byteCount:)``.
//
//  ``enforceDurableByteLimits()`` covers the remaining case, where refusing
//  cannot help: a store that is *already* over, which is what an install
//  predating this ceiling looks like.
//

import Foundation
import os
import Synchronization

nonisolated extension TileCache {

    /// How far under a provider's ceiling ``enforceDurableByteLimits()`` trims.
    /// Leaves room for a session's worth of saves before the ceiling binds
    /// again, so this is an occasional job rather than a per-tile one.
    private static var durableTrimTargetFraction: Double { 4.0 / 5.0 }

    /// The provider that owns `key`, which is namespaced `providerID/z/x/y@scale`.
    static func providerID(forKey key: String) -> String? {
        guard let slash = key.firstIndex(of: "/") else { return nil }
        return String(key[key.startIndex..<slash])
    }

    /// The provider that owns a durable tile *file*, whose name is the key with
    /// its separators flattened to `_` by ``diskName(for:)``.
    ///
    /// Matched longest-id-first rather than by scanning to the first `_`,
    /// because a provider id may itself contain one — `stadia_outdoors` does.
    /// Without the ordering a future `osm_de` would be indistinguishable from
    /// `osm`, and its tiles would be counted against the wrong ceiling.
    static func providerID(forDiskName name: String) -> String? {
        candidateProviderIDs.first { name.hasPrefix($0 + "_") }
    }

    private static var candidateProviderIDs: [String] {
        TileProvider.all.map(\.id).sorted { $0.count > $1.count }
    }

    /// The ceiling for `providerID`, or `nil` where its terms set none.
    ///
    /// The provider catalog's own figure — the licensed one. Instances use
    /// ``durableByteLimit(forProviderID:)`` below, which applies the test
    /// scale; this static form is for the pure provider facts, like
    /// ``OfflineTileDownloader/tileBudget(forProviderID:)``.
    static func durableByteLimit(forProviderID providerID: String?) -> Int64? {
        guard let providerID else { return nil }
        return TileProvider.all.first { $0.id == providerID }?.durableByteLimit
    }

    /// This cache's effective ceiling for `providerID`.
    func durableByteLimit(forProviderID providerID: String?) -> Int64? {
        guard let licensed = Self.durableByteLimit(forProviderID: providerID) else { return nil }
        guard durableByteLimitScale != 1 else { return licensed }
        return max(1, Int64(Double(licensed) * durableByteLimitScale))
    }

    // MARK: Measurement

    /// Ensures `providerID`'s durable total is known, walking the durable
    /// directory once if it isn't.
    ///
    /// **Call with no other lock held.** This is the directory walk the
    /// reservation below must not perform inline. Two threads racing here both
    /// measure and install the same total, which is wasteful but not wrong.
    func ensureDurableMeasurement(forProviderID providerID: String) {
        assertOffMainThread(
            "ensureDurableMeasurement enumerates the durable tile directory — call it off the main thread"
        )
        let measured = durableProviderBytes.withLock { $0[providerID] != nil }
        guard !measured else { return }

        let interval = RenderSignpost.beginInterval("TileDurableQuotaScan")
        defer { RenderSignpost.endInterval("TileDurableQuotaScan", interval) }

        var total: Int64 = 0
        for file in allTileFiles(in: durableDirectory)
        where Self.providerID(forDiskName: file.lastPathComponent) == providerID {
            total += fileSize(file)
        }
        durableProviderBytes.withLock { bytes in
            // Another thread may have measured and then had writes recorded
            // against its total while this walk was running. Its answer is at
            // least as current as this one.
            guard bytes[providerID] == nil else { return }
            bytes[providerID] = total
        }
        RenderSignpost.mark("TileDurableQuotaMeasured", "provider=\(providerID) bytes=\(total)")
    }

    /// Forgets every measured total, so the next reservation re-measures.
    ///
    /// Invalidation rather than per-file decrements: durable tiles are deleted
    /// by five different paths (the TTL sweep, the unclaimed sweep, the cache
    /// trim, a keyed removal, a full clear), and a decrement missed by any one
    /// of them would leave the total drifting permanently upward until it
    /// refused every write. Re-measuring costs one directory walk on the next
    /// durable write, and deletions are rare next to writes.
    ///
    /// The exception is a path that mutates exactly one durable file whose
    /// size it already knows, on the browse path — the lazy TTL deletion in
    /// ``freshModificationDate(for:in:referenceDate:)`` and the durable
    /// re-fetch write. Those use ``adjustDurableBytes(forProviderID:by:)``
    /// below, because invalidating per tile would turn the next reservation
    /// into a directory walk and, during a bulk download over expired
    /// coverage, one walk per tile saved.
    func invalidateDurableMeasurements() {
        durableProviderBytes.withLock { $0.removeAll() }
    }

    /// Moves a *measured* provider's total by `delta`, and does nothing at all
    /// when there is no measurement to move.
    ///
    /// The no-op is the point: a partial total is worse than no total. An
    /// unmeasured provider is re-measured by the next reservation, and that
    /// walk reads whatever this caller just wrote or deleted — so skipping the
    /// adjustment loses nothing, while installing `delta` as if it were the
    /// whole store would under-count everything already on disk and let the
    /// ceiling be overrun.
    ///
    /// Safe to call with ``mutationVersions`` held: it takes
    /// ``durableProviderBytes`` — the inner lock of the two, and never the
    /// other way round — and never measures, so no directory walk happens
    /// under a lock.
    func adjustDurableBytes(forProviderID providerID: String?, by delta: Int64) {
        guard delta != 0,
              let providerID,
              durableByteLimit(forProviderID: providerID) != nil
        else { return }

        durableProviderBytes.withLock { bytes in
            guard let current = bytes[providerID] else { return }
            bytes[providerID] = max(0, current + delta)
        }
    }

    /// Durable bytes currently attributed to `providerID`, if measured.
    ///
    /// A rough per-tile size, used only to decide *up front* whether a planned
    /// download can fit under a provider's ceiling.
    ///
    /// The same ~30 KB figure ``cacheByteLimit`` is reasoned from. Nothing is
    /// enforced with it — ``reserveDurableBytes(forKey:byteCount:)`` weighs
    /// every tile as it actually arrives — so an estimate that runs a little
    /// high costs a slightly cautious plan rather than a broken promise.
    static var estimatedTileBytes: Int64 { 30 * 1024 }

    /// How much of `providerID`'s ceiling is spent, or `nil` where its terms
    /// set no ceiling.
    func durableSpace(forProviderID providerID: String) -> (limit: Int64, used: Int64)? {
        guard let limit = durableByteLimit(forProviderID: providerID) else { return nil }
        ensureDurableMeasurement(forProviderID: providerID)
        let used = durableProviderBytes.withLock { $0[providerID] ?? 0 }
        return (limit, used)
    }

    /// Bytes of `providerID`'s durable tiles that eviction could reach — that
    /// is, everything except the keys `protecting` names.
    func reclaimableDurableBytes(
        forProviderID providerID: String,
        protecting protectedKeys: Set<String>
    ) -> Int64 {
        assertOffMainThread(
            "reclaimableDurableBytes enumerates the durable tile directory — call it off the main thread"
        )
        let protectedNames = Set(protectedKeys.map(diskName(for:)))
        var total: Int64 = 0
        for file in allTileFiles(in: durableDirectory)
        where Self.providerID(forDiskName: file.lastPathComponent) == providerID
            && !protectedNames.contains(file.lastPathComponent) {
            total += fileSize(file)
        }
        return total
    }

    /// Frees at least `byteCount` of `providerID`'s durable tiles, oldest
    /// first, never touching a key `protecting` names. Returns the bytes freed,
    /// which falls short only when there was nothing left to take.
    ///
    /// The one path in the app that deletes offline coverage a hike still
    /// claims, and it exists because the alternative is worse: a 100 MB
    /// device-wide ceiling is roughly one route's download, so without this the
    /// second hike a user tried to save would silently get nothing at all. It
    /// runs only behind an explicit confirmation — see
    /// ``OfflineTileDownloader/Phase`` — and never for auto-save, which has no
    /// user standing behind it to ask.
    ///
    /// Oldest-first by modification date, so what goes is the ground the user
    /// has been away from longest. The affected hike keeps its manifest entry;
    /// the tile refills the next time that ground is browsed online.
    @discardableResult func reclaimDurableBytes(
        forProviderID providerID: String,
        protecting protectedKeys: Set<String>,
        byteCount: Int64
    ) -> Int64 {
        assertOffMainThread(
            "reclaimDurableBytes stats and deletes tile files synchronously — call it off the main thread"
        )
        guard byteCount > 0 else { return 0 }
        let protectedNames = Set(protectedKeys.map(diskName(for:)))

        var candidates: [(url: URL, size: Int64, modified: Date)] = []
        for file in allTileFiles(in: durableDirectory)
        where Self.providerID(forDiskName: file.lastPathComponent) == providerID
            && !protectedNames.contains(file.lastPathComponent) {
            let values = try? file.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
            )
            candidates.append((
                file,
                Int64(values?.fileSize ?? 0),
                values?.contentModificationDate ?? .distantPast
            ))
        }

        let interval = RenderSignpost.beginInterval("TileDurableReclaim")
        var freed: Int64 = 0
        for tile in candidates.sorted(by: { $0.modified < $1.modified }) {
            guard freed < byteCount else { break }
            let removed = mutationVersions.withLock { versions -> Bool in
                guard removeItemIgnoringNotFound(
                    at: tile.url,
                    operation: "reclaim durable tile for a confirmed download"
                ) else { return false }
                versions.invalidateAll()
                return true
            }
            guard removed else { continue }
            freed += tile.size
        }

        durableProviderBytes.withLock { bytes in
            guard let current = bytes[providerID] else { return }
            bytes[providerID] = max(0, current - freed)
        }
        RenderSignpost.mark(
            "TileDurableReclaimed",
            "provider=\(providerID) requested=\(byteCount) freed=\(freed)"
        )
        RenderSignpost.endInterval("TileDurableReclaim", interval)
        return freed
    }

    // MARK: Reservation

    /// Claims `byteCount` of `key`'s provider's ceiling, or reports that there
    /// is no room. Always balance a `true` with either ``commitDurableBytes``
    /// (a no-op that documents the write landed) or ``releaseDurableBytes``.
    ///
    /// Returns `true` immediately for a provider with no ceiling, which is
    /// every provider but Stadia — so the common path is one dictionary lookup
    /// and no directory walk ever.
    func reserveDurableBytes(forKey key: String, byteCount: Int64) -> Bool {
        guard let providerID = Self.providerID(forKey: key),
              let limit = durableByteLimit(forProviderID: providerID)
        else { return true }

        ensureDurableMeasurement(forProviderID: providerID)

        return durableProviderBytes.withLock { bytes in
            let current = bytes[providerID] ?? 0
            guard current + byteCount <= limit else { return false }
            bytes[providerID] = current + byteCount
            return true
        }
    }

    /// Gives back a reservation whose bytes never reached disk.
    func releaseDurableBytes(forKey key: String, byteCount: Int64) {
        guard let providerID = Self.providerID(forKey: key),
              durableByteLimit(forProviderID: providerID) != nil
        else { return }

        durableProviderBytes.withLock { bytes in
            guard let current = bytes[providerID] else { return }
            bytes[providerID] = max(0, current - byteCount)
        }
    }

    /// Whether `key`'s provider is at its ceiling. Used to explain a refusal,
    /// not to decide one — ``reserveDurableBytes(forKey:byteCount:)`` is the
    /// decision, and it is atomic.
    func isDurableLimitReached(forKey key: String) -> Bool {
        guard let providerID = Self.providerID(forKey: key),
              let limit = durableByteLimit(forProviderID: providerID)
        else { return false }
        ensureDurableMeasurement(forProviderID: providerID)
        return durableProviderBytes.withLock { ($0[providerID] ?? 0) >= limit }
    }

    // MARK: Enforcement

    /// Brings any provider that is already over its ceiling back under it,
    /// oldest tile first. Returns the bytes freed.
    ///
    /// Runs at launch, and normally frees nothing: the reservation above stops
    /// a store reaching the ceiling in the first place. It is what corrects an
    /// install whose tiles were saved before the ceiling existed, and what
    /// would correct one whose ceiling is lowered by a future change in a
    /// provider's terms.
    ///
    /// Unlike ``trimCache(claimedBy:limit:)`` this *does* delete tiles a hike
    /// claims, because there is no other way to come back under a limit the
    /// terms impose. The hike's manifest still lists the key; the tile refills
    /// the next time that ground is browsed online.
    @discardableResult func enforceDurableByteLimits() -> Int64 {
        assertOffMainThread(
            "enforceDurableByteLimits() stats and deletes tile files synchronously — call it off the main thread"
        )
        let capped = TileProvider.all.filter { $0.durableByteLimit != nil }
        guard !capped.isEmpty else { return 0 }

        let interval = RenderSignpost.beginInterval("TileDurableQuotaEnforce")
        var freed: Int64 = 0
        defer {
            RenderSignpost.mark("TileDurableQuotaEnforced", "freed=\(freed)")
            RenderSignpost.endInterval("TileDurableQuotaEnforce", interval)
        }

        for provider in capped {
            guard let limit = durableByteLimit(forProviderID: provider.id) else { continue }
            freed += trimDurableTiles(forProviderID: provider.id, limit: limit)
        }
        return freed
    }

    /// Deletes `providerID`'s oldest durable tiles until its total is under
    /// `limit` with headroom. No-op when it already is.
    private func trimDurableTiles(forProviderID providerID: String, limit: Int64) -> Int64 {
        var tiles: [(url: URL, size: Int64, modified: Date)] = []
        var total: Int64 = 0

        for file in allTileFiles(in: durableDirectory)
        where Self.providerID(forDiskName: file.lastPathComponent) == providerID {
            let values = try? file.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
            )
            let size = Int64(values?.fileSize ?? 0)
            tiles.append((file, size, values?.contentModificationDate ?? .distantPast))
            total += size
        }

        guard total > limit else {
            // Nothing to do, but the walk above is the same one the lazy
            // measurement would perform, so install its answer.
            durableProviderBytes.withLock { $0[providerID] = total }
            return 0
        }

        let target = Int64(Double(limit) * Self.durableTrimTargetFraction)
        var freed: Int64 = 0
        for tile in tiles.sorted(by: { $0.modified < $1.modified }) {
            guard total - freed > target else { break }
            let removed = mutationVersions.withLock { versions -> Bool in
                guard removeItemIgnoringNotFound(
                    at: tile.url,
                    operation: "trim durable tile over provider limit"
                ) else { return false }
                versions.invalidateAll()
                return true
            }
            guard removed else { continue }
            freed += tile.size
        }

        durableProviderBytes.withLock { $0[providerID] = total - freed }
        Self.logger.notice(
            // swiftlint:disable:next line_length
            "Trimmed \(freed, privacy: .public) durable bytes for \(providerID, privacy: .public) (was \(total, privacy: .public), limit \(limit, privacy: .public))"
        )
        return freed
    }
}
