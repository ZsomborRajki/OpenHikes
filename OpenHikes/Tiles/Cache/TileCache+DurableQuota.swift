//
//  TileCache+DurableQuota.swift
//  OpenHikes
//
//  Enforces the ceiling on durably stored tiles that
//  ``TileProvider/durableQuota`` declares.
//
//  This exists because of one clause. Stadia's terms of service permit bulk
//  downloading only "for the purpose of caching small amounts of data for
//  offline use in a mobile application, not to exceed 100MB cached at a time
//  per device". That is a promise to the tile host in exactly the way
//  ``TileProvider/supportsBulkDownload`` is, so it is kept by the code that
//  does the writing rather than by the UI that offers it — and it is
//  device-wide, so it cannot be kept by any per-hike cap.
//
//  It is licence-wide too. The clause covers every Stadia tile on the device,
//  whichever style it was drawn in, so totals are kept per
//  ``DurableTileQuota`` and every provider sharing one is counted, refused,
//  reclaimed and trimmed together. A provider id is still what callers pass:
//  each of them holds a tile or a source, and the quota is looked up from it.
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

    /// How far under a quota's ceiling ``enforceDurableByteLimits()`` trims.
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

    /// Layers included: a layer's tiles are namespaced by its id exactly as a
    /// provider's are, and none of them carries a ceiling — but a layer file
    /// matched to no id at all would be one nothing can attribute.
    private static var candidateProviderIDs: [String] {
        (TileProvider.all.map(\.id) + TileLayer.all.map(\.id)).sorted { $0.count > $1.count }
    }

    /// The quota `providerID`'s durable tiles count against, or `nil` where
    /// its terms set none.
    static func durableQuota(forProviderID providerID: String?) -> DurableTileQuota? {
        guard let providerID else { return nil }
        return TileProvider.all.first { $0.id == providerID }?.durableQuota
    }

    /// Whether the durable tile file `name` counts against `quota` — true for
    /// every style the quota's licence covers, not just the one asking.
    static func diskName(_ name: String, countsAgainst quota: DurableTileQuota) -> Bool {
        durableQuota(forProviderID: providerID(forDiskName: name)) == quota
    }

    /// The providers whose durable tiles a reclaim for `providerID` may take:
    /// every style its quota covers, or only its own where it has none.
    static func providerIDs(sharingCeilingWith providerID: String) -> Set<String> {
        guard let quota = durableQuota(forProviderID: providerID) else { return [providerID] }
        return Set(quota.providers.map(\.id))
    }

    /// The ceiling for `providerID`, or `nil` where its terms set none.
    ///
    /// The provider catalog's own figure — the licensed one. Instances use
    /// ``durableByteLimit(forProviderID:)`` below, which applies the test
    /// scale; this static form is for the pure provider facts, like
    /// ``OfflineTileDownloader/tileBudget(forProviderID:)``.
    static func durableByteLimit(forProviderID providerID: String?) -> Int64? {
        durableQuota(forProviderID: providerID)?.byteLimit
    }

    /// This cache's effective ceiling for `quota`.
    func durableByteLimit(for quota: DurableTileQuota) -> Int64 {
        guard durableByteLimitScale != 1 else { return quota.byteLimit }
        return max(1, Int64(Double(quota.byteLimit) * durableByteLimitScale))
    }

    /// This cache's effective ceiling for `providerID`'s quota.
    func durableByteLimit(forProviderID providerID: String?) -> Int64? {
        Self.durableQuota(forProviderID: providerID).map(durableByteLimit(for:))
    }

    // MARK: Measurement

    /// Ensures `quota`'s durable total is known, walking the durable
    /// directory once if it isn't.
    ///
    /// **Call with no other lock held.** This is the directory walk the
    /// reservation below must not perform inline. Two threads racing here both
    /// measure and install the same total, which is wasteful but not wrong.
    func ensureDurableMeasurement(for quota: DurableTileQuota) {
        assertOffMainThread(
            "ensureDurableMeasurement enumerates the durable tile directory — call it off the main thread"
        )
        let measured = durableQuotaBytes.withLock { $0[quota.id] != nil }
        guard !measured else { return }

        var total: Int64 = 0
        for file in allTileFiles(in: durableDirectory)
        where Self.diskName(file.lastPathComponent, countsAgainst: quota) {
            total += fileSize(file)
        }
        durableQuotaBytes.withLock { bytes in
            // Another thread may have measured and then had writes recorded
            // against its total while this walk was running. Its answer is at
            // least as current as this one.
            guard bytes[quota.id] == nil else { return }
            bytes[quota.id] = total
        }
    }

    /// Forgets every measured total, so the next reservation re-measures.
    ///
    /// Invalidation rather than per-file decrements: durable tiles are deleted
    /// by four different paths (the unclaimed sweep, the cache trim, a keyed
    /// removal, a full clear), and a decrement missed by any one of them would
    /// leave the total drifting permanently upward until it refused every
    /// write. Re-measuring costs one directory walk on the next durable write,
    /// and deletions are rare next to writes.
    ///
    /// Age is not one of those paths. A durable tile past its TTL is refreshed
    /// in place rather than deleted — see
    /// ``TileCache/storedModificationDate(for:in:referenceDate:)`` — so the
    /// browse path moves this total only by *writing*, through the durable
    /// re-fetch in ``TileCache/storeFetchedTile(_:forKey:in:token:)``. That one
    /// uses ``adjustDurableBytes(forProviderID:by:)`` below, because
    /// invalidating per tile would turn the next reservation into a directory
    /// walk and, during a bulk download over stale coverage, one walk per tile
    /// saved.
    func invalidateDurableMeasurements() {
        durableQuotaBytes.withLock { $0.removeAll() }
    }

    /// Moves the *measured* total of `providerID`'s quota by `delta`, and does
    /// nothing at all when there is no measurement to move.
    ///
    /// The no-op is the point: a partial total is worse than no total. An
    /// unmeasured provider is re-measured by the next reservation, and that
    /// walk reads whatever this caller just wrote or deleted — so skipping the
    /// adjustment loses nothing, while installing `delta` as if it were the
    /// whole store would under-count everything already on disk and let the
    /// ceiling be overrun.
    ///
    /// Safe to call with ``mutationVersions`` held: it takes
    /// ``durableQuotaBytes`` — the inner lock of the two, and never the
    /// other way round — and never measures, so no directory walk happens
    /// under a lock.
    func adjustDurableBytes(forProviderID providerID: String?, by delta: Int64) {
        guard delta != 0,
              let quota = Self.durableQuota(forProviderID: providerID)
        else { return }

        durableQuotaBytes.withLock { bytes in
            guard let current = bytes[quota.id] else { return }
            bytes[quota.id] = max(0, current + delta)
        }
    }

    /// A rough per-tile size, used only to decide *up front* whether a planned
    /// download can fit under a provider's ceiling.
    ///
    /// The same ~30 KB figure ``cacheByteLimit`` is reasoned from. Nothing is
    /// enforced with it — ``reserveDurableBytes(forKey:byteCount:)`` weighs
    /// every tile as it actually arrives — so an estimate that runs a little
    /// high costs a slightly cautious plan rather than a broken promise.
    static var estimatedTileBytes: Int64 { 30 * 1024 }

    /// How much of `providerID`'s ceiling is spent, or `nil` where its terms
    /// set no ceiling. `used` is the whole quota's: every style sharing it.
    func durableSpace(forProviderID providerID: String) -> (limit: Int64, used: Int64)? {
        guard let quota = Self.durableQuota(forProviderID: providerID) else { return nil }
        ensureDurableMeasurement(for: quota)
        let used = durableQuotaBytes.withLock { $0[quota.id] ?? 0 }
        return (durableByteLimit(for: quota), used)
    }

    /// Bytes of durable tiles under `providerID`'s quota that eviction could
    /// reach — that is, every style's tiles except the keys `protecting`
    /// names. See ``providerIDs(sharingCeilingWith:)``.
    func reclaimableDurableBytes(
        forProviderID providerID: String,
        protecting protectedKeys: Set<String>
    ) -> Int64 {
        assertOffMainThread(
            "reclaimableDurableBytes enumerates the durable tile directory — call it off the main thread"
        )
        let scope = Self.providerIDs(sharingCeilingWith: providerID)
        let protectedNames = Set(protectedKeys.map(diskName(for:)))
        var total: Int64 = 0
        for file in allTileFiles(in: durableDirectory)
        where Self.providerID(forDiskName: file.lastPathComponent).map(scope.contains) == true
            && !protectedNames.contains(file.lastPathComponent) {
            total += fileSize(file)
        }
        return total
    }

    /// Frees at least `byteCount` of the durable tiles under `providerID`'s
    /// quota, oldest first, never touching a key `protecting` names. Returns
    /// the bytes freed, which falls short only when there was nothing left to
    /// take.
    ///
    /// Across the quota, not just the provider: a Stamen Terrain download that
    /// does not fit may take Stadia Outdoors tiles, because it is the shared
    /// 100 MB that is short, and freeing only Terrain's own tiles could leave
    /// it short however much the user agreed to give up.
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
        let scope = Self.providerIDs(sharingCeilingWith: providerID)
        let protectedNames = Set(protectedKeys.map(diskName(for:)))

        var candidates: [(url: URL, size: Int64, modified: Date)] = []
        for file in allTileFiles(in: durableDirectory)
        where Self.providerID(forDiskName: file.lastPathComponent).map(scope.contains) == true
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

        var freed: Int64 = 0
        for tile in candidates.sorted(by: { $0.modified < $1.modified }) {
            guard freed < byteCount else { break }
            // A reclaim runs while the map is being browsed, which is the
            // case ``removeTileInvalidatingToken(at:operation:)`` is shaped
            // around.
            let removed = removeTileInvalidatingToken(
                at: tile.url,
                operation: "reclaim durable tile for a confirmed download"
            )
            guard removed else { continue }
            freed += tile.size
        }

        if let quota = Self.durableQuota(forProviderID: providerID) {
            durableQuotaBytes.withLock { bytes in
                guard let current = bytes[quota.id] else { return }
                bytes[quota.id] = max(0, current - freed)
            }
        }
        return freed
    }

    // MARK: Reservation

    /// Claims `byteCount` of the ceiling `key`'s provider counts against, or
    /// reports that there is no room. There is no commit call: a `true` reservation *is* the
    /// accounting for those bytes, so a caller whose write lands is already
    /// balanced and does nothing further.
    ///
    /// A `true` that does not end with `byteCount` newly on disk must be given
    /// back with ``releaseDurableBytes(forKey:byteCount:)``. That covers the
    /// write failing, and also the write finding another writer's durable copy
    /// already there — those bytes are counted against the ceiling once
    /// already, and keeping this reservation too would spend it twice for one
    /// tile.
    ///
    /// Returns `true` immediately for a provider with no ceiling, which is
    /// every provider but Stadia's — so the common path is one catalog lookup
    /// and no directory walk ever.
    func reserveDurableBytes(forKey key: String, byteCount: Int64) -> Bool {
        guard let quota = Self.durableQuota(forProviderID: Self.providerID(forKey: key)) else {
            return true
        }
        let limit = durableByteLimit(for: quota)

        ensureDurableMeasurement(for: quota)

        return durableQuotaBytes.withLock { bytes in
            let current = bytes[quota.id] ?? 0
            guard current + byteCount <= limit else { return false }
            bytes[quota.id] = current + byteCount
            return true
        }
    }

    /// Gives back a reservation that this caller's write did not account
    /// for — because it failed, or because the bytes were already on disk
    /// and already counted by the writer that put them there.
    func releaseDurableBytes(forKey key: String, byteCount: Int64) {
        guard let quota = Self.durableQuota(forProviderID: Self.providerID(forKey: key)) else {
            return
        }

        durableQuotaBytes.withLock { bytes in
            guard let current = bytes[quota.id] else { return }
            bytes[quota.id] = max(0, current - byteCount)
        }
    }

    /// Whether the ceiling `key`'s provider counts against is reached. Used to explain a refusal,
    /// not to decide one — ``reserveDurableBytes(forKey:byteCount:)`` is the
    /// decision, and it is atomic.
    func isDurableLimitReached(forKey key: String) -> Bool {
        guard let quota = Self.durableQuota(forProviderID: Self.providerID(forKey: key)) else {
            return false
        }
        let limit = durableByteLimit(for: quota)
        ensureDurableMeasurement(for: quota)
        return durableQuotaBytes.withLock { ($0[quota.id] ?? 0) >= limit }
    }

    // MARK: Enforcement

    /// Brings any quota that is already over its ceiling back under it,
    /// oldest tile first and whichever style it belongs to. Returns the bytes
    /// freed.
    ///
    /// Runs at launch, and normally frees nothing: the reservation above stops
    /// a store reaching the ceiling in the first place. It is what corrects an
    /// install whose tiles were saved before the ceiling existed, and what
    /// would correct one whose ceiling is lowered by a future change in a
    /// provider's terms — and one holding a full 100 MB for each of two
    /// Stadia styles, from a build that counted them apart.
    ///
    /// Unlike ``trimCache(claimedBy:limit:)`` this *does* delete tiles a hike
    /// claims, because there is no other way to come back under a limit the
    /// terms impose. The hike's manifest still lists the key; the tile refills
    /// the next time that ground is browsed online.
    @discardableResult func enforceDurableByteLimits() -> Int64 {
        assertOffMainThread(
            "enforceDurableByteLimits() stats and deletes tile files synchronously — call it off the main thread"
        )
        // Each quota once, however many styles share it — trimming per
        // provider would give each style the whole ceiling.
        var freed: Int64 = 0
        for quota in DurableTileQuota.all {
            freed += trimDurableTiles(for: quota, limit: durableByteLimit(for: quota))
        }
        return freed
    }

    /// Deletes the oldest durable tiles under `quota` until its total is under
    /// `limit` with headroom. No-op when it already is.
    private func trimDurableTiles(for quota: DurableTileQuota, limit: Int64) -> Int64 {
        var tiles: [(url: URL, size: Int64, modified: Date)] = []
        var total: Int64 = 0

        for file in allTileFiles(in: durableDirectory)
        where Self.diskName(file.lastPathComponent, countsAgainst: quota) {
            let values = try? file.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
            )
            let size = Int64(values?.fileSize ?? 0)
            tiles.append((file, size, values?.contentModificationDate ?? .distantPast))
            total += size
        }

        guard total > limit else {
            // Nothing to do, but the walk above is the same one the lazy
            // measurement would perform, so install its answer — unless a
            // reservation or promotion has installed one since this walk
            // began, in which case that total already accounts for bytes
            // this walk could not have seen and must not be overwritten.
            durableQuotaBytes.withLock { bytes in
                guard bytes[quota.id] == nil else { return }
                bytes[quota.id] = total
            }
            return 0
        }

        let target = Int64(Double(limit) * Self.durableTrimTargetFraction)
        var freed: Int64 = 0
        for tile in tiles.sorted(by: { $0.modified < $1.modified }) {
            guard total - freed > target else { break }
            // This one runs at launch, alongside the first draw pass's
            // fetches, so the per-row bump
            // ``removeTileInvalidatingToken(at:operation:)`` makes matters
            // here for the same reason it does during browsing.
            let removed = removeTileInvalidatingToken(
                at: tile.url,
                operation: "trim durable tile over licence limit"
            )
            guard removed else { continue }
            freed += tile.size
        }

        // Apply the trim as a relative delta, matching
        // ``reclaimDurableBytes(forProviderID:protecting:byteCount:)``: a tile
        // reserved or promoted between the walk above and this lock is in the
        // current total but absent from `total`, so installing `total - freed`
        // absolutely would erase it and let the ceiling over-admit. Only when
        // no measurement is live does the freshly walked figure stand in.
        durableQuotaBytes.withLock { bytes in
            if let current = bytes[quota.id] {
                bytes[quota.id] = max(0, current - freed)
            } else {
                bytes[quota.id] = max(0, total - freed)
            }
        }
        Self.logger.notice(
            // swiftlint:disable:next line_length
            "Trimmed \(freed, privacy: .public) durable bytes for \(quota.id, privacy: .public) (was \(total, privacy: .public), limit \(limit, privacy: .public))"
        )
        return freed
    }
}
