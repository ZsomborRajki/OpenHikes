//
//  SheetPresentation+OfflineCountries.swift
//  OpenHikes
//
//  *Offline Maps* over whatever the sheet shows, from *Map Modes*.
//

import Foundation

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
}
