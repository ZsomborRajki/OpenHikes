//
//  SheetPresentation+OfflineCountries.swift
//  OpenHikes
//
//  *Offline Maps* over whatever the sheet shows, from *Map Modes*, and the
//  whole sheet for its search field.
//

import SwiftUI

extension SheetPresentation {
    /// Pushes *Offline Maps*, or comes back to it where it is already open
    /// further down, with the sheet at its middle so the map is in view.
    func showOfflineCountries() {
        guard path.last != .offlineCountries else { return }
        makeRoomForTheMap()
        // Built aside and assigned once — see ``path``.
        var next = path
        if let open = next.firstIndex(of: .offlineCountries) {
            next.removeSubrange((open + 1)...)
        } else {
            next.append(.offlineCountries)
        }
        path = next
    }

    /// Raises the sheet to its full height for the list's search field, as
    /// the sheet's own field does: at the middle the keyboard would cover
    /// what the search finds.
    func makeRoomToSearch() {
        guard detent != .large else { return }
        withAnimation { detent = .large }
    }
}
