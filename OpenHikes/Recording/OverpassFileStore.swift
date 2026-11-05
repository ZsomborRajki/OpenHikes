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

    /// The extension every file of these caches is named with, and so what
    /// tells one of their files from anything else in the directory.
    ///
    /// Spelled once because the naming and the listing both rest on it: a
    /// cache that named its files any other way would never find them in a
    /// listing, and would see the trim delete each one an hour after writing
    /// it, as the leftover of a write.
    static let fileExtension = "json"

    /// How long after it was last written something in a directory that is
    /// not one of the cache's files is taken for the leftover of a write that
    /// never finished, and deleted.
    ///
    /// What sits beside a cache's files is the staged half of an `.atomic`
    /// write — see ``OverpassFileStore``. A write here is a few megabytes at
    /// most and done in well under a second, so an hour is far past any that
    /// is still under way. The one that can be is a write the system
    /// suspended halfway for that long, and losing its file then is a miss
    /// like any other: the next search asks again.
    static let stagedWriteLifetime: TimeInterval = 60 * 60

    /// Whether `url` is one of the cache's own files, rather than the staged
    /// half of a write beside one.
    static func isCacheFile(_ url: URL) -> Bool {
        url.pathExtension == fileExtension
    }

    /// Drops the oldest files in `directory` once there are more than
    /// `maximumFiles`, by `.contentModificationDateKey`, and deletes the
    /// leftovers of writes that never finished.
    ///
    /// Oldest by whatever the cache makes that date mean: *last written* for
    /// the graph tiles, and *last used* for an ``OverpassFileStore``, which
    /// re-stamps what it hands back. `min(count:)` rather than a full sort,
    /// because only the handful over the ceiling need finding.
    ///
    /// Only the cache's own files count toward the ceiling. A staged write
    /// counted there would push a stored answer out to make room for a file
    /// about to be renamed over another one, or for one a killed save left
    /// that nothing will ever read. Those leftovers go here instead, once
    /// they are ``stagedWriteLifetime`` old, so a directory that never
    /// reaches its ceiling does not keep them for ever. `now` is the caller's
    /// clock, which in a running app is the file system's too.
    static func trim(_ directory: URL, keeping maximumFiles: Int, at now: Date) {
        guard let listed = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        // `partitioned(by:)` answers (does not satisfy, satisfies).
        let (staged, files) = listed.partitioned(by: isCacheFile)
        let abandoned = now.addingTimeInterval(-stagedWriteLifetime)
        for url in staged {
            guard let written = modificationDate(of: url), written < abandoned else { continue }
            try? FileManager.default.removeItem(at: url)
        }
        guard files.count > maximumFiles else { return }
        let dated = files.map { url in
            (url: url, date: modificationDate(of: url) ?? .distantPast)
        }
        let doomed = dated.min(count: files.count - maximumFiles) { $0.date < $1.date }
        for (url, _) in doomed {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
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
/// A value rather than an actor, and with no lock, because these operations
/// tolerate running at the same time as one another, on the same files — and
/// they do run that way. The caches built on it call it from wherever they
/// are, off the main actor: one from inside an actor and from a `@concurrent`
/// fall-back beside it, the others from `@concurrent` work with no isolation
/// of its own. An actor here would add a hop to every read and order nothing
/// that needs ordering. What holds without one:
///
/// - **A file is replaced whole.** ``save(_:)`` writes `.atomic`: Foundation
///   stages the bytes in a file beside the target and renames it into place,
///   so a reader opening the target gets the old file or the new one, never
///   part of either. Of two saves of the same name, one whole file is left.
/// - **A file that vanishes is a miss.** The trim and an expired read delete
///   by name. A read that comes after fails to open, which `try?` turns into
///   `nil` or a skipped file, and a re-stamp of a deleted file fails as
///   quietly. Because the delete is by name, an expired read racing a save of
///   the same name can take the fresh file with it.
/// - **Only the store's own files are read or counted.** The staged file is
///   not hidden, so `.skipsHiddenFiles` does not keep it out of a listing,
///   and whole but not yet renamed it decodes. Both listings keep only names
///   with ``OverpassCache/fileExtension``, which every file here is given and
///   no staged file is: ``values(near:limit:at:)`` never opens a staged file,
///   so a value being saved is not in its answer twice, and the trim never
///   counts one toward the ceiling. A save killed before the rename leaves
///   its staged file behind, and the trim deletes that once it is
///   ``OverpassCache/stagedWriteLifetime`` old, sparing a younger one that a
///   save may still rename into place.
///
/// So an overlap can cost a value left out of an answer, a fresh file
/// deleted, or a re-stamp that lands too late to keep a file from the trim —
/// a round trip later, at worst — and never a torn or mixed value, nor one
/// listed twice.
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
        OverpassCache.trim(directory, keeping: maximumFiles, at: now)
    }
}

// MARK: - What is already here, near there

nonisolated extension OverpassFileStore {
    /// Stored values standing within `area`, nearest its centre first.
    ///
    /// Within the rectangle the hiker could see when the area carries one —
    /// see ``CommunitySearchArea/contains(_:)`` — and within its radius when
    /// it does not.
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
              let listed = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              )
        else { return [] }
        // Only the store's own files, because a staged write decodes as well
        // as the file it is about to replace — see this type's header.
        let files = listed.filter(OverpassCache.isCacheFile)

        let center = area.coordinate
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
            let point = coordinate(stored.value)
            guard area.contains(point) else { return nil }
            let distance = RouteGeometry.distanceMeters(from: center, to: point)
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
        directory.appendingPathComponent("\(name).\(OverpassCache.fileExtension)")
    }

    /// Moves `url` to the newest end of the eviction order.
    func touch(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: clock()],
            ofItemAtPath: url.path
        )
    }
}
