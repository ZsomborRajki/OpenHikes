//
//  RouteShading.swift
//  OpenHikes
//
//  The selected hike's line, coloured stretch by stretch on the
//  ``RouteShade`` scale: by the SAC grade OpenStreetMap gives the way beneath
//  it, by how steep the ground is, or not at all — the three positions of the
//  *Color By* control in Route Style (``RouteColoring``).
//
//  Neither answer is stored. `Hike.difficultyMetersByGrade` keeps how many
//  metres each grade covers, which is what the Difficulty section needs and
//  all that it needs — *where* those metres are is a second measurement, and
//  keeping it would be a CloudKit column holding a copy of the route for
//  something the trail graph answers again in milliseconds once it is cached.
//  So grades are asked for every time the selection changes, from the same
//  graph and the same walk the section's figures came from (see
//  ``TrailBreakdownAnalyzer``), and a stretch drawn red on the map is the red
//  share of the bar beneath it. Steepness is cheaper still: the route carries
//  its own heights, and ``RouteSteepness`` reads them in one pass.
//
//  Held in a reference type the map observes directly, for the reason
//  ``WalkHighlight`` is: the answer is a handful of polylines for MapKit, and
//  no SwiftUI view has any business re-rendering for it.
//

import CoreLocation
import Foundation
import OpenHikesData

/// What the selected hike's line is coloured by. One setting for every hike
/// rather than a column on each, because it is a way of reading the map and
/// not something a hiker styles a route with.
nonisolated enum RouteColoring: String, CaseIterable, Sendable {
    /// OpenStreetMap's SAC grade for the way under each stretch.
    case difficulty = "difficulty"
    /// How steep each stretch is, from the route's own heights.
    case elevation = "elevation"
    /// The hike's own colour, everywhere — *None* on the control.
    case off = "off"
}

@Observable
final class RouteShading {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// One coloured stretch of the line, and the step of the scale it is
    /// drawn in. Built where it is measured, off the main actor.
    nonisolated struct Stretch: Sendable {
        let shade: RouteShade
        let coordinates: [CLLocationCoordinate2D]
    }

    /// Bumped on every change to what the map should draw. The coordinator
    /// observes this one `Int` and reads ``hikeID`` and ``stretches`` inside
    /// the same pass — the arrangement ``WalkHighlight/revision`` explains.
    private(set) var revision = 0
    /// Which hike ``stretches`` were measured along. The map draws them only
    /// over that hike's line, so an answer arriving after the selection moved
    /// on can never colour the next hike's route with the last one's shades.
    @ObservationIgnored private(set) var hikeID: UUID?
    /// The coloured stretches, in route order. Empty with ``coloring``
    /// `off`, before the answer lands, and for a route there is nothing to
    /// colour on — no grade in OSM, or no heights.
    @ObservationIgnored private(set) var stretches: [Stretch] = []

    /// The *Color By* control in Route Style. Observed, because that control
    /// reads it; the map never does — changing it replaces ``stretches``,
    /// which is all the map needs to know.
    private(set) var coloring: RouteColoring

    /// The measurement in flight, if any. Readable so a suite can wait on the
    /// effect rather than on a duration.
    @ObservationIgnored private(set) var measurement: Task<Void, Never>?

    @ObservationIgnored private let provider: (any TrailGraphProviding)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var followed: Hike?
    /// Identifies the current measurement, so one that was cancelled but had
    /// already got its answer drops it rather than publishing it over the one
    /// that replaced it.
    @ObservationIgnored private var generation = 0

    /// `provider` is `nil` exactly where ``OpenHikesModel/trailGraphProvider``
    /// is, and then no grade is ever measured and the line keeps its colour
    /// under `difficulty`. Steepness needs no provider.
    init(provider: (any TrailGraphProviding)?, defaults: UserDefaults = .standard) {
        self.provider = provider
        self.defaults = defaults
        coloring = Self.storedColoring(in: defaults)
    }

    /// The remembered position, or the one the old on/off switch it replaced
    /// implies: turned off, it stays `off`; on, or never touched, takes the
    /// default.
    private static func storedColoring(in defaults: UserDefaults) -> RouteColoring {
        if let stored = defaults.string(forKey: SettingsKey.routeColoring).flatMap(RouteColoring.init(rawValue:)) {
            return stored
        }
        if defaults.object(forKey: SettingsKey.legacyRouteDifficultyColors) as? Bool == false {
            return .off
        }
        return SettingsDefault.routeColoring
    }

    /// Measures `hike`'s route, or clears the map with `nil`.
    ///
    /// Called on every selection change. A different hike clears the old
    /// one's stretches at once; the same hike again — reselected after its
    /// route was edited — keeps them up until the new answer replaces them,
    /// so the line does not flash back to its plain colour in between.
    func follow(_ hike: Hike?) {
        followed = hike
        if hike?.id != hikeID { publish(hikeID: nil, stretches: []) }
        measure()
    }

    /// Moves the control, remembers it, and clears the line before measuring
    /// it the new way — the old mode's colours mean something else now.
    func setColoring(_ coloring: RouteColoring) {
        guard coloring != self.coloring else { return }
        self.coloring = coloring
        defaults.set(coloring.rawValue, forKey: SettingsKey.routeColoring)
        cancelMeasurement()
        publish(hikeID: nil, stretches: [])
        measure()
    }

    private func measure() {
        cancelMeasurement()
        guard let hike = followed else { return }
        switch coloring {
        case .off:
            publish(hikeID: nil, stretches: [])
        case .difficulty:
            measureDifficulty(of: hike)
        case .elevation:
            measureSteepness(of: hike)
        }
    }

    private func measureDifficulty(of hike: Hike) {
        guard let provider else { return }
        // A breakdown already measured with no grade in it has answered the
        // question: there is nothing to colour, so there is nothing to fetch.
        // Anything still drawn is from before — the same hike followed again
        // after an edit took its grades away — and goes now.
        if let stored = hike.difficultyBreakdown, stored.surveyedFraction == 0 {
            publish(hikeID: nil, stretches: [])
            return
        }
        let route = hike.route
        start(for: hike.id) {
            await HikeTrailAnalysis.difficultyRuns(route: route, provider: provider).compactMap { run in
                run.category.shade.map { Stretch(shade: $0, coordinates: run.coordinates) }
            }
        }
    }

    private func measureSteepness(of hike: Hike) {
        let route = hike.route
        start(for: hike.id) {
            await RouteSteepness.measuredRuns(route: route).map { run in
                Stretch(shade: run.shade, coordinates: run.coordinates)
            }
        }
    }

    /// Runs `answer` and publishes it against `hikeID`, unless something has
    /// replaced it by the time it lands.
    private func start(for hikeID: UUID, answer: @escaping @Sendable () async -> [Stretch]) {
        let started = generation
        measurement = Task { [weak self] in
            let answered = await answer()
            guard let self, !Task.isCancelled, started == generation else { return }
            publish(hikeID: hikeID, stretches: answered)
        }
    }

    private func cancelMeasurement() {
        generation &+= 1
        measurement?.cancel()
        measurement = nil
    }

    private func publish(hikeID: UUID?, stretches: [Stretch]) {
        // Nothing drawn and nothing to draw: the map has no work to do, so it
        // is not woken to find that out.
        if self.stretches.isEmpty, stretches.isEmpty, self.hikeID == hikeID { return }
        self.hikeID = hikeID
        self.stretches = stretches
        revision &+= 1
    }
}
