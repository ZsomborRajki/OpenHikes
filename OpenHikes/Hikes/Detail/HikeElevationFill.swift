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
//  ## Interpolated onto every point, unlike the maker's save
//
//  The readings are two hundred along the line, and they are written onto
//  every point between them, by distance — ``RouteHeightSamples/interpolating(_:)``.
//  Two hundred heights on a line of thousands of points would draw the chart
//  but not the *Elevation* colours: ``RouteSteepness`` stops at a point with
//  no height. The climb comes out the same either way, because a straight run
//  between two readings adds nothing to it.
//
//  ## Only a hike with no heights at all
//
//  A recording whose barometer dropped out for a while has heights, and a gap
//  in them is a gap in what was measured. Patching it from a different source
//  would splice two disagreeing references into one profile, so a hike with
//  any height on it is left as it is.
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

    /// Whether `hike` is one the subscription would give heights to — see
    /// the file header. A walk still being recorded has no line yet.
    static func canFill(_ hike: Hike) -> Bool {
        !hike.isRecording && needsHeights(hike.route)
    }

    /// Reads heights for `hike`'s line from `source` and saves them onto it.
    ///
    /// - Returns: whether the hike now has them. False for a hike that did
    ///   not need them, a source that could not answer, a line that changed
    ///   while the question was out, and a save that was refused — which puts
    ///   the line back as it was.
    @discardableResult static func fill(
        _ hike: Hike,
        from source: any CuratedElevationSourcing,
        in context: ModelContext,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) async -> Bool {
        guard canFill(hike) else { return false }
        guard let samples = await source.samples(of: hike.route), !Task.isCancelled else { return false }
        // Read again after the await: an edit, or another device's sync, may
        // have replaced the line, or given it heights, in the meantime.
        let route = hike.route
        guard canFill(hike), samples.describes(route) else { return false }
        hike.route = samples.interpolating(route)
        do {
            try save(context)
        } catch {
            context.rollback()
            hike.route = route
            logger.error("Heights for a hike could not be saved: \(error.localizedDescription, privacy: .public)")
            return false
        }
        return true
    }
}
