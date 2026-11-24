//
//  OrderedHikePhotos.swift
//  OpenHikes
//
//  A hike's photographs in gallery order (``Hike/orderedPhotos``), sorted
//  again only when the hike's photographs have changed.
//
//  For a screen whose body runs for things that do not move the order. The
//  gallery's does on every page turned, every tap on Delete that only opens
//  its question, and every page that finds its file — measured on
//  `testBrowsesSeededPhotosAndDeletesOne`, ten passes for two photographs —
//  and each pass sorted the whole hike, with a `uuidString` per tie. What is
//  read on every pass now is the photographs, once, compared with the ones
//  the order was made from, which is also what keeps the body listening for
//  them: a photograph added, removed or re-dated by sync still re-runs it,
//  and that pass sorts.
//
//  Any change to a photograph is a new order, not only to its time: a
//  photograph is a value, and the order hands out copies, so one kept past
//  a change of caption or place would draw the old one.
//
//  A reference held in `@State`, and not `@Observable`: what it keeps is a
//  cache of the body's own reads, and nothing should re-run because it
//  changed.
//

import Foundation
import OpenHikesData

final class OrderedHikePhotos {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// The photographs the order was made from, as the hike holds them.
    private var source: [HikePhoto] = []
    private var ordered: [HikePhoto] = []
    private var positions: [UUID: Int] = [:]
    /// How many times the order has been worked out, for a suite to tell a
    /// sort from a read.
    private(set) var sorts = 0

    /// `hike`'s photographs in gallery order, sorted only if the hike's
    /// photographs have changed since the last call.
    func photos(of hike: Hike) -> [HikePhoto] {
        let current = hike.photos
        guard current != source else { return ordered }
        source = current
        ordered = current.inGalleryOrder()
        positions = Dictionary(zip(ordered.map(\.id), ordered.indices)) { first, _ in first }
        sorts += 1
        return ordered
    }

    /// Where the photograph `id` stands in the last order handed out, or
    /// `nil` for none or for one not in it.
    func index(of id: UUID?) -> Int? {
        id.flatMap { positions[$0] }
    }
}
