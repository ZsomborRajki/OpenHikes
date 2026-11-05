//
//  HikeElevationFill.swift
//  OpenHikes
//
//  Heights for a hike in the library that has none — a GPX exported without
//  `<ele>`, a trail drawn or a route saved from OpenStreetMap before its
//  hiker subscribed — read once from Stadia, for an OpenHikes Pro subscriber,
//  and written onto the hike so it never has to ask again.
//
//  The same question the trail maker and a curated route ask, through the
//  same source — ``StadiaElevationSource`` refuses anybody else before it
//  forms a request — so it costs one billed call per hike, ever. Asked when
//  the hike is opened rather than for the whole library at once: a library
//  imported in bulk is a bill for routes nobody may look at.
//
//  ## Interpolated onto every point
//
//  The readings are two hundred along the line, and they are written onto
//  every point between them, by distance — ``RouteHeightSamples/interpolating(_:)``,
//  as the maker's save and a curated route write theirs. Two hundred heights
//  on a line of thousands of points would draw the chart but not the
//  *Elevation* colours: ``RouteSteepness`` stops at a point with no height.
//  The climb comes out the same either way, because a straight run between
//  two readings adds nothing to it.
//
//  A recording with pauses, or a GPX of several `<trkseg>`s, is the one
//  caller whose line has paused legs, and none of them is filled across: the
//  cable car's kilometre of rise stays off the level ground either side of
//  it (#1032). Both ends of each pause are among the two hundred readings, so
//  the walked stretches keep heights of their own, as long as those ends are
//  no more than half of them. A file split into more segments than that is
//  read evenly along its line instead — see
//  ``CuratedElevationRequest/sampleIndexes(of:limit:)`` — and a stretch no
//  reading lands on is left without heights rather than given some from
//  across a pause.
//
//  ## Only a hike with no heights at all
//
//  A recording whose barometer dropped out for a while has heights, and a gap
//  in them is a gap in what was measured. Patching it from a different source
//  would splice two disagreeing references into one profile, so a hike with
//  any height on it is left as it is.
//
//  ## Off the main actor, up to the write
//
//  The line it starts from is the one the hike's screen read (``ShownLine``),
//  and the line it checks its answer against is read in a context of its own
//  once the answer is back, by a ``SelectedLine`` it makes for that: a read on
//  the main actor decoded all of it, twice if a save fell between. The
//  heights are worked out there too. Only the write is left on the main
//  actor, because the hike's own context is what writes it.
//

import Foundation
import OpenHikesData
import os
import SwiftData

enum HikeElevationFill {
    private static let logger = Logger(subsystem: "OpenHikes", category: "Elevation")

    /// Whether `route` is a line with no usable height anywhere on it.
    nonisolated static func needsHeights(_ route: [RouteCoordinate]) -> Bool {
        route.count > 1 && !route.contains { $0.elevation?.isFinite == true }
    }

    /// Whether `hike` is one the subscription would give heights to, along
    /// `route`, the line it has now as its screen read it off the main actor
    /// — see the file header. A walk still being recorded has no line yet.
    static func canFill(_ hike: Hike, along route: [RouteCoordinate]) -> Bool {
        !hike.isRecording && needsHeights(route)
    }

    /// Reads heights for `route`, `hike`'s line as its screen read it, from
    /// `source` and saves them onto the hike.
    ///
    /// - Returns: whether the hike now has them. False for a hike that did
    ///   not need them, a source that could not answer, a line that changed
    ///   while the question was out, and a save that was refused — which puts
    ///   the line back as it was.
    @discardableResult static func fill(
        _ hike: Hike,
        along route: [RouteCoordinate],
        from source: any CuratedElevationSourcing,
        in context: ModelContext,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) async -> Bool {
        guard canFill(hike, along: route) else { return false }
        guard let samples = await source.samples(of: route), !Task.isCancelled, hike.isAttached else { return false }
        // Read again after the await: an edit, or another device's sync, may
        // have replaced the line, or given it heights, in the meantime. And a
        // write while this read is out replaces it.
        let read = SelectedLine().read(of: hike)
        guard let filled = await heights(on: read, from: samples), hike.isAttached, !hike.isRecording,
              !read.isReplaced else { return false }
        hike.replaceRoute(with: filled.route)
        do {
            try save(context)
        } catch {
            // Restore only our change. This is the shared UI context, whose
            // other pending edits may have arrived while the source was
            // suspended; rolling it back would discard those too.
            hike.replaceRoute(with: filled.previous)
            logger.error("Heights for a hike could not be saved: \(error.localizedDescription, privacy: .public)")
            return false
        }
        return true
    }

    /// The line `read` holds, and that line with `samples`' heights on it, or
    /// `nil` for a line that has heights by now or that they do not describe.
    ///
    /// `@concurrent`, because a `nonisolated async` function runs on its
    /// caller's executor, and each of these walks the whole line.
    @concurrent
    nonisolated private static func heights(
        on read: SelectedLine.Read,
        from samples: RouteHeightSamples
    ) async -> (previous: [RouteCoordinate], route: [RouteCoordinate])? {
        let route = await read.route
        guard needsHeights(route), samples.describes(route) else { return nil }
        return (route, samples.interpolating(route))
    }
}
