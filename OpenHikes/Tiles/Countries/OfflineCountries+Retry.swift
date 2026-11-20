//
//  OfflineCountries+Retry.swift
//  OpenHikes
//
//  Trying a failed download again, and the room a download has to leave for
//  the others.
//
//  The tile server deletes a build's files once it has moved past it
//  (`Scripts/offline-countries.sh prune`), so a download left waiting across
//  a refresh fails for good: its files answer 404, and asked for again they
//  answer 404 again, at every launch, because the list of downloads under
//  way brings the row back. Trying again therefore goes by what the server
//  offers now, read at the tap: *Offline Maps* reads the list as it opens,
//  and can stay open across a move.
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
        // What came down of the old build is no part of the new one.
        cancel(id)
        download(current)
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
