//
//  CuratedTrailStore.swift
//  OpenHikes
//
//  The curated routes this device has already downloaded, kept on disk.
//
//  ``CuratedTrailSource``'s memory cache used to be the whole of it, and the
//  reasoning for that is worth restating before the reasoning for this,
//  because it was right about the thing it was about: a z12 tile file of the
//  kind ``OverpassTrailGraphProvider`` keeps is 6.9 km across at 47°N, and a
//  community search is 10–40 km of *radius*, so the smallest search this
//  feature allows already spans about 25 tiles. Tiles are the wrong unit here.
//  The unit is the **relation**, and that has not changed.
//
//  What changed is the estimate of what a launch costs. The old bargain —
//  "a browse session is minutes long, OSM data changes under a cache anyway"
//  — priced a miss as one round trip. Against a volunteer-run API that allows
//  a handful of slots per address, a miss is priced in `429`s: two passes per
//  search, every search, and a hiker who opens the app twice in an evening
//  pays for the same valley twice. The geometry pass is 420 KB to 1.4 MB a
//  page. That is the measurement the old paragraph said nobody had.
//
//  ## What is kept, and what is deliberately not
//
//  One JSON file per relation, holding the route and the moment it was
//  fetched. Nothing else: no index, no manifest, no second file listing what
//  the first ones contain. An index is the coherence problem the memory-only
//  version was right to refuse, and the one question it would answer quickly —
//  *which of these are near here* — is asked only when Overpass has already
//  refused, where the cost of reading every file is paid instead of a network
//  round trip that was never going to arrive.
//
//  **An absent relation is not written down.** ``CuratedTrailSource`` caches
//  "Overpass has nothing to draw for this" in memory, which is right for a
//  session — a relation that is gone stays gone while the app is running — and
//  wrong for thirty days, because the fix for a route too fragmented to
//  assemble is somebody editing OSM, and a file saying *nothing here* would
//  outlast the edit.
//

import CoreLocation
import Foundation

/// The on-disk half of the curated trail cache.
///
/// A value rather than an actor: every caller is already inside
/// ``CuratedTrailSource``'s isolation, which is where the serialisation this
/// needs comes from. How the directory behaves — expiry, the re-stamp on use,
/// the trim — is ``OverpassFileStore``'s, and is the same for every
/// OpenStreetMap cache this app keeps.
nonisolated struct CuratedTrailStore: Sendable {
    /// How many routes are kept on disk.
    ///
    /// Eight pages of results, against the memory cache's four. A route's line
    /// is a few hundred points, which is 10–30 KB of JSON, so this is a few
    /// megabytes at its fullest — the same order as the 64 graph tiles next to
    /// it, in a directory the system may reclaim at any time.
    static let maximumFiles = 200

    /// Where the files live for an ordinary launch.
    ///
    /// `Caches`, not `Application Support`: every byte here is re-downloadable
    /// and none of it is the hiker's. The system deleting the lot under
    /// pressure costs a round trip, which is exactly the trade this directory
    /// exists to express.
    static func defaultDirectory() -> URL? {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("CuratedTrails", isDirectory: true)
    }

    /// One relation, and when it was downloaded — the file format.
    ///
    /// Internal rather than private, and only because the compiler needs it:
    /// a `private` type as the generic argument of ``files`` crashes Swift
    /// 6.4's IRGen ("Global is external, but doesn't have external or weak
    /// linkage") when the file is compiled in a batch with its neighbours.
    nonisolated struct StoredTrail: OverpassFileEntry {
        let fetchedAt: Date
        let trail: CuratedTrail

        var value: CuratedTrail { trail }

        init(fetchedAt: Date, value: CuratedTrail) {
            self.fetchedAt = fetchedAt
            trail = value
        }
    }

    private let files: OverpassFileStore<StoredTrail>

    init(directory: URL, clock: @escaping @Sendable () -> Date) {
        files = OverpassFileStore(directory: directory, maximumFiles: Self.maximumFiles, clock: clock)
    }
}

nonisolated extension CuratedTrailStore {
    /// The stored route for `relationID`, or `nil` for one that was never
    /// stored or has expired. A hit counts as a use — see
    /// ``OverpassFileStore/value(named:)``.
    func trail(of relationID: Int64) -> CuratedTrail? {
        files.value(named: Self.fileName(for: relationID))
    }

    /// Writes `trail` down, replacing whatever was there.
    func save(_ trail: CuratedTrail) {
        save([trail])
    }

    /// Writes a whole geometry pass down, and trims once — a page is
    /// twenty-five routes, and a trim per route would read a directory of two
    /// hundred files twenty-five times for one search.
    func save(_ trails: [CuratedTrail]) {
        files.save(trails.map { (name: Self.fileName(for: $0.relationID), value: $0) })
    }

    /// Stored routes whose pin stands within `area`, nearest first.
    ///
    /// **This is what a refused search draws, and it does not claim to be the
    /// answer.** There is no record of which areas have been listed, so this
    /// cannot say whether it is showing all the waymarked routes around there
    /// or the four a hiker happened to open last month. What makes that honest
    /// is where it is used: only when Overpass has already refused, and beside
    /// the caption under *Search this area* that says so — see
    /// ``CuratedTrailOutage`` and ``MergedCommunityTransport``.
    ///
    /// By the pin, which is the box's centre — the same point the row's
    /// distance and the map's annotation use, so a trail the list offers is a
    /// trail the map can show. See ``CuratedTrailQuery/centre(of:)``.
    func trails(near area: CommunitySearchArea, limit: Int) -> [CuratedTrail] {
        files.values(near: area, limit: limit, at: \.coordinate)
    }

    private static func fileName(for relationID: Int64) -> String {
        "relation-\(relationID)"
    }
}
