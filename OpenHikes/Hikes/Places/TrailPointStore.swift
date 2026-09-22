//
//  TrailPointStore.swift
//  OpenHikes
//
//  The places this device has already been told about, kept on disk.
//
//  ``TrailPointSource`` used to keep nothing, and the argument in its header
//  was that caching a page of things nobody took would be keeping a list of
//  everything a hiker has ever looked past. That overstates it, and
//  ``CuratedTrailStore`` is the proof: it already keeps every waymarked route
//  near everywhere the hiker has browsed, in this same `Caches` directory. A
//  spring is no more sensitive than a trail.
//
//  ## What it is worth is a refused search drawing something
//
//  Three of five first attempts came back `504` the day this feature was
//  measured. Without a store, a refusal in a valley leaves a caption and an
//  empty map — even if the same valley answered an hour ago, on the same
//  device, to the same hiker. That is the whole case for this file, and it is
//  why the read below is reached from exactly one place: the failure branch of
//  a search, beside the caption that has already said the search was refused.
//
//  **It makes no claim to be the area's places, and it must keep saying so.**
//  Nothing here records which areas have been searched, so a read cannot tell
//  whether it is answering with everything mapped around there or with the few
//  hundred elements one search happened to bring back last week. That is
//  exactly ``CuratedTrailStore/trails(near:limit:)``'s bargain and it is kept
//  the same way: used only where the alternative is nothing.
//
//  ## One file per element, and deliberately not one per search box
//
//  A file per *box* would save round trips — a later search inside a stored one
//  would cost no request at all — and it is the coverage index this repository
//  has already declined once. The reason still holds: a box that merely
//  overlaps the one being asked about answers partially while looking
//  complete, and there is no way for the screen to tell the difference. The
//  per-element store saves no round trips and claims nothing, which is the
//  trade to take.
//
//  ## The cap is picked against the fetch, not copied from the curated one
//
//  ``CuratedTrailStore`` keeps 200 files against a page of 25 relations, which
//  is eight pages. The unit here is an order of magnitude smaller and far more
//  numerous: one search at ``TrailPointQuery/maximumRadiusMeters`` fetches
//  some 578 elements in the densest Alpine mapping there is, of which forty are
//  ever drawn. So ``maximumFiles`` is 1,200 — two of those searches — for two
//  reasons that agree. What this is for is *the valley that answered an hour
//  ago*, which is one or two valleys and not eight; and the read is the
//  expensive half, because nothing indexes these and a refusal pays for every
//  file in the directory.
//
//  What is stored is what Overpass *answered*, not what the app chose to draw.
//  The forty that were offered were chosen against the line as it stood at the
//  time, and a hiker who has drawn somewhere else since would get a fall-back
//  ranked for a trail they no longer have.
//

import Algorithms
import CoreLocation
import Foundation

nonisolated extension TrailPlaceOSM {
    /// A file name that cannot leave the directory it is written in, so the
    /// same spring is the same file across searches.
    ///
    /// Readable rather than hashed, because a directory somebody can inspect
    /// is worth having when the thing being debugged is *why is this spring
    /// here* — and sanitised rather than trusted, because the type comes off
    /// the wire and a value carrying a `/` or a `..` would be a path this app
    /// writes wherever it was told to. The id is an `Int64` and is safe by
    /// construction.
    var fileNameStem: String {
        let kind = elementType.lowercased().filter { $0.isASCII && $0.isLetter }
        return "\(kind.isEmpty ? "element" : kind)-\(elementID)"
    }
}

/// The on-disk half of what a place search found.
///
/// A value rather than an actor, for the reason ``CuratedTrailStore`` is one:
/// every caller is already off the main actor when it gets here, and an actor
/// would add a hop to each read for nothing. Nothing here touches the main
/// actor — see the repository instructions on disk work.
nonisolated struct TrailPointStore: Sendable {
    /// How long a stored place is trusted, in seconds.
    ///
    /// The thirty days ``CuratedTrailStore`` and ``OverpassTrailGraphProvider``
    /// both give OpenStreetMap geometry, for the same reason: a spring moves
    /// when somebody maps it differently, not when the hiker walks past it. A
    /// day would throw away the point of having this at all; forever would
    /// keep offering a hut that has been demolished.
    static let lifetime: TimeInterval = 30 * 24 * 60 * 60

    /// How many places are kept. See this file's header for the arithmetic.
    static let maximumFiles = 1200

    /// Where the files live for an ordinary launch.
    ///
    /// `Caches`, not `Application Support`: every byte here is re-fetchable
    /// and none of it is the hiker's. The system deleting the lot under
    /// pressure costs a round trip, which is exactly the trade this directory
    /// exists to express.
    static func defaultDirectory() -> URL? {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("TrailPoints", isDirectory: true)
    }

    /// One element, and when it was fetched.
    private struct StoredPlace: Codable {
        let fetchedAt: Date
        let place: TrailPlace
    }

    private let directory: URL
    private let clock: @Sendable () -> Date

    init(directory: URL, clock: @escaping @Sendable () -> Date) {
        self.directory = directory
        self.clock = clock
    }
}

