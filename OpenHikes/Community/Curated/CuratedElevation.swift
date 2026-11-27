//
//  CuratedElevation.swift
//  OpenHikes
//
//  Heights for a route OpenStreetMap has none for.
//
//  A hiking relation is ways and nodes, not a terrain model. Measured over one
//  Berchtesgaden box while the curated feature was built: `ele` was on **zero**
//  of 1,725 geometry nodes, on 106 relations. So a curated route opens with a
//  line, a length, a surface and a difficulty — and no profile, which is the
//  one figure a hiker uses to decide whether a trail is a walk or a day out.
//  Asking Overpass for more nodes does not change that; a second source is the
//  only thing that can.
//
//  ## Who is asked, and when
//
//  The OpenHikes tile server's elevation squares: the Copernicus DEM's
//  heights, filed by eighth of a degree — see ``ElevationSquareLibrary``.
//  They were a billed service's until 2026, Stadia Maps', and so a
//  subscriber's alone. Read out of an archive of our own they cost a request
//  to our own server, so every hiker has them, and no request leaves for
//  anyone else's.
//
//  Asked **once, when a curated hike is opened**, and never for a list. A
//  nearby search offers up to a page of routes and a hiker opens one of them,
//  so fetching on the list would read twenty-five routes' squares to draw
//  one. It is the same rule the surface and difficulty analysis already
//  follows, and for the same reason.
//
//  ## And once more, for a trail somebody is drawing
//
//  The trail maker asks the same source the same question — see
//  ``TrailDraftElevation`` — because a drawn line has exactly the problem a
//  curated route has: it is geometry with no terrain under it, and the climb
//  is the figure that decides whether Saturday is a walk or a day out. What
//  differs is *when*: a curated route is opened once, while a drawn one keeps
//  changing, so that caller waits for the drawing to settle before it asks and
//  throws the answer away the moment the line moves. Everything below is
//  unchanged by it, which is the point of it being the same file.
//
//  ## What is sent, and what is kept
//
//  The names of the squares the route crosses, and nothing else: an eighth of
//  a degree each way, so a request says which valley is being looked at and
//  no more, as a map tile does. Not the hiker's position and not their
//  identity. The squares are kept on the device, as the trail squares are, so
//  a second look at the same valley sends nothing. The heights themselves
//  are asked for once the route is on screen, never ahead of it, so a slow
//  answer costs the chart its wait and nothing else; they are drawn and go
//  with the screen, and a hiker who imports the hike keeps them the way they
//  keep every other route point — see
//  ``CommunityTransporting/filledHeights(of:for:)``.
//
//  ## Read at two hundred points, written on all of them
//
//  A route is sampled down to ``CuratedElevationRequest/maximumShapePoints``
//  evenly spaced points before the squares are read, which is one height every hundred
//  metres on a twenty-kilometre trail and finer on everything shorter. The
//  heights land back on exactly those points, and every point between two of
//  them takes the height its distance along the line puts it at — see
//  ``RouteHeightSamples/interpolating(_:)``. Never across a pause, though: a
//  library hike's route can carry them, and a paused leg is not trail. Both
//  of its ends are among the two hundred, so each walked stretch has heights
//  of its own, unless the route has more pauses than half the request can
//  read the ends of — see ``CuratedElevationRequest/sampleIndexes(of:limit:)``.
//
//  Written on the sampled points alone, the chart came out the same and the
//  map did not: ``RouteSteepness`` closes its window at every point without a
//  height. A route a little over the ceiling was coloured in scraps of two or
//  three points, each a slope between two whole-metre readings and none of
//  them blending into the next, and a route of twice the ceiling or more was
//  not coloured at all. A straight run between two readings is no finer than
//  the readings themselves, but it adds nothing to the climb, and the chart
//  draws the same straight line between them that it drew before.
//

import Algorithms
import CoreLocation
import Foundation
import OpenHikesData
import OpenHikesShared
import os

