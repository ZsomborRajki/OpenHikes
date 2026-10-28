//
//  CommonsAuthorBudget.swift
//  OpenHikes
//
//  The per-photographer rule both Commons selectors apply before they spread
//  anything: ``CommonsTrailPhotos`` along a route, ``CommonsAreaPhotos`` over
//  a grid. Each sorts its candidates by its own idea of *better* and spreads
//  them its own way, but who counts as one photographer, and how many of
//  theirs compete first, is one rule — see
//  ``CommonsTrailPhotos/perAuthorLimit`` for why there is a limit at all.
//

import Foundation

nonisolated enum CommonsAuthorBudget {
    /// `ordered` split into the photographs that compete for a place first and
    /// the ones held back: each named photographer's first
    /// ``CommonsTrailPhotos/perAuthorLimit`` go first, the rest wait. A
    /// photograph `author` names nobody for is nobody's, and is never held
    /// back nor counted against anyone.
    ///
    /// Both halves keep `ordered`'s order, so a caller's *first* is whatever
    /// it sorted first.
    static func partition<Photo>(
        _ ordered: [Photo],
        author: (Photo) -> String?
    ) -> (preferred: [Photo], heldBack: [Photo]) {
        var taken: [String: Int] = [:]
        var preferred: [Photo] = []
        var heldBack: [Photo] = []
        for photo in ordered {
            guard let name = author(photo) else {
                preferred.append(photo)
                continue
            }
            let count = taken[name, default: 0]
            if count < CommonsTrailPhotos.perAuthorLimit {
                taken[name] = count + 1
                preferred.append(photo)
            } else {
                heldBack.append(photo)
            }
        }
        return (preferred, heldBack)
    }
}