// MARK: - Writing a search down

nonisolated extension TrailPointStore {
    /// Writes a whole search down, and trims **once**.
    ///
    /// The plural is the one that matters, because the caller is plural: a
    /// search is some hundreds of elements, and a per-element trim would
    /// enumerate a directory of twelve hundred files hundreds of times for one
    /// tap. The trim only has to be right about the ceiling after the batch,
    /// not during it.
    ///
    /// Failure is silent and that is deliberate: this is a cache, the caller
    /// already has the answer in hand, and a hiker drawing a trail has nothing
    /// to do about a full disk. The next search asks Overpass again, which is
    /// what would have happened anyway.
    /// Places with no ``TrailPlace/osm`` have nowhere to be filed and are skipped.
    func save(_ found: [TrailPlace]) {
        guard !found.isEmpty,
              (try? FileManager.default.createDirectory(
                  at: directory,
                  withIntermediateDirectories: true
              )) != nil
        else { return }
        let now = clock()
        for place in found {
            guard let osm = place.osm else { continue }
            let stored = StoredPlace(fetchedAt: now, place: place)
            guard let data = try? JSONEncoder().encode(stored) else { continue }
            let url = fileURL(for: osm)
            try? data.write(to: url, options: .atomic)
            // Stamped from the same clock a read stamps with, so the eviction
            // order is one clock's opinion rather than a mixture of this one's
            // and the file system's.
            touch(url)
        }
        trim()
    }
}

// MARK: - What is already here, near there

nonisolated extension TrailPointStore {
    /// Stored places standing within `area`, nearest its centre first.
    ///
    /// **This is what a refused search draws, and it does not claim to be the
    /// answer** — see this file's header. Nearest the *centre* rather than
    /// nearest the line, because a file on disk can be sorted by nothing else;
    /// which of these are worth a pin is decided against the drawing
    /// afterwards, by ``TrailPointRanking``, which is why the caller asks for
    /// more of them than it will draw.
    ///
    /// Every file is read, because nothing here indexes them. That is the cost
    /// this cache deliberately does not pay up front, and it is paid on the one
    /// path where the alternative is a round trip that is not going to be
    /// answered.
    func places(near area: CommunitySearchArea, limit: Int) -> [TrailPlace] {
        guard limit > 0,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              )
        else { return [] }

        let centre = area.coordinate
        // One reading of the clock for the whole pass rather than one per
        // file: twelve hundred of them answer the same question, and a pass
        // that straddled a tick would age two files differently for no reason
        // anybody could see.
        let now = clock()
        let within = files.compactMap { url -> (url: URL, place: TrailPlace, distance: Double)? in
            guard let data = try? Data(contentsOf: url),
                  let stored = try? JSONDecoder().decode(StoredPlace.self, from: data),
                  now.timeIntervalSince(stored.fetchedAt) <= Self.lifetime
            else { return nil }
            let distance = RouteGeometry.distanceMeters(
                from: centre,
                to: stored.place.clCoordinate
            )
            guard distance <= area.radiusMeters else { return nil }
            return (url: url, place: stored.place, distance: distance)
        }
        // `min(count:)` rather than a full sort and a `prefix`, which is the
        // same question ``trim()`` asks below and is worth asking the same
        // way: twelve hundred files are read to keep a couple of hundred.
        let nearest = within.min(count: limit) { $0.distance < $1.distance }
        // Re-stamped, for the reason ``CuratedTrailStore`` re-stamps a hit:
        // without it the places a hiker keeps coming back to are the oldest
        // files in the directory and the first trim takes exactly those. The
        // ones that were read and rejected for being in another valley are
        // left alone — a file this opened and did not offer is not a place
        // anybody used.
        for entry in nearest { touch(entry.url) }
        return nearest.map(\.place)
    }
}

// MARK: - Keeping the directory bounded

nonisolated private extension TrailPointStore {
    func fileURL(for element: TrailPlaceOSM) -> URL {
        directory.appendingPathComponent("\(element.fileNameStem).json")
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
    /// The same shape ``CuratedTrailStore/trim()`` uses, against the same
    /// `.contentModificationDateKey` — and here that key means *last written
    /// or last offered*, because ``places(near:limit:)`` re-stamps what it
    /// hands back.
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