/// Where a curated route's heights come from.
///
/// A protocol for the reason ``CuratedTrailSourcing`` is one: the conformance
/// that answers, ``ElevationSquareLibrary``, reaches the tile server, and no
/// suite may.
nonisolated protocol CuratedElevationSourcing: Sendable {
    /// The height in metres at each coordinate, in the order asked.
    ///
    /// Throws rather than answering short: a caller cannot pair a partial
    /// answer with the points it asked about, and a profile drawn from the
    /// wrong pairing is worse than no profile. A point the source has no
    /// height for is `nan`, in its place, and a line with one has no profile
    /// at all — see ``samples(of:)``.
    @concurrent
    func heights(at coordinates: [CLLocationCoordinate2D]) async throws -> [Double]
}

/// Which points of a route are asked about.
///
/// Pure and separate from the source, so that which points are read — the
/// whole of what this half gets wrong in practice — can be asserted without
/// a network.
nonisolated enum CuratedElevationRequest {
    /// The most points one request asks about, a library hike's pause ends
    /// included: they come out of it, never on top of it — see
    /// ``sampleIndexes(of:limit:)``.
    ///
    /// Two hundred, which is a height every hundred metres on a twenty-
    /// kilometre trail — the longest a curated route can be, since
    /// ``CuratedTrailQuery`` refuses a bounding box wider than that — and
    /// finer on everything below it. The chart plots at most 500 samples in any
    /// case, and the trail maker compares the points it asked about with the
    /// line it saves (``RouteHeightSamples/describes(_:)``), two hundred at a
    /// time.
    static let maximumShapePoints = 200

    /// Evenly spaced indexes into a route of `count` points, always including
    /// the first and the last.
    ///
    /// The ends are kept because they are where a hiker reads the profile from
    /// — the trailhead's height and the finish's — and because a series that
    /// stops short draws a chart whose x-axis disagrees with the route's own
    /// length. A route already short enough is asked about whole.
    ///
    /// The widget's stride, ``decimatedIndices(count:maxPoints:)``, rather
    /// than a copy of it (#1084): one stride is one rounding.
    static func sampleIndexes(count: Int, limit: Int = maximumShapePoints) -> [Int] {
        decimatedIndices(count: count, maxPoints: limit)
    }

    /// The indexes to ask about for `route`, never more than `limit`: both
    /// ends of every leg a pause opened, while they come to half of it or
    /// less, and the rest spread evenly over the other points.
    ///
    /// A paused leg is not trail (see ``RouteBoundary``), so no height is
    /// interpolated across one — see ``RouteHeightSamples/interpolating(_:)``.
    /// Reading the last walked point before a pause and the first after it
    /// gives each walked stretch a height at its own ends, the way
    /// ``WatchTrailPackaging`` keeps them for the watch. They come out of the
    /// request rather than on top of it, so a hike with pauses asks about
    /// exactly as many points as one without.
    ///
    /// **At most half the request goes to pause ends.** A recording pauses as
    /// often as its hiker did, but a GPX file opens one with every `<trkseg>`
    /// after the first, and nothing bounds how many segments a file holds.
    /// Allowed the whole request, those ends would place the readings by how
    /// the file was split rather than by where the walking is: a long walk
    /// after a run of short splits would be read at its own two ends and
    /// little else. So a route whose pause ends would be more than half is
    /// asked ``sampleIndexes(count:limit:)``, spread along the whole line. Its
    /// stretches are still never filled across a pause; one that no reading
    /// lands on is left without heights. No pause is kept over another,
    /// because the length of a break says nothing about the ground either
    /// side of it.
    ///
    /// Curated routes and drawn trails carry no pauses, and are asked exactly
    /// what they were before.
    static func sampleIndexes(of route: [RouteCoordinate], limit: Int = maximumShapePoints) -> [Int] {
        let spread = sampleIndexes(count: route.count, limit: limit)
        // A route asked about whole has every pause's ends in it already.
        guard spread.count < route.count else { return spread }
        let pauseEnds = Set(route.trailRuns.pausedLegs.flatMap { [$0, $0 + 1] })
        guard !pauseEnds.isEmpty, pauseEnds.count <= limit / 2 else { return spread }
        // The rest, at least half the request, is spread over the points that
        // are not a pause's end, so no point is asked about twice and the
        // request comes to `limit` exactly. Its first and last are the
        // route's, as the plain spread's are, unless a pause's end already is.
        // The fill is the one the widget and the watch share; only the choice
        // of ends is this request's.
        return decimatedIndices(count: route.count, maxPoints: limit, keeping: pauseEnds)
    }
}

