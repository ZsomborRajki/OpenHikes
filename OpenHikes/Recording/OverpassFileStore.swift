//
//  OverpassFileStore.swift
//  OpenHikes
//
//  How a directory of things Overpass answered behaves on disk.
//
//  ``CuratedTrailStore`` and ``TrailPointStore`` were the same file twice: a
//  read that expires, a write that stamps and trims once, a re-stamp on use
//  that makes eviction least recently *used*, and the read of every file a
//  refused search falls back to. ``OverpassTrailGraphProvider``'s trim was a
//  third copy of the last of those, and the thirty days all three trust
//  OpenStreetMap for was spelled three times. What each cache keeps, and why,
//  is still in its own file's header; what is here is only the directory.
//

import Algorithms
import CoreLocation
import Foundation
import OpenHikesData

/// What every on-disk OpenStreetMap cache shares, whatever its files hold.
nonisolated enum OverpassCache {
    /// How long anything OpenStreetMap answered is trusted, in seconds.
    ///
    /// Thirty days for a walking graph, a waymarked route and a spring alike,
    /// because the reason is the same for each: OSM's geometry moves when
    /// somebody maps it differently, not when the hiker walks. A day would
    /// throw away the point of keeping it at all; forever would draw a trail
    /// that has been re-routed along a path that is no longer there, and keep
    /// offering a hut that has been demolished.
    static let lifetime: TimeInterval = 30 * 24 * 60 * 60

    /// Drops the oldest files in `directory` once there are more than
    /// `maximumFiles`, by `.contentModificationDateKey`.
    ///
    /// Oldest by whatever the cache makes that date mean: *last written* for
    /// the graph tiles, and *last used* for an ``OverpassFileStore``, which
    /// re-stamps what it hands back. `min(count:)` rather than a full sort,
    /// because only the handful over the ceiling need finding.
    static func trim(_ directory: URL, keeping maximumFiles: Int) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ), files.count > maximumFiles else { return }
        let dated = files.map { url in
            let date = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            return (url: url, date: date)
        }
        let doomed = dated.min(count: files.count - maximumFiles) { $0.date < $1.date }
        for (url, _) in doomed {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// What one file of an ``OverpassFileStore`` holds: the value, and the moment
/// it was fetched.
///
/// Declared by each cache rather than once here, because it *is* the file
/// format — the name the value is filed under is each cache's own word, and
/// files an earlier build wrote have to keep reading after this one is
/// installed.
nonisolated protocol OverpassFileEntry: Codable, Sendable {
    associatedtype Value

    var fetchedAt: Date { get }
    var value: Value { get }

    init(fetchedAt: Date, value: Value)
}

/// One directory of JSON files, one per thing Overpass answered, trusted for
/// ``OverpassCache/lifetime`` and kept to `maximumFiles` by dropping the least
/// recently used.
///
/// A value rather than an actor, for the reason both caches built on it are
/// values: every caller is already off the main actor and inside an isolation
/// of its own, which is where the serialisation this needs comes from, and an
/// actor here would add a second hop to every read for nothing.
///
/// Failure is silent throughout, and that is deliberate: this is a cache, a
/// caller writing to it already has the answer in hand, and a hiker has
/// nothing to do about a full disk. The next search asks Overpass again,
/// which is what would have happened anyway.
nonisolated struct OverpassFileStore<Entry: OverpassFileEntry>: Sendable {
    private let directory: URL
    private let maximumFiles: Int
    private let clock: @Sendable () -> Date

    init(directory: URL, maximumFiles: Int, clock: @escaping @Sendable () -> Date) {
        self.directory = directory
        self.maximumFiles = maximumFiles
        self.clock = clock
    }
}

// MARK: - One file at a time

nonisolated extension OverpassFileStore {
    /// The value filed under `name`, or `nil` for one that was never stored,
    /// cannot be read, or has expired.
    ///
    /// A hit re-stamps the file's modification date, which is what makes the
    /// trim *least recently used* rather than least recently written. Without
    /// it, the routes a hiker keeps coming back to would be the oldest files
    /// in the directory, and the first trim would take exactly those.
    func value(named name: String) -> Entry.Value? {
        let url = fileURL(named: name)
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(Entry.self, from: data)
        else { return nil }
        guard clock().timeIntervalSince(stored.fetchedAt) <= OverpassCache.lifetime else {
            // Expired rather than corrupt, and removed because it will never
            // be read again: left, it costs a slot in the trim that a usable
            // file could have had.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        touch(url)
        return stored.value
    }

    /// Writes every entry down, replacing whatever was filed under its name,
    /// and trims **once**.
    ///
    /// The batch is the shape that matters, because the callers are batches: a
    /// page of routes or a search's worth of places. A trim per file would
    /// enumerate the whole directory once for every one of them, on the actor
    /// a hiker is waiting on. The trim only has to be right about the ceiling
    /// after the batch, not during it.
    func save(_ entries: [(name: String, value: Entry.Value)]) {
        guard !entries.isEmpty,
              (try? FileManager.default.createDirectory(
                  at: directory,
                  withIntermediateDirectories: true
              )) != nil
        else { return }
        let now = clock()
        for (name, value) in entries {
            guard let data = try? JSONEncoder().encode(Entry(fetchedAt: now, value: value)) else { continue }
            let url = fileURL(named: name)
            try? data.write(to: url, options: .atomic)
            // Stamped from the same clock a read stamps with, so the eviction
            // order is one clock's opinion rather than a mixture of this one's
            // and the file system's.
            touch(url)
        }
        OverpassCache.trim(directory, keeping: maximumFiles)
    }
}

// MARK: - What is already here, near there

nonisolated extension OverpassFileStore {
    /// Stored values standing within `area`, nearest its centre first.
    ///
    /// Every file is read, because nothing indexes them. That is the cost
    /// these caches deliberately do not pay up front — an index is the
    /// coherence problem each of their headers declines — and it is paid only
    /// where the alternative is a round trip that is not going to be answered.
    ///
    /// What is handed back is re-stamped, for the reason ``value(named:)``
    /// re-stamps a hit: these are what the hiker is looking at. The files that
    /// were read and rejected for standing in another valley are left alone —
    /// a file this opened and did not offer is not one anybody used.
    func values(
        near area: CommunitySearchArea,
        limit: Int,
        at coordinate: (Entry.Value) -> CLLocationCoordinate2D
    ) -> [Entry.Value] {
        guard limit > 0,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              )
        else { return [] }

        let centre = area.coordinate
        // One reading of the clock for the whole pass rather than one per
        // file: every file answers the same question, and a pass that
        // straddled a tick would age two of them differently for no reason
        // anybody could see.
        let now = clock()
        let within = files.compactMap { url -> (url: URL, value: Entry.Value, distance: Double)? in
            guard let data = try? Data(contentsOf: url),
                  let stored = try? JSONDecoder().decode(Entry.self, from: data),
                  now.timeIntervalSince(stored.fetchedAt) <= OverpassCache.lifetime
            else { return nil }
            let distance = RouteGeometry.distanceMeters(from: centre, to: coordinate(stored.value))
            guard distance <= area.radiusMeters else { return nil }
            return (url: url, value: stored.value, distance: distance)
        }
        // `min(count:)` rather than a full sort and a `prefix`: hundreds of
        // files are read to keep a few dozen.
        let nearest = within.min(count: limit) { $0.distance < $1.distance }
        for entry in nearest { touch(entry.url) }
        return nearest.map(\.value)
    }
}

// MARK: - Files

nonisolated private extension OverpassFileStore {
    func fileURL(named name: String) -> URL {
        directory.appendingPathComponent("\(name).json")
    }

    /// Moves `url` to the newest end of the eviction order.
    func touch(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: clock()],
            ofItemAtPath: url.path
        )
    }
}
