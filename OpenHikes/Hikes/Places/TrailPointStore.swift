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

import CoreLocation
import Foundation
import OpenHikesData

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
/// every caller is already off the main actor when it gets here. How the
/// directory behaves — expiry, the re-stamp on use, the trim — is
/// ``OverpassFileStore``'s, and is the same for every OpenStreetMap cache this
/// app keeps.
nonisolated struct TrailPointStore: Sendable {
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

    /// One element, and when it was fetched — the file format.
    ///
    /// Internal rather than private, and only because the compiler needs it:
    /// a `private` type as the generic argument of ``files`` crashes Swift
    /// 6.4's IRGen ("Global is external, but doesn't have external or weak
    /// linkage") when the file is compiled in a batch with its neighbours.
    nonisolated struct StoredPlace: OverpassFileEntry {
        let fetchedAt: Date
        let place: TrailPlace

        var value: TrailPlace { place }

        init(fetchedAt: Date, value: TrailPlace) {
            self.fetchedAt = fetchedAt
            place = value
        }
    }

    private let files: OverpassFileStore<StoredPlace>

    init(directory: URL, clock: @escaping @Sendable () -> Date) {
        files = OverpassFileStore(directory: directory, maximumFiles: Self.maximumFiles, clock: clock)
    }
}

nonisolated extension TrailPointStore {
    /// Writes a whole search down, and trims once — a search is some hundreds
    /// of elements, and a trim per element would read a directory of twelve
    /// hundred files hundreds of times for one tap.
    ///
    /// Places with no ``TrailPlace/osm`` have nowhere to be filed and are skipped.
    func save(_ found: [TrailPlace]) {
        files.save(found.compactMap { place in
            place.osm.map { (name: $0.fileNameStem, value: place) }
        })
    }

    /// Stored places standing within `area`, nearest its centre first.
    ///
    /// **This is what a refused search draws, and it does not claim to be the
    /// answer** — see this file's header. Nearest the *centre* rather than
    /// nearest the line, because a file on disk can be sorted by nothing else;
    /// which of these are worth a pin is decided against the drawing
    /// afterwards, by ``TrailPointRanking``, which is why the caller asks for
    /// more of them than it will draw.
    func places(near area: CommunitySearchArea, limit: Int) -> [TrailPlace] {
        files.values(near: area, limit: limit, at: \.clCoordinate)
    }
}