/// Why a height request produced nothing usable.
///
/// Never shown to a hiker. A curated hike with no profile draws no chart at
/// all — see ``CommunityHikeView/elevationSection`` — so these exist to be
/// logged and to keep the failing branches apart in a test.
nonisolated enum CuratedElevationFailure: LocalizedError, Equatable {
    /// The line crosses more squares than one request reads — see
    /// ``ElevationSquareLibrary/maximumSquaresPerRequest``.
    case tooLong
    /// No elevation archive this build reads: the tile server lists none, or
    /// this launch reaches no server. Every suite's launch is this one.
    case uncovered
    /// A square the line needs could not be read, or was not a square.
    case unreachable

    var errorDescription: String? {
        switch self {
        case .tooLong: String(localized: "This route is too long to read its elevation at once.")
        case .uncovered: String(localized: "No elevation data is available for this version of the app.")
        case .unreachable: String(localized: "The elevation for this route could not be downloaded.")
        }
    }
}

/// A route's heights, at the points that were actually asked about.
///
/// Kept as a value of its own rather than folded straight into the route,
/// because the two callers want different things out of one answer. A curated
/// hike wants the route *filled* and nothing else: it opens once, draws a
/// chart, and never has to ask again. The trail maker wants the figures while
/// the hiker goes on drawing, and then — possibly many edits later — has to be
/// able to say whether the line it is about to save is still the line these
/// were read for.
///
/// Carrying the coordinates is what answers that second question. They are the
/// ones that were sent, so a route whose sampled points still stand where
/// these stood is the route these describe. Comparing them is exact rather
/// than approximate on purpose: these *are* the route's own values, copied,
/// and a tolerance would only be a way of accepting a height for a point that
/// has moved.
nonisolated struct RouteHeightSamples: Equatable, Sendable {
    /// How many points the route had when these were read.
    ///
    /// Which indexes were asked about follows from this and from where the
    /// route was paused — see
    /// ``CuratedElevationRequest/sampleIndexes(of:limit:)`` — so a route of
    /// a different length is a different question, and the indexes below are
    /// not necessarily even in bounds for it.
    let routePointCount: Int
    /// The indexes asked about, ascending, both ends included.
    let indexes: [Int]
    /// The route's points at those indexes, as they were sent.
    let coordinates: [RouteCoordinate]
    /// The height in metres at each, in the same order.
    let heights: [Double]

    /// What the sampled heights add up to: the climb, the drop and the two
    /// extremes.
    ///
    /// Read off the samples rather than off a filled route, and they are the
    /// same numbers either way: every point ``interpolating(_:)`` adds lies on
    /// the straight run between two readings, or holds one of them, which
    /// climbs and drops no more than they do and reaches no higher or lower.
    /// Computed on demand because it is two hundred additions and the caller
    /// stores the answer.
    ///
    /// A pause ends the run, as it does on the route itself — see
    /// ``ElevationAccumulator/record(_:)`` — because the point it resumed at
    /// is among the samples and carries the mark. On a route with more pauses
    /// than ``CuratedElevationRequest/sampleIndexes(of:limit:)`` reads the
    /// ends of, a pause can fall between two samples, and the run goes on
    /// across it. Only the trail maker reads this, and a drawn line has none.
    var summary: RouteElevationSummary {
        var accumulator = ElevationAccumulator()
        for (coordinate, height) in zip(coordinates, heights) {
            var reading = coordinate
            reading.elevation = height
            accumulator.record(reading)
        }
        return RouteElevationSummary(accumulator)
    }

    /// Whether `route` is still the route these heights were read for.
    func describes(_ route: [RouteCoordinate]) -> Bool {
        guard route.count == routePointCount, indexes.count == coordinates.count else { return false }
        return zip(indexes, coordinates).allSatisfy { index, sampled in
            route[index].latitude == sampled.latitude
                && route[index].longitude == sampled.longitude
        }
    }

    /// `route` with a height on every point between the first and last that
    /// were read, the ones in between interpolated by distance along the
    /// line — or `route` untouched when it is not the route they were read
    /// for.
    ///
    /// How every caller puts these heights on its line. Written on the
    /// sampled points alone, they would leave every point between two samples
    /// without a height, and ``RouteSteepness`` closes its window at a point
    /// with none, so a snapped line — thousands of points and two hundred
    /// heights — would measure as nothing at all. A straight run between two
    /// readings is the grade those two readings give, which is as fine as the
    /// answer gets.
    ///
    /// **Never towards a reading that is not a number.** That is ground the
    /// source has no height for — land Copernicus withholds — and a straight
    /// run from the readings either side of it across that ground would be a
    /// grade nobody measured, shown and saved as the model's. So such a
    /// reading puts no height on its own point, and the points between it and
    /// its neighbours keep none either. ``samples(of:)`` already declines a
    /// line with one, so this is the guard for a caller that builds its own
    /// samples.
    ///
    /// **Never across a pause** (#1032). A paused leg is not trail (see
    /// ``RouteBoundary``): a cable car rising a kilometre, joined straight to
    /// the readings either side of it, put its grade on the level ground
    /// beside it, and so into the climb, the chart and the *Elevation*
    /// colours of a hike whose every walked metre was flat. Both ends of a
    /// pause are normally read themselves —
    /// ``CuratedElevationRequest/sampleIndexes(of:limit:)`` — so this bites
    /// only when one of them was not a number, or the route had more pauses
    /// than the request reads the ends of. Then a walked stretch holds the
    /// reading nearest it on its own side, which adds no climb, and a stretch
    /// with no reading of its own is given no height at all.
    func interpolating(_ route: [RouteCoordinate]) -> [RouteCoordinate] {
        guard describes(route) else { return route }
        var filled = route
        let readings = Array(zip(indexes, heights))
        for reading in readings where reading.1.isFinite {
            filled[reading.0].elevation = reading.1
        }
        let pausedLegs = route.trailRuns.pausedLegs
        for (start, end) in readings.adjacentPairs() where end.0 - start.0 > 1 {
            // The paused legs between the two readings, in order: leg
            // `start.0` is the first out of the one before, and `end.0 - 1`
            // the last into the one after.
            let first = pausedLegs.partitioningIndex { $0 >= start.0 }
            let past = pausedLegs.partitioningIndex { $0 >= end.0 }
            if first < past {
                if start.1.isFinite {
                    for index in (start.0 + 1)..<(pausedLegs[first] + 1) { filled[index].elevation = start.1 }
                }
                if end.1.isFinite {
                    for index in (pausedLegs[past - 1] + 1)..<end.0 { filled[index].elevation = end.1 }
                }
                continue
            }
            guard start.1.isFinite, end.1.isFinite else { continue }
            // How far along the line each point between the two is, from the
            // first: `along[k]` is the distance to `route[start.0 + k]`.
            let along = route[start.0...end.0].adjacentPairs().reductions(0) { total, pair in
                total + pair.1.legMeters(from: pair.0)
            }
            let total = along[along.count - 1]
            let steps = Double(end.0 - start.0)
            for offset in 1..<(end.0 - start.0) {
                let fraction = total > 0 ? along[offset] / total : Double(offset) / steps
                filled[start.0 + offset].elevation = start.1 + (end.1 - start.1) * fraction
            }
        }
        return filled
    }
}

