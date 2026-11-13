//
//  TrailCellStore.swift
//  OpenHikes
//
//  The pre-built squares this device has already fetched, kept on disk.
//
//  A square is asked for by every search whose map comes within ten
//  kilometres of it — see ``TrailCellGrid/reachMeters`` — so the squares
//  around wherever a hiker is looking are asked for again and again: on the
//  next pan, the next time the tab opens, the next morning. Kept here, the
//  second search of a valley sends nothing at all, and works with no signal.
//
//  It is an ``OverpassFileStore`` like every other OpenStreetMap cache this
//  app keeps, and trusts a square for the thirty days ``OverpassCache``
//  trusts anything OpenStreetMap said, for the reason given there: a route
//  moves when somebody maps it differently, not when a hiker walks it.
//
//  **A square that does not exist is kept too**, as a file holding no routes.
//  Like every square here it is only ever written when the manifest said the
//  squares are the whole world — see ``TrailCellFetch/Manifest`` — so it is a
//  fact about the place rather than about an upload that had not got there
//  yet, and without it a search beside a lake would send a request every
//  time, to be told the lake is still a lake.
//

import Foundation

/// The on-disk half of ``TrailCellLibrary``.
///
/// A value with no lock for the reason ``OverpassFileStore`` is one: a file is
/// replaced whole, one that vanishes is a miss, and a miss here costs a fetch.
nonisolated struct TrailCellStore: Sendable {
    /// How many squares are kept.
    ///
    /// A search of the map above the sheet reads four to nine and the widest
    /// search the app allows a few dozen, so this is several regions' worth.
    /// Measured over Hungary, the median square is 5 KB and the largest of
    /// 166 is 168 KB, a third more than that once it is a file here; in
    /// `Caches`, where the system takes the lot back when it wants the room.
    static let maximumFiles = 150

    /// Where the files live for an ordinary launch. `Caches`, for the reason
    /// ``CuratedTrailStore/defaultDirectory()`` gives.
    static func defaultDirectory() -> URL? {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("TrailCells", isDirectory: true)
    }

    /// One square's bytes, and when they were fetched — the file format.
    ///
    /// Internal rather than private for the reason
    /// ``CuratedTrailStore/StoredTrail`` is.
    nonisolated struct StoredCell: OverpassFileEntry {
        let fetchedAt: Date
        let bytes: Data

        var value: Data { bytes }

        init(fetchedAt: Date, value: Data) {
            self.fetchedAt = fetchedAt
            bytes = value
        }
    }

    private let files: OverpassFileStore<StoredCell>

    init(directory: URL, clock: @escaping @Sendable () -> Date) {
        files = OverpassFileStore(directory: directory, maximumFiles: Self.maximumFiles, clock: clock)
    }
}

nonisolated extension TrailCellStore {
    /// The bytes kept for the square named `name`, or `nil` for one that was
    /// never kept or has expired.
    func bytes(ofCellNamed name: String) -> Data? {
        files.value(named: name)
    }

    /// Keeps a search's worth of squares, and trims once.
    func save(_ cells: [(name: String, bytes: Data)]) {
        files.save(cells.map { (name: $0.name, value: $0.bytes) })
    }
}
