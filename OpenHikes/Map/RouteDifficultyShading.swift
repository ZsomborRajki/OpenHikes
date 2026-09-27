//
//  RouteDifficultyShading.swift
//  OpenHikes
//
//  The selected hike's line, coloured by how hard each stretch of it is: the
//  SAC grade OpenStreetMap gives the way beneath it, in the colours the
//  hike's Difficulty section already charts the same grades in.
//
//  The grades are not stored. `Hike.difficultyMetersByGrade` keeps how many
//  metres each grade covers, which is what the section needs and all that it
//  needs — *where* those metres are is a second measurement, and keeping it
//  would be a CloudKit column holding a copy of the route for something the
//  trail graph answers again in milliseconds once it is cached. So this asks
//  every time the selection changes, from the same graph and the same walk
//  the section's figures came from (see ``TrailBreakdownAnalyzer``), and a
//  stretch drawn red on the map is the red share of the bar beneath it.
//
//  Held in a reference type the map observes directly, for the reason
//  ``WalkHighlight`` is: the answer is a handful of polylines for MapKit, and
//  no SwiftUI view has any business re-rendering for it.
//

import CoreLocation
import Foundation
import OpenHikesData

@Observable
final class RouteDifficultyShading {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// One graded stretch of the line, and the grade it is drawn in.
    struct Stretch {
        let difficulty: TrailDifficulty
        let coordinates: [CLLocationCoordinate2D]
    }

    /// Bumped on every change to what the map should draw. The coordinator
    /// observes this one `Int` and reads ``hikeID`` and ``stretches`` inside
    /// the same pass — the arrangement ``WalkHighlight/revision`` explains.
    private(set) var revision = 0
    /// Which hike ``stretches`` were measured along. The map draws them only
    /// over that hike's line, so an answer arriving after the selection moved
    /// on can never colour the next hike's route with the last one's grades.
    @ObservationIgnored private(set) var hikeID: UUID?
    /// The graded stretches, in route order. Empty when the switch is off,
    /// before the answer lands, and for a route OSM grades nowhere.
    @ObservationIgnored private(set) var stretches: [Stretch] = []

    /// The *Difficulty Colors* switch in Route Style. Observed, because that
    /// switch reads it; the map never does — turning it off empties
    /// ``stretches``, which is all the map needs to know.
    private(set) var isEnabled: Bool

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
    /// is, and then nothing is ever measured and the line keeps its colour.
    init(provider: (any TrailGraphProviding)?, defaults: UserDefaults = .standard) {
        self.provider = provider
        self.defaults = defaults
        isEnabled = defaults.object(forKey: SettingsKey.routeDifficultyColors) as? Bool
            ?? SettingsDefault.routeDifficultyColors
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

    /// Flips the switch, remembers it, and measures or clears to match.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: SettingsKey.routeDifficultyColors)
        if enabled {
            measure()
        } else {
            cancelMeasurement()
            publish(hikeID: nil, stretches: [])
        }
    }

    private func measure() {
        cancelMeasurement()
        guard isEnabled, let hike = followed, let provider else { return }
        // A breakdown already measured with no grade in it has answered the
        // question: there is nothing to colour, so there is nothing to fetch.
        // Anything still drawn is from before — the same hike followed again
        // after an edit took its grades away — and goes now.
        if let stored = hike.difficultyBreakdown, stored.surveyedFraction == 0 {
            publish(hikeID: nil, stretches: [])
            return
        }
        let measuredID = hike.id
        let route = hike.route
        let started = generation
        measurement = Task { [weak self] in
            let runs = await HikeTrailAnalysis.difficultyRuns(route: route, provider: provider)
            guard let self, !Task.isCancelled, started == generation else { return }
            publish(
                hikeID: measuredID,
                stretches: runs.map { Stretch(difficulty: $0.category, coordinates: $0.coordinates) }
            )
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
