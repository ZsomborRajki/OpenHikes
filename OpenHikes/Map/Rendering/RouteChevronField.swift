//
//  RouteChevronField.swift
//  OpenHikes
//
//  Which of a route's direction chevrons are actually drawn where the route
//  runs over ground it has already covered.
//
//  An out-and-back walks the way home along the way out, so every place on
//  that stretch carries two chevrons pointing at each other. Drawn, they land
//  on top of one another — crosses where the phases coincide, blots where they
//  nearly do, and twice the arrows everywhere else — at every zoom level,
//  because the spacing is in screen points and so the pile-up never zooms
//  apart. The line underneath stops being readable, and under
//  ``RouteLinePattern/arrowheads`` there is no line underneath at all. The
//  second chevron says nothing the first did not: the ground is the same
//  ground, and the walk crossed it twice.
//
//  So a chevron is claimed here before it is drawn, against the ones already
//  placed in the same pass, and one landing on ground an earlier chevron
//  already covers is dropped. Two chevrons whose headings genuinely differ —
//  a route crossing itself rather than retracing itself — are both kept, and
//  asked only not to print on top of each other: a crossing is worth drawing.
//
//  Everything here is in map points at the pass's own zoom scale, which is
//  what makes the rule zoom-aware without a zoom level ever being named: two
//  legs a few metres apart are one stretch while those metres are half a
//  pixel, and two stretches once they are far enough apart to be told apart.
//

import Foundation

/// One chevron's centre and heading, in map points.
nonisolated struct RouteChevron: Equatable, Sendable {
    let x: Double
    let y: Double
    /// Unit vector along the direction of travel.
    let ux: Double
    let uy: Double
}

/// The chevrons already placed in one draw pass, bucketed on a grid so a
/// candidate is compared against its neighbours rather than against all of
/// them — a screenful at the closest spacing is a few hundred of them, and
/// every one of those would otherwise be tested against every other.
nonisolated struct RouteChevronField {
    private struct Cell: Hashable {
        let x: Int
        let y: Int
    }

    /// Side of one bucket, in map points. Set from the widest clearance the
    /// pass will ask about, which makes the search the nine cells around the
    /// candidate; a smaller cell still answers correctly, only over more of
    /// them.
    private let cell: Double
    private var buckets: [Cell: [RouteChevron]] = [:]

    init(cellSize: Double) {
        cell = cellSize.isFinite && cellSize > 0 ? cellSize : 1
    }

    /// Answers whether `chevron` is clear to draw, and records it when it is.
    ///
    /// `retrace` is the clearance demanded of a chevron running along the same
    /// ground as an earlier one, in either direction — the way home over the
    /// way out, or a second lap of a loop. `crossing` is the clearance demanded
    /// when the two headings genuinely differ, where both chevrons carry
    /// something worth reading and the only thing to avoid is overdraw.
    ///
    /// A dropped chevron is not recorded: it left no ink, so it has no claim on
    /// the ground it would have covered.
    mutating func claim(_ chevron: RouteChevron, retrace: Double, crossing: Double) -> Bool {
        let reach = searchReach(retrace: retrace, crossing: crossing)
        let home = cellIndex(x: chevron.x, y: chevron.y)
        for gx in (home.x - reach)...(home.x + reach) {
            for gy in (home.y - reach)...(home.y + reach) {
                guard let placed = buckets[Cell(x: gx, y: gy)] else { continue }
                let blocked = placed.contains { other in
                    conflicts(chevron, with: other, retrace: retrace, crossing: crossing)
                }
                if blocked { return false }
            }
        }
        buckets[home, default: []].append(chevron)
        return true
    }

    /// Whether the two are close enough to read as one mark, at the clearance
    /// their headings call for.
    private func conflicts(
        _ chevron: RouteChevron,
        with other: RouteChevron,
        retrace: Double,
        crossing: Double
    ) -> Bool {
        let dx = chevron.x - other.x, dy = chevron.y - other.y
        // Unsigned: a heading and its reverse both mean the same ground.
        let alignment = abs(chevron.ux * other.ux + chevron.uy * other.uy)
        let clearance = alignment >= RouteChevronMetrics.collinearAlignment ? retrace : crossing
        return dx * dx + dy * dy < clearance * clearance
    }

    /// How many cells out the search has to look. One, for the cell size the
    /// renderer passes; more if a caller buckets finer than it compares.
    private func searchReach(retrace: Double, crossing: Double) -> Int {
        let widest = max(retrace, crossing)
        guard widest.isFinite, widest > 0 else { return 0 }
        return max(1, Int((widest / cell).rounded(.up)))
    }

    private func cellIndex(x: Double, y: Double) -> Cell {
        Cell(x: Self.index(x / cell), y: Self.index(y / cell))
    }

    /// Clamped rather than converted outright: `Int(_:)` traps on a value past
    /// its range or on a non-finite one, and a trap in a draw pass is the map
    /// taking the app down. Two absurd coordinates sharing a bucket costs a
    /// distance comparison that answers correctly anyway.
    private static func index(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(max(-indexLimit, min(indexLimit, value.rounded(.down))))
    }

    /// Well inside `Int`'s range, and far outside the map's: the whole world
    /// is 2.7e8 map points across.
    private static let indexLimit: Double = 1e15
}