/// Where the log for this half of the feature goes. File-scoped so the
/// protocol extension below can reach it without every conformance carrying
/// one.
nonisolated private let elevationLogger = Logger(subsystem: "OpenHikes", category: "Community")

nonisolated extension CuratedElevationSourcing {
    /// The heights at the points `route` samples down to, or `nil` when the
    /// squares could not answer.
    ///
    /// **A failure here is not a failure of the screen.** A curated hike is a
    /// line, a length, a surface and a difficulty before it is a profile, and
    /// every one of those is already in hand by the time this is asked. So a
    /// square that would not come, a timeout, a launch with no server — all of
    /// them draw the hike without a chart, which is what the screen did before
    /// this existed and what it still does for ground with no heights. The
    /// trail maker's header is the same bargain: no figure rather than a wrong
    /// one.
    ///
    /// **A line that crosses ground with no heights has no profile.** That is
    /// land Copernicus withholds (see ``ElevationSquareLibrary``), and the
    /// heights either side of it are not the heights across it: joined, they
    /// would draw a grade nobody measured, and a library hike or a saved
    /// trail would keep it as the model's. Nor is a profile with a hole in it
    /// worth having, because the climb, the chart and the *Elevation* colours
    /// would each stop and start at it. So one reading that is not a number
    /// costs the whole answer, as a square that would not come does, and an
    /// answer of nothing but those is never handed on to be saved as a fill.
    ///
    /// Two of the refusals are logged at `info` rather than `error`, and that
    /// is about the second caller. A launch with no elevation archive to read,
    /// and a line over withheld ground, are states this is *designed* to
    /// have, and the maker asks again every time a drawing settles — so at
    /// `error` they would be the loudest things in the log, and the refusals
    /// worth reading would be buried under them.
    func samples(of route: [RouteCoordinate]) async -> RouteHeightSamples? {
        let indexes = CuratedElevationRequest.sampleIndexes(of: route)
        guard indexes.count > 1 else { return nil }
        let coordinates = indexes.map { route[$0] }
        do {
            let heights = try await heights(at: coordinates.map(\.clCoordinate))
            guard heights.count == coordinates.count, heights.allSatisfy(\.isFinite) else {
                elevationLogger.info("No heights for a route: it crosses ground the elevation squares have none for.")
                return nil
            }
            return RouteHeightSamples(
                routePointCount: route.count,
                indexes: indexes,
                coordinates: coordinates,
                heights: heights
            )
        } catch CuratedElevationFailure.uncovered {
            elevationLogger.info("No heights for a route: this launch reads no elevation squares.")
            return nil
        } catch {
            elevationLogger.error(
                """
                No heights for a route: \(error.localizedDescription, privacy: .public). \
                It is drawn without a profile.
                """
            )
            return nil
        }
    }

    /// `route` with a height on every point — read at the points that were
    /// asked about, interpolated between them — or `route` exactly as it came
    /// when the squares could not answer.
    ///
    /// The whole of what a curated hike wants from one of these: it opens
    /// once, draws, and has no reason to remember which points carried the
    /// answer. See ``RouteHeightSamples`` for the caller that does.
    func filled(_ route: [RouteCoordinate]) async -> [RouteCoordinate] {
        guard let samples = await samples(of: route) else { return route }
        return samples.interpolating(route)
    }
}

/// A source that answers nothing, for the launches that must not ask.
///
/// The elevation half of ``DormantLocationSource``'s argument: a suite, or a
/// UI-test launch with no curated scenario, gets one of these rather than a
/// real one that would reach the tile server.
nonisolated struct DormantElevationSource: CuratedElevationSourcing {
    @concurrent
    func heights(at coordinates: [CLLocationCoordinate2D]) async throws -> [Double] {
        throw CuratedElevationFailure.uncovered
    }
}
