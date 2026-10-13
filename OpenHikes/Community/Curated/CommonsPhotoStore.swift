//
//  CommonsPhotoStore.swift
//  OpenHikes
//
//  What Wikimedia Commons has said about the geotagged files this device has
//  already asked about, kept on disk. The pictures themselves are not kept.
//
//  A search asks Commons two things, and only the second one costs much: the
//  geosearch hands back page ids and camera positions, and `imageinfo` is
//  asked about up to fifty of them for the thumbnail, the licence, the author
//  and the date — see ``CommonsPhotoQuery``. The same valley searched twice
//  asked about the same fifty files twice, and a busy geosearch, which is
//  about one answer in ten, showed nothing at all for an area whose files
//  were answered a minute earlier.
//
//  ## What is kept
//
//  One JSON file per Commons page: where its camera stood and, when it is a
//  file this app may show, what ``CommonsFile`` says about it. A page this app
//  may *not* show is kept too, with no file. That answer is as stable as the
//  other one, since an aerial survey tile does not turn into a JPEG, and
//  without it every search would ask again about the same tiles and
//  diagrams.
//
//  How the directory behaves — thirty days, re-stamped on use, trimmed least
//  recently used — is ``OverpassFileStore``'s, the same as for every
//  OpenStreetMap answer this app keeps. Thirty days is about right for
//  Commons for the same reason it is for OpenStreetMap: a file page changes
//  when somebody edits it, not because time passed.
//
//  ## What is not kept, and why
//
//  **The thumbnails.** They are where the bytes are, about 65 KB each against
//  a few hundred bytes for a page here, and keeping them would make this a
//  photo library of other people's pictures inside the app. They are
//  downloaded again, from the URL kept here, every time one is shown. A file
//  deleted from Commons since then simply fails to arrive and is left out,
//  which is also how a stale entry here ends up costing nothing.
//
//  **Which areas were asked.** As with ``CuratedTrailStore``, there is no
//  index. The one question an index would answer — *which pages stand around
//  here* — is asked only when the geosearch could not be, and there the cost of
//  reading every file is paid instead of a round trip that did not arrive.
//  What comes back is then the pages this device happened to see, not
//  everything Commons has. That is the honest answer to an outage, and a
//  better one than no photographs.
//

import CoreLocation
import Foundation

/// What Commons said about one geotagged page.
nonisolated struct CommonsPage: Codable, Equatable, Sendable {
    var pageID: Int
    var latitude: Double
    var longitude: Double
    /// What the page is, or `nil` for a page this app may not show — see this
    /// file's header for why that answer is kept too.
    var file: CommonsFile?

    init(_ candidate: CommonsPhotoCandidate, file: CommonsFile?) {
        pageID = candidate.pageID
        latitude = candidate.latitude
        longitude = candidate.longitude
        self.file = file
    }

    var candidate: CommonsPhotoCandidate {
        CommonsPhotoCandidate(pageID: pageID, latitude: latitude, longitude: longitude)
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// The on-disk half of what Commons said about its files.
///
/// A value rather than an actor, for the reason ``CuratedTrailStore`` is one:
/// every caller is already inside ``WikimediaCommonsSource``'s work, off the
/// main actor.
nonisolated struct CommonsPhotoStore: Sendable {
    /// How many pages are kept.
    ///
    /// A search asks about fifty at most, so this is the last forty searches
    /// or so. Each file is a few hundred bytes, which makes the whole
    /// directory about a megabyte at its fullest.
    static let maximumFiles = 2000

    /// Where the files live for an ordinary launch.
    ///
    /// `Caches`, for the reason every OpenStreetMap cache beside it is there:
    /// everything here can be downloaded again, and none of it belongs to the
    /// hiker.
    static func defaultDirectory() -> URL? {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("CommonsPhotos", isDirectory: true)
    }

    /// One page, and when Commons was asked about it — the file format.
    ///
    /// Internal rather than private for the reason ``CuratedTrailStore``'s
    /// `StoredTrail` is: a `private` generic argument crashes Swift 6.4's IRGen.
    nonisolated struct StoredPage: OverpassFileEntry {
        let fetchedAt: Date
        let page: CommonsPage

        var value: CommonsPage { page }

        init(fetchedAt: Date, value: CommonsPage) {
            self.fetchedAt = fetchedAt
            page = value
        }
    }

    private let files: OverpassFileStore<StoredPage>

    init(directory: URL, clock: @escaping @Sendable () -> Date = { Date() }) {
        files = OverpassFileStore(directory: directory, maximumFiles: Self.maximumFiles, clock: clock)
    }
}

nonisolated extension CommonsPhotoStore {
    /// The stored answer for `pageID`, or `nil` for a page that was never
    /// asked about or whose answer has expired.
    func page(_ pageID: Int) -> CommonsPage? {
        files.value(named: Self.fileName(for: pageID))
    }

    /// Writes a whole `imageinfo` answer down, and trims once.
    func save(_ pages: [CommonsPage]) {
        files.save(pages.map { (name: Self.fileName(for: $0.pageID), value: $0) })
    }

    /// Stored pages whose camera stood within `area`, nearest its middle
    /// first: what a geosearch that could not be asked falls back to.
    func pages(near area: CommunitySearchArea, limit: Int) -> [CommonsPage] {
        files.values(near: area, limit: limit, at: \.coordinate)
    }

    private static func fileName(for pageID: Int) -> String {
        "page-\(pageID)"
    }
}
