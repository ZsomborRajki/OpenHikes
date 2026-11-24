//
//  OfflineCountries+Retry.swift
//  OpenHikes
//
//  Trying a failed download again, starting one from an area a screen kept,
//  and the room a download has to leave for the others.
//
//  The tile server deletes a build's files once it has moved past it
//  (`Scripts/offline-countries.sh prune`), so a download left waiting across
//  a refresh fails for good: its files answer 404, and asked for again they
//  answer 404 again, at every launch, because the list of downloads under
//  way brings the row back. Trying again therefore goes by what the server
//  offers now, read at the tap: *Offline Maps* reads the list as it opens,
//  and can stay open across a move. For the same reason a download asked
//  for by a screen that kept an area from an earlier list, as the hike
//  screen's *Offline* tile does, goes by the area listed under its code at
//  the tap (#1532).
//

import Foundation

extension OfflineCountries {
    /// Tries the failed download of the area `id` again: from where it
    /// stopped while the server still offers that build, and the build it
    /// offers now, from nothing, where it has a newer one. The list is read
    /// first, or the read already out waited for; where it cannot be read,
    /// the one read last is gone by.
    func retry(_ id: String) async {
        guard downloads[id]?.hasFailed == true else { return }
        await refreshList()
        // A second tap waited for the same read, and finds this one started.
        guard let failed = downloads[id], failed.hasFailed else { return }
        guard let current = offered.first(where: { $0.id == id }), current.build > failed.country.build else {
            download(failed.country)
            return
        }
        // What came down of the old build is no part of the new one, and
        // the new one waits for it to go: kept, it would resume from it.
        guard cancel(id) else { return }
        download(current)
    }

    /// Downloads the area `id` as the list has it now, where the map does not
    /// draw it already: a dialog asked for it before the list last changed,
    /// and the build it was shown may be one the server has deleted. Of an
    /// area on the device whose basemap would not open, the same build
    /// brings only what would not open.
    func downloadListed(_ id: String) {
        guard !isDrawn(id), let country = listedCountry(id) else { return }
        download(country)
    }

    /// What the areas coming down, other than `id`, have yet to bring: room
    /// one more download has to leave them. One that has failed still owes
    /// what the transfers out for it are bringing.
    func bytesOwed(besides id: String) -> Int64 {
        downloads.reduce(0) { owed, entry in
            entry.key == id ? owed : owed + entry.value.owedBytes
        }
    }
}
