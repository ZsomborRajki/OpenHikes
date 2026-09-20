//
//  HikeListOrder.swift
//  OpenHikes
//
//  What order the library is in, and what a drag does to it.
//
//  ## Two modes, and the list is only ever in one of them
//
//  A library is in one of ``HikeListSort``'s orders until the hiker drags a
//  row, and in *their* order from then on. There is no half-way state: the
//  first drag writes a position for every hike, because a list where some rows
//  have a place and others do not has no answer for where the others go.
//  ``isCustom(_:)`` is that question, and it is asked of the hikes themselves
//  rather than of a flag beside them — a flag can disagree with the rows it
//  describes, and this cannot.
//
//  Picking a sort is therefore also how a hand-made order is given up: the two
//  cannot both be in force, and a menu that quietly kept the drag would leave a
//  hiker choosing *Longest* and getting their own order back.
//
//  A hike added *after* that first drag has no position, and sorts to the top
//  rather than the bottom: it is the newest thing the hiker has, and the
//  alternative is a walk finishing into the far end of a long list. The next
//  drag gives it a number like everything else.
//
//  ## The recording is not ordered at all
//
//  A hike being recorded or walked right now is pinned above the list whatever
//  its position says, and cannot be dragged out of it — it is not a place in a
//  library, it is the thing happening. When it finishes it takes the position
//  it holds like any other row.
//
//  The pin is applied on every arrangement rather than written down, so it
//  cannot be left behind by a crash mid-walk, and a drop *above* the pinned
//  row is simply corrected the next time the list is arranged.
//

import Foundation
// For `move(fromOffsets:toOffset:)`, whose semantics are `ForEach`'s and whose
// indices are the ones a drag reports. Re-deriving that arithmetic here would
// be re-deriving the one thing the caller and this type have to agree about.
import SwiftUI

enum HikeListOrder {
    /// Whether the hiker has taken over the order.
    ///
    /// True as soon as any hike carries a position, which is what the first
    /// drag guarantees for all of them.
    static func isCustom(_ hikes: [Hike]) -> Bool {
        hikes.contains { $0.listOrder != nil }
    }

    /// The order to draw: the hike in progress first, then the rest.
    ///
    /// Stable by date within equal positions, so two hikes that somehow share
    /// a number — a store restored from a half-written state — do not swap
    /// places between redraws.
    static func arrange(
        _ hikes: [Hike],
        activeHikeID: UUID?,
        sort: HikeListSort = .newest
    ) -> [Hike] {
        let rest: [Hike]
        let active = activeHikeID.flatMap { id in hikes.first { $0.id == id } }
        let unpinned = active == nil ? hikes : hikes.filter { $0.id != activeHikeID }

        if isCustom(hikes) {
            rest = unpinned.sorted { first, second in
                // A hike with no position is newer than the ordering itself.
                // `Int.min` puts it above everything placed, where a walk that
                // has just finished belongs.
                let left = first.listOrder ?? Int.min
                let right = second.listOrder ?? Int.min
                if left != right { return left < right }
                return first.date > second.date
            }
        } else {
            // Measured once each and then sorted on the measurements — see
            // ``HikeListSort``'s header for what this costs when it is done
            // the other way round.
            let keyed = unpinned.map { (key: sort.key(for: $0), hike: $0) }
            rest = keyed.sorted { sort.precedes($0.key, $1.key) }.map(\.hike)
        }
        return active.map { [$0] + rest } ?? rest
    }

    /// The hikes whose elevation figures a sort needs and nothing has.
    ///
    /// Asked before an elevation order is drawn, so the cache is filled for
    /// what is missing and nothing else — see ``HikeListMetrics``. Empty for
    /// every other order, which is what keeps them free.
    static func hikesMissingElevation(in hikes: [Hike], for sort: HikeListSort) -> [UUID] {
        guard sort.needsElevation else { return [] }
        return hikes.filter { $0.climbMeters == nil || $0.descentMeters == nil }.map(\.id)
    }

    /// Applies a drag, and writes a position for every row while it is at it.
    ///
    /// Takes the arrangement that was on screen rather than re-deriving one:
    /// the indices in `offsets` and `destination` are `ForEach`'s, and they
    /// mean nothing against any other ordering of the same hikes.
    ///
    /// Returns the new arrangement so a caller can show it before the store
    /// has been read back — the positions live in a second, unmirrored store
    /// that no `@Query` observes, so nothing here would otherwise tell a list
    /// to redraw.
    @discardableResult static func move(
        _ displayed: [Hike],
        from offsets: IndexSet,
        to destination: Int
    ) -> [Hike] {
        var moved = displayed
        moved.move(fromOffsets: offsets, toOffset: destination)
        renumber(moved)
        return moved
    }

    /// Gives the list back to whichever sort is chosen.
    static func reset(_ hikes: [Hike]) {
        for hike in hikes where hike.listOrder != nil {
            hike.listOrder = nil
        }
    }

    /// Writes 0, 1, 2… down the list.
    ///
    /// Every row, including the ones that did not move: the gaps left by
    /// numbering only what was dragged are what make a second drag ambiguous.
    private static func renumber(_ hikes: [Hike]) {
        for (index, hike) in hikes.enumerated() where hike.listOrder != index {
            hike.listOrder = index
        }
    }
}
