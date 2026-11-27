//
//  OfflineCountryOffer+Title.swift
//  OpenHikes
//
//  The words of an offer on a downloaded area's row: what a tap adds or
//  deletes, by the switches' own names, and its size. Each is a whole
//  sentence in the catalog, one for *Extra Detail*, one for *Elevation
//  Data* and one for both, because a sentence put together from the two
//  names is one no translation could order or decline. Here rather than in
//  the row, which is body code no hosted suite runs
//  (`OfflineCountryOfferTitleTests`).
//

import Foundation

extension OfflineCountryOffer {
    /// The offer to bring its files down, and what they take.
    var additionTitle: String {
        let size = OfflineCountryRow.bytes(byteCount)
        return if extras == [.detail, .elevation] {
            String(localized: "Add Extra Detail and Elevation Data · \(size)")
        } else if extras == .elevation {
            String(localized: "Add Elevation Data · \(size)")
        } else {
            String(localized: "Add Extra Detail · \(size)")
        }
    }

    /// The offer to delete its files, and what that frees.
    var removalTitle: String {
        let size = OfflineCountryRow.bytes(byteCount)
        return if extras == [.detail, .elevation] {
            String(localized: "Remove Extra Detail and Elevation Data · \(size)")
        } else if extras == .elevation {
            String(localized: "Remove Elevation Data · \(size)")
        } else {
            String(localized: "Remove Extra Detail · \(size)")
        }
    }
}
