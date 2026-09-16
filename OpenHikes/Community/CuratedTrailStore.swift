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

import Algorithms
import CoreLocation
import Foundation

/// The on-disk half of the curated trail cache.
///
/// A value rather than an actor: every caller is already inside
/// ``CuratedTrailSource``'s isolation, which is where the serialisation this
/// needs comes from, and an actor of its own would add a second hop to every
/// read for nothing. Nothing here touches the main actor — see the repository
/// instructions on disk work.
nonisolated struct CuratedTrailStore: Sendable {
    /// How long a stored route is trusted, in seconds.
    ///
    /// The thirty days ``OverpassTrailGraphProvider`` gives a walking graph,
    /// for the same reason: this is OSM's own geometry, which moves when
    /// somebody maps a re-route, not when the hiker walks. A day would throw
    /// away the whole point; forever would leave a trail that has been
    /// re-routed drawn along a path that is no longer there.
    static let lifetime: TimeInterval = 30 * 24 * 60 * 60

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

    /// One relation, and when it was downloaded.
    private struct StoredTrail: Codable {
        let fetchedAt: Date
        let trail: CuratedTrail
    }

    private let directory: URL
    private let clock: @Sendable () -> Date

    init(directory: URL, clock: @escaping @Sendable () -> Date) {
        self.directory = directory
        self.clock = clock
    }
}

// MARK: - One relation at a time

nonisolated extension CuratedTrailStore {
    /// The stored route for `relationID`, or `nil` for one that was never
    /// stored or has expired.
    ///
    /// A hit re-stamps the file's modification date, which is what makes the
    /// eviction below *least recently used* rather than least recently
    /// written. Without it, the twenty-five routes a hiker keeps coming back
    /// to would be the twenty-five oldest files in the directory, and the
    /// first trim would take exactly those.
    func trail(of relationID: Int64) -> CuratedTrail? {
        let url = fileURL(for: relationID)
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(StoredTrail.self, from: data)
        else { return nil }
        guard clock().timeIntervalSince(stored.fetchedAt) <= Self.lifetime else {
            // Expired rather than corrupt, and removed for the same reason a
            // corrupt one is: it will never be read again, and leaving it
            // costs a slot in the trim below that a usable route could have.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        touch(url)
        return stored.trail
    }

    /// Writes `trail` down, replacing whatever was there.
    ///
    /// Failure is silent and that is deliberate: this is a cache, the caller
    /// already has the route in hand, and a hiker looking at a list of trails
    /// has nothing to do about a full disk. The next search asks Overpass
    /// again, which is what would have happened anyway.
    func save(_ trail: CuratedTrail) {
        save([trail])
    }

    /// Writes a whole geometry pass down, and trims **once**.
    ///
    /// The plural is the one that matters, because the caller is plural: a
    /// page is twenty-five routes, and a per-route trim would enumerate a
    /// directory of two hundred files twenty-five times for one search — on
    /// the actor a hiker is waiting on. The trim only has to be right about
    /// the ceiling after the batch, not during it.
    func save(_ trails: [CuratedTrail]) {
        guard !trails.isEmpty,
              (try? FileManager.default.createDirectory(
                  at: directory,
                  withIntermediateDirectories: true
              )) != nil
        else { return }
        let now = clock()
        for trail in trails {
            let stored = StoredTrail(fetchedAt: now, trail: trail)
            guard let data = try? JSONEncoder().encode(stored) else { continue }
            let url = fileURL(for: trail.relationID)
            try? data.write(to: url, options: .atomic)
            // Stamped from the same clock a read stamps with, so the eviction
            // order below is one clock's opinion rather than a mixture of this
            // one's and the file system's.
            touch(url)
        }
        trim()
    }
}

// MARK: - What is already here, near there

nonisolated extension CuratedTrailStore {
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
    /// Every file is read, because nothing here indexes them. That is the cost
    /// this cache deliberately does not pay up front — see the file header —
    /// and it is paid on the one path where the alternative is a round trip
    /// that is not going to be answered.
    func trails(near area: CommunitySearchArea, limit: Int) -> [CuratedTrail] {
        guard limit > 0,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              )
        else { return [] }

        let centre = area.coordinate
        let within = files.compactMap { url -> (url: URL, trail: CuratedTrail, distance: Double)? in
            guard let data = try? Data(contentsOf: url),
                  let stored = try? JSONDecoder().decode(StoredTrail.self, from: data),
                  clock().timeIntervalSince(stored.fetchedAt) <= Self.lifetime
            else { return nil }
            // By the pin, which is the box's centre — the same point the row's
            // distance and the map's annotation use, so a trail the list
            // offers is a trail the map can show. See
            // ``CuratedTrailQuery/centre(of:)``.
            let distance = RouteGeometry.distanceMeters(
                from: centre,
                to: stored.trail.coordinate
            )
            guard distance <= area.radiusMeters else { return nil }
            return (url: url, trail: stored.trail, distance: distance)
        }
        // `min(count:)` rather than a full sort and a `prefix`, which is the
        // same question ``trim()`` asks four lines down and is worth asking
        // the same way: two hundred files are read to keep twenty-five.
        let nearest = within.min(count: limit) { $0.distance < $1.distance }
        // Re-stamped, for the reason ``trail(of:)`` re-stamps a hit. These are
        // the rows the hiker is looking at, and without this they keep
        // whatever age they had — so the fall-back a refused search draws is
        // made of exactly the files the next ``trim()`` is most likely to
        // take. The ones that were read and not offered are left alone: a file
        // this opened and rejected for being in another valley is not a route
        // anybody used.
        for entry in nearest { touch(entry.url) }
        return nearest.map(\.trail)
    }
}

// MARK: - Keeping the directory bounded

nonisolated private extension CuratedTrailStore {
    func fileURL(for relationID: Int64) -> URL {
        directory.appendingPathComponent("relation-\(relationID).json")
    }

    /// Moves `url` to the newest end of the eviction order.
    func touch(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: clock()],
            ofItemAtPath: url.path
        )
    }

    /// Drops the least recently used files once there are more than
    /// ``maximumFiles``.
    ///
    /// The same shape ``OverpassTrailGraphProvider/trimCache()`` uses, against
    /// the same `.contentModificationDateKey` — and here that key means *last
    /// read or written*, because ``trail(of:)`` re-stamps a hit.
    func trim() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ), files.count > Self.maximumFiles else { return }
        let dated = files.map { url in
            let date = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            return (url: url, date: date)
        }
        let doomed = dated.min(count: files.count - Self.maximumFiles) { $0.date < $1.date }
        for (url, _) in doomed {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
