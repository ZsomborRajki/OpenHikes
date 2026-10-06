//
//  TrailDraftShading.swift
//  OpenHikes
//
//  The trail being drawn, coloured stretch by stretch on the ``RouteShade``
//  scale — the same colours, from the same measurements, as a saved hike's
//  line, so the maker shows what the hike will look like once it is saved.
//
//  Both ways are measured, not just the one the *Color By* control is on.
//  That control is shared by every hike (see ``RouteShading``) and moving it
//  in the maker has to repaint the line straight away, and each answer is
//  cheap: neither one asks anything of the network.
//
//  - **Difficulty** comes from the trail graph a hiking leg was routed over,
//    and only from the cache — see ``HikeTrailAnalysis/difficultyRuns(route:provider:downloading:)``.
//    Asked after every leg lands, once no leg is still waiting.
//  - **Elevation** comes from the heights ``TrailDraftElevation`` reads, once
//    they land. Those are two hundred readings along a line of any length, so
//    the points between them are interpolated before steepness is measured —
//    see ``RouteHeightSamples/interpolating(_:)``.
//
//  Hiking only. Walking, cycling and driving legs come from Apple's
//  directions and run along roads, where neither a SAC grade nor a hill on a
//  footpath is the thing worth knowing.
//
//  ## When the control is offered
//
//  ``offered`` is every way of colouring this drawing has had an answer for
//  since the maker opened, and it stays set while the line changes. Each edit
//  throws the colours away until the line has been measured again, so a
//  section shown only while the colours are up would hide and come back with
//  every point the hiker put down, moving everything under it each time.
//

import CoreLocation
import Foundation
import Observation
import OpenHikesData

/// The colours of the trail being drawn, and what asks for them.
///
/// A stable `@Observable` reference type for the reason ``TrailDraftElevation``
/// is one, and held beside it for the same reason: nothing here is part of the
/// drawing, and closing the maker forgets all of it.
@Observable
final class TrailDraftShading {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// Bumped on every change to what the map should draw. The map observes
    /// this one `Int` and reads ``stretches(for:)`` in the same pass — the
    /// arrangement ``RouteShading/revision`` explains.
    private(set) var revision = 0

    /// The ways of colouring this drawing that have had an answer since the
    /// maker opened — see the file header. Read by the maker's *Color By*
    /// section, which is shown while this is not empty.
    private(set) var offered: Set<RouteColoring> = []

    /// The graded stretches of the line, in route order.
    @ObservationIgnored private(set) var difficulty: [RouteShading.Stretch] = []
    /// The line's stretches by steepness, in route order.
    @ObservationIgnored private(set) var steepness: [RouteShading.Stretch] = []

    /// The measurement in flight, if any. Readable so a suite can wait on the
    /// effect rather than on a duration.
    @ObservationIgnored private(set) var measurement: Task<Void, Never>?

    @ObservationIgnored private let draft: TrailDraft
    @ObservationIgnored private let provider: (any TrailGraphProviding)?
    /// Identifies the line the measurements are about, so an answer that
    /// lands after the line moved on is dropped rather than drawn over it.
    @ObservationIgnored private var generation = 0

    /// - Parameter provider: the graph the hiking legs are routed over, or
    ///   `nil` for a launch with none — then nothing is graded, and only the
    ///   heights can colour the line.
    init(draft: TrailDraft, provider: (any TrailGraphProviding)?) {
        self.draft = draft
        self.provider = provider
    }

    /// The stretches to draw for `coloring`: none at all for *None*.
    func stretches(for coloring: RouteColoring) -> [RouteShading.Stretch] {
        switch coloring {
        case .difficulty: difficulty
        case .elevation: steepness
        case .off: []
        }
    }

    /// The line moved: both answers are about a trail that no longer exists.
    ///
    /// Called wherever ``TrailDraftElevation/drawingDidChange()`` is. The
    /// grades are asked for again at once if no leg is still being routed;
    /// otherwise the leg that lands last asks. The heights come back through
    /// ``heightsDidLand(_:)``.
    func drawingDidChange() {
        forget()
        measureDifficulty()
    }

    /// The line's heights have been read: colour it by steepness.
    func heightsDidLand(_ samples: RouteHeightSamples) {
        guard draft.travelMode == .hiking else { return }
        let route = draft.routeCoordinates
        guard samples.describes(route) else { return }
        let measured = samples.interpolating(route)
        start {
            .steepness(await RouteSteepness.measuredRuns(route: measured).map { run in
                RouteShading.Stretch(shade: run.shade, coordinates: run.coordinates)
            })
        }
    }

    /// Forgets everything, the offer included. What closing, saving and
    /// discarding the drawing do.
    func clear() {
        forget()
        offered = []
    }

    private func measureDifficulty() {
        guard draft.travelMode == .hiking, let provider, !draft.isRouting else { return }
        let route = draft.routeCoordinates
        guard route.count > 1 else { return }
        start {
            let runs = await HikeTrailAnalysis.difficultyRuns(route: route, provider: provider, downloading: false)
            return .difficulty(runs.compactMap { run in
                run.category.shade.map { RouteShading.Stretch(shade: $0, coordinates: run.coordinates) }
            })
        }
    }

    /// One of the two answers.
    private enum Answer {
        case difficulty([RouteShading.Stretch])
        case steepness([RouteShading.Stretch])
    }

    /// Runs `measure` and publishes its answer, unless the line has moved on
    /// by the time it lands.
    ///
    /// Chained onto the measurement already running rather than replacing
    /// it: the grades and the heights are two questions about one line, and
    /// one landing must not cancel the other.
    private func start(_ measure: @escaping @Sendable () async -> Answer) {
        let started = generation
        let previous = measurement
        measurement = Task { [weak self] in
            await previous?.value
            let answered = await measure()
            guard let self, !Task.isCancelled, started == generation else { return }
            publish(answered)
        }
    }

    private func publish(_ answer: Answer) {
        switch answer {
        case .difficulty(let stretches):
            difficulty = stretches
            if !stretches.isEmpty { offer(.difficulty) }
        case .steepness(let stretches):
            steepness = stretches
            if !stretches.isEmpty { offer(.elevation) }
        }
        revision &+= 1
    }

    /// Adds `coloring` to the offer — only when it is new, so an answer
    /// landing does not wake the section to find nothing changed.
    private func offer(_ coloring: RouteColoring) {
        guard !offered.contains(coloring) else { return }
        offered.insert(coloring)
    }

    /// Drops both answers and cancels whatever was going to replace them.
    private func forget() {
        generation &+= 1
        measurement?.cancel()
        measurement = nil
        guard !difficulty.isEmpty || !steepness.isEmpty else { return }
        difficulty = []
        steepness = []
        revision &+= 1
    }
}
