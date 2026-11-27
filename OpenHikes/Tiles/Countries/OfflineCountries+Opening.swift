//
//  OfflineCountries+Opening.swift
//  OpenHikes
//
//  The opening of the downloaded areas' archives, off the main actor, for
//  the map and the searches to read: what ``OfflineCountries`` hands to
//  ``OfflineCountryArchives`` at every launch and after every change to what
//  is installed. Each area opens the files its record says are on the
//  device, the heights among them where *Elevation Data* brought them.
//

import Foundation
import os

extension OfflineCountries {
    /// What an opening of the archives made of the index: the areas the map
    /// draws, and the files that would not open.
    nonisolated struct Opening: Sendable {
        var countries: [OfflineCountryArchives.Country] = []
        var unopenable: [String: Set<OfflineCountryManifest.Role>] = [:]
    }

    /// Opens every file the index names. An area whose basemap will not open
    /// is on no map, and one whose other files will not open is drawn
    /// without them.
    @concurrent
    static func open(_ records: [Record], in store: OfflineCountryStore) async -> Opening {
        var opening = Opening()
        for record in records {
            let id = record.country.id
            var failed = Set<OfflineCountryManifest.Role>()
            var opened: [OfflineCountryManifest.Role: PMTilesArchive] = [:]
            for file in record.files {
                do {
                    opened[file.role] = try PMTilesArchive(contentsOf: store.fileURL(for: file))
                } catch {
                    let reason = String(describing: error)
                    logger.error("Opening \(file.fileName, privacy: .public): \(reason, privacy: .public)")
                    failed.insert(file.role)
                }
            }
            if !failed.isEmpty { opening.unopenable[id] = failed }
            guard let basemap = opened[.basemap] else { continue }
            opening.countries.append(OfflineCountryArchives.Country(
                id: id,
                bounds: record.country.bounds,
                basemap: basemap,
                extras: opened[.extras],
                record: record,
                detail: opened[.detail],
                detailExtras: opened[.detailExtras],
                trails: opened[.trails],
                elevation: opened[.elevation]
            ))
        }
        return opening
    }
}
