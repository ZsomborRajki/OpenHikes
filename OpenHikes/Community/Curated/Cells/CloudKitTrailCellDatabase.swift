//
//  CloudKitTrailCellDatabase.swift
//  OpenHikes
//
//  The pre-built squares, fetched from the public database.
//
//  A fetch of record IDs and never a query, like every read of a submission:
//  ``CommunitySchema/trailCellType`` carries no index, and needs none, because
//  a square's name is its place on the map. Public reads need no account, so
//  this works on a phone that is signed out of iCloud, which is the phone the
//  community list is browsable on.
//
//  Nothing here is reachable from a suite. The request is built and sent in
//  ``fetch(cellsNamed:)`` and everything worth asserting — which answer is
//  *no such square*, which is *could not be read*, what the manifest's flag
//  means — is in ``answer(from:names:)``, which takes what CloudKit handed
//  back and touches no network. `CloudKitTrailCellDatabaseTests` drives that.
//

import CloudKit
import Foundation
import os

nonisolated struct CloudKitTrailCellDatabase: TrailCellFetching {
    private static let logger = Logger(subsystem: "OpenHikes", category: "TrailCells")

    /// How long the request may go quiet, and how long it may take in all,
    /// in seconds.
    ///
    /// Short, and set rather than left at CloudKit's own — a minute of
    /// silence, and a week for the whole — because of what waits behind a
    /// failure here: ``CuratedTrailSource`` asks Overpass instead, and a
    /// hiker should reach that in seconds rather than after a spinner has
    /// outlasted their patience.
    private static let requestTimeout: TimeInterval = 15
    private static let resourceTimeout: TimeInterval = 30

    let containerIdentifier: String

    init(containerIdentifier: String = CloudSyncCoordinator.containerIdentifier) {
        self.containerIdentifier = containerIdentifier
    }

    @concurrent
    func fetch(cellsNamed names: [String]) async throws -> TrailCellFetch {
        let ids = ([TrailCellGrid.manifestRecordName] + names).map { CKRecord.ID(recordName: $0) }
        let configuration = CKOperation.Configuration()
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.resourceTimeout
        // The hiker is waiting on this. It also keeps CloudKit from holding
        // the request for a network that is not there: at this priority it
        // fails instead, and the failure is what falls back.
        configuration.qualityOfService = .userInitiated

        // Built here rather than held, for the reason
        // ``CloudKitCommunityTransport`` builds its own: the first
        // `CKContainer(identifier:)` in a process blocks on CloudKit's daemon.
        let database = CKContainer(identifier: containerIdentifier).publicCloudDatabase
        let fetched = try await database.configuredWith(configuration: configuration) { database in
            // The two fields this reads and no others. Without it the
            // manifest's own asset — the list of every square, which only
            // the upload wants — would be downloaded by every search.
            try await database.records(
                for: ids,
                desiredKeys: [CommunitySchema.TrailCell.routes, CommunitySchema.TrailManifest.complete]
            )
        }
        var results: [String: Result<CKRecord, any Error>] = [:]
        for (id, result) in fetched {
            results[id.recordName] = result
        }
        return Self.answer(from: results, names: names)
    }
}

nonisolated extension CloudKitTrailCellDatabase {
    /// The value ``CommunitySchema/TrailManifest/complete`` holds when the
    /// squares are the whole world.
    private static let completeFlag = 1

    /// What CloudKit's per-record results amount to, keyed by record name.
    ///
    /// The distinction that matters is drawn here: `unknownItem` is the
    /// server saying there is no such record, and is the only failure read
    /// as *absent*. Everything else — a timeout on one asset, a throttle, a
    /// record with no file where its routes should be — is *failed*, because
    /// reading any of those as absent would let a bad afternoon on the
    /// network tell a hiker there are no trails where they are standing.
    static func answer(
        from results: [String: Result<CKRecord, any Error>],
        names: [String]
    ) -> TrailCellFetch {
        let manifest: TrailCellFetch.Manifest
        switch results[TrailCellGrid.manifestRecordName] {
        case .success(let record):
            let flag = record[CommunitySchema.TrailManifest.complete] as? Int
            manifest = flag == completeFlag ? .complete : .partial

        case .failure(let error) where isUnknownItem(error):
            manifest = .absent

        case .failure, nil:
            manifest = .unread
        }

        var cells: [String: TrailCellFetch.Cell] = [:]
        for name in names {
            switch results[name] {
            case .success(let record):
                cells[name] = routes(of: record).map(TrailCellFetch.Cell.found) ?? .failed

            case .failure(let error) where isUnknownItem(error):
                cells[name] = .absent

            case .failure(let error):
                logger.error(
                    """
                    Could not read square \(name, privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
                cells[name] = .failed

            case nil:
                cells[name] = .failed
            }
        }
        return TrailCellFetch(manifest: manifest, cells: cells)
    }

    /// The bytes of a square's asset, read while its record is still in hand:
    /// the file is CloudKit's own, in a cache it clears when it likes.
    private static func routes(of record: CKRecord) -> Data? {
        guard let asset = record[CommunitySchema.TrailCell.routes] as? CKAsset,
              let url = asset.fileURL
        else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func isUnknownItem(_ error: any Error) -> Bool {
        (error as? CKError)?.code == .unknownItem
    }
}
