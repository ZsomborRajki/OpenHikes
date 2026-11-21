//
//  RouteTrimSession.swift
//  OpenHikes
//
//  One visit to *Edit Route* on a hike that was recorded or imported: the
//  whole line it works on, where the two cuts stand on it, how each stretch
//  to check is answered, and what the map draws of all three.
//
//  ## The whole line
//
//  Not the line the hike has now but the one it was saved with, put together
//  under the answers that stand, with the hike's trim as two cuts on it — see
//  ``RouteEditSources``. Changing an answer puts the line together again and
//  moves the cuts with the ground they stood on.
//
//  ## Whose it is
//
//  ``SheetPresentation`` keeps one for as long as the screen's route is on
//  the path, for the reason it keeps every pushed screen's state: a turn of
//  the phone builds the screen again in the other host, and the cuts a hiker
//  placed must not go back to the ends. The pop that takes the screen away
//  ends it, which is what takes its handles off the map.
//
//  ## Two readers, neither a screen's body
//
//  The cuts move at drag frequency, from the chart in the sheet and from the
//  handles on the map. The map reads them directly (see `MapRouteTrim.swift`),
//  and in the sheet only the leaf views that draw them do, so a drag redraws
//  the chart, the figures and the Save button and nothing above them — see
//  *Render isolation, in practice* in `AGENTS.md`. Both cuts are `Double`s,
//  which Observation filters a same-value write of, so a handle held still
//  wakes nothing.
//

import Algorithms
import CoreLocation
import Foundation
import MapKit
import OpenHikesData

/// Which end of the line a cut is.
nonisolated enum RouteTrimHandle: Sendable {
    case end
    case start

    /// The pause on this end of the line — see ``RouteTrim/EndPauses``.
    var endPause: RouteTrim.EndPauses {
        switch self {
        case .end: .end
        case .start: .start
        }
    }
}

/// The line a session trims, measured once, off the main actor.
nonisolated struct RouteTrimLine: Sendable {
    /// Where a cut stands on the map.
    struct Spot: Sendable {
        let coordinate: CLLocationCoordinate2D
        /// How far along the polyline MapKit draws it, 0 to 1: the scale
        /// `MKPolylineRenderer.strokeStart` and `strokeEnd` are in.
        let drawnFraction: Double
    }

    let route: [RouteCoordinate]
    let profile: RouteProfile
    let carriedEnds: RouteCarriedEnds
    /// Where each stretch to check is in ``route``, by its id — see
    /// ``RouteAssembly/Line``. Empty for a line with none.
    var checkRanges: [Int: ClosedRange<Int>] = [:]
    /// The answer each stretch to check is drawn under, by its id.
    var choices: [Int: RouteCheck.Choice] = [:]
    /// The pieces the line was put together from, and where each is in
    /// ``route`` — see ``RouteAssembly/Line/pieceRanges``. Empty for a line
    /// with no stretches to check.
    var pieces: [RouteAssembly.Piece] = []
    var pieceRanges: [ClosedRange<Int>?] = []
    /// How far along the drawn polyline each point stands, 0 to 1, by the
    /// length MapKit measures a polyline in: map points, a paused leg's
    /// included, since the polyline is drawn across it.
    let drawnFractions: [Double]

    var distances: [Double] { profile.distances }
    var totalMeters: Double { profile.totalDistanceMeters }

    /// The whole line of `sources` under `assembly`, measured.
    @concurrent
    static func measuring(
        _ sources: RouteEditSources,
        under assembly: RouteAssembly?
    ) async throws(CancellationError) -> Self {
        let whole = sources.whole(under: assembly)
        var line = try await measuring(whole.route)
        line.checkRanges = whole.checkRanges
        line.choices = Self.choices(of: assembly?.checks ?? [])
        line.pieces = assembly?.pieces ?? []
        line.pieceRanges = whole.pieceRanges
        return line
    }

    /// The answers `checks` stand under, by stretch: what tells two lines
    /// put together from the same pieces apart.
    static func choices(of checks: [RouteCheck]) -> [Int: RouteCheck.Choice] {
        Dictionary(checks.map { ($0.id, $0.choice) }, uniquingKeysWith: { first, _ in first })
    }

    /// The part of the line a stretch to check takes up, in metres along it.
    func meters(ofCheck id: Int) -> ClosedRange<Double>? {
        guard let range = checkRanges[id], distances.indices.contains(range.upperBound) else { return nil }
        return distances[range.lowerBound]...distances[range.upperBound]
    }

    /// Where the spot `distance` metres along this line is on `other`: the
    /// same pieces put together under other answers. A piece the two draw
    /// alike — kept ground, or a stretch answered alike — is the same ground
    /// on both, so a spot on it is the same spot. The leg joining two pieces
    /// is neither's, and changes with the pieces it joins, so a spot on it
    /// keeps its share of it.
    ///
    /// A spot inside a stretch the two draw differently is on no ground
    /// `other` has, so it goes to the edge of that stretch `handle` keeps it
    /// whole from: a start to its beginning, an end to its finish. Either end
    /// of the line is the same end of `other`.
    func meters(matching distance: Double, on other: Self, for handle: RouteTrimHandle) -> Double {
        if distance <= 0 { return 0 }
        if distance >= totalMeters { return other.totalMeters }
        guard choices != other.choices, pieces == other.pieces, pieceRanges.count == other.pieceRanges.count else {
            return min(distance, other.totalMeters)
        }
        var behind = (here: 0.0, there: 0.0)
        for (index, piece) in pieces.enumerated() {
            guard let here = meters(ofPiece: index), let there = other.meters(ofPiece: index) else { continue }
            if distance <= here.lowerBound {
                let leg = behind.there...there.lowerBound
                return Self.share(of: distance, from: behind.here, to: here.lowerBound, on: leg)
            }
            if distance < here.upperBound {
                if case .check(let id) = piece, choices[id] != other.choices[id] {
                    return handle == .start ? there.lowerBound : there.upperBound
                }
                return min(there.lowerBound + distance - here.lowerBound, there.upperBound)
            }
            behind = (here.upperBound, there.upperBound)
        }
        return Self.share(of: distance, from: behind.here, to: totalMeters, on: behind.there...other.totalMeters)
    }

    /// The part of the line one of ``pieces`` takes up, in metres along it.
    private func meters(ofPiece index: Int) -> ClosedRange<Double>? {
        guard pieceRanges.indices.contains(index), let range = pieceRanges[index],
              distances.indices.contains(range.upperBound)
        else { return nil }
        return distances[range.lowerBound]...distances[range.upperBound]
    }

    /// The spot on `there` that is as far along it as `distance` is from
    /// `start` to `end`.
    private static func share(
        of distance: Double,
        from start: Double,
        to end: Double,
        on there: ClosedRange<Double>
    ) -> Double {
        guard end > start else { return there.upperBound }
        let fraction = min(max((distance - start) / (end - start), 0), 1)
        return there.lowerBound + fraction * (there.upperBound - there.lowerBound)
    }

    /// The points a stretch to check is drawn with.
    func coordinates(ofCheck id: Int) -> [CLLocationCoordinate2D] {
        guard let range = checkRanges[id], profile.coordinates.indices.contains(range.upperBound) else { return [] }
        return Array(profile.coordinates[range])
    }

    @concurrent
    static func measuring(_ route: [RouteCoordinate]) async throws(CancellationError) -> Self {
        assertOffMainThread("A route is measured for trimming off the main thread")
        let measured = try RouteProfile.cancellable(route: route)
        let carried = RouteCarriedEnds.found(in: route, distances: measured.distances)
        guard !Task.isCancelled else { throw CancellationError() }
        return Self(
            route: route,
            profile: measured,
            carriedEnds: carried,
            drawnFractions: Self.drawnFractions(of: measured.coordinates)
        )
    }

    private static func drawnFractions(of coordinates: [CLLocationCoordinate2D]) -> [Double] {
        var lengths: [Double] = []
        lengths.reserveCapacity(coordinates.count)
        var cumulative = 0.0
        var previous: MKMapPoint?
        for coordinate in coordinates {
            let point = MKMapPoint(coordinate)
            if let previous { cumulative += hypot(point.x - previous.x, point.y - previous.y) }
            lengths.append(cumulative)
            previous = point
        }
        guard cumulative > 0 else { return lengths }
        return lengths.map { $0 / cumulative }
    }

    /// Where a line that begins `meters` along this one begins. Across a
    /// pause that is the fix after it, as ``RouteTrim`` cuts it.
    ///
    /// - Parameter takingOffPause: whether a cut on the line's own first
    ///   point takes off the pause after it — see ``RouteTrim/EndPauses``.
    func startSpot(at meters: Double, takingOffPause: Bool = false) -> Spot {
        // An end left alone is the line's own first point, a pause on it
        // included, as ``RouteTrim`` leaves it.
        if isLeftAlone(.start, at: meters, takingOffPause: takingOffPause), let first = profile.coordinates.first {
            return Spot(coordinate: first, drawnFraction: 0)
        }
        return spot(at: bracket(meters, for: .start))
    }

    /// Where a line that ends `meters` along this one ends: across a pause,
    /// the fix before it.
    func endSpot(at meters: Double, takingOffPause: Bool = false) -> Spot {
        if isLeftAlone(.end, at: meters, takingOffPause: takingOffPause), let last = profile.coordinates.last {
            return Spot(coordinate: last, drawnFraction: 1)
        }
        return spot(at: bracket(meters, for: .end))
    }

    /// The clock at a cut `meters` along the line, read off the two points
    /// either side of it, or `nil` where they carry none. An end left alone
    /// is its own point's, as the hike's *Duration* reads it.
    func timestamp(of handle: RouteTrimHandle, at meters: Double, takingOffPause: Bool = false) -> Date? {
        if isLeftAlone(handle, at: meters, takingOffPause: takingOffPause) {
            return handle == .start ? route.first?.timestamp : route.last?.timestamp
        }
        let leg = bracket(meters, for: handle)
        guard let began = route[leg.lower].timestamp, let arrived = route[leg.upper].timestamp else { return nil }
        return began.addingTimeInterval(arrived.timeIntervalSince(began) * leg.fraction)
    }

    /// Whether a cut `meters` along the line is no cut at all: it stands on
    /// its own end of the line, and leaves the pause there.
    private func isLeftAlone(_ handle: RouteTrimHandle, at meters: Double, takingOffPause: Bool) -> Bool {
        guard !takingOffPause else { return false }
        return switch handle {
        case .start: meters <= 0
        case .end: meters >= totalMeters
        }
    }

    /// The leg a cut falls on, and how far along it.
    private struct Bracket {
        let lower: Int
        let upper: Int
        let fraction: Double
    }

    /// Of the points standing at one distance, either side of a pause, a
    /// start takes the last and an end the first — see ``RouteTrim``.
    private func bracket(_ meters: Double, for handle: RouteTrimHandle) -> Bracket {
        let past = switch handle {
        case .start: distances.partitioningIndex { $0 > meters }
        case .end: distances.partitioningIndex { $0 >= meters }
        }
        let upper = min(past, distances.count - 1)
        let lower = max(upper - 1, 0)
        let length = distances[upper] - distances[lower]
        let fraction = length > 0 ? min(max((meters - distances[lower]) / length, 0), 1) : 0
        return Bracket(lower: lower, upper: upper, fraction: fraction)
    }

    private func spot(at leg: Bracket) -> Spot {
        Spot(
            coordinate: RouteGeometry.interpolate(
                from: profile.coordinates[leg.lower],
                to: profile.coordinates[leg.upper],
                fraction: leg.fraction
            ),
            drawnFraction: drawnFractions[leg.lower]
                + (drawnFractions[leg.upper] - drawnFractions[leg.lower]) * leg.fraction
        )
    }

    /// How far along the line the spot nearest `coordinate` is, looking only
    /// around `anchor`, where the handle being dragged stands.
    ///
    /// A handle slides along its line, so a finger that crosses to the other
    /// side of a loop must not take it there: the search stays inside
    /// ``RouteProfile/candidateSegmentRange(near:)``, and inside it a spot
    /// further along the line has to be nearer the finger to win, by
    /// ``continuityWeight``. That is what keeps the handle on its own leg of
    /// an out-and-back, whose two legs lie on top of each other.
    func distance(nearest coordinate: CLLocationCoordinate2D, around anchor: Double) -> Double? {
        var best: (cost: Double, meters: Double)?
        for index in profile.candidateSegmentRange(near: anchor) {
            let length = distances[index + 1] - distances[index]
            // A paused leg is no part of the line — see ``RouteBoundary``.
            guard length > 0 else { continue }
            let projection = RouteGeometry.project(
                coordinate,
                onSegmentFrom: profile.coordinates[index],
                to: profile.coordinates[index + 1]
            )
            let meters = distances[index] + projection.fraction * length
            let cost = projection.offRouteMeters + Self.continuityWeight * abs(meters - anchor)
            if cost < best?.cost ?? .greatestFiniteMagnitude { best = (cost, meters) }
        }
        return best?.meters
    }

    /// How many metres nearer the finger a spot has to be for each metre
    /// further along the line it is from the handle.
    static let continuityWeight = 0.02
}

@Observable
final class RouteTrimSession {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// The least a trim may leave: two handles closer than this are one
    /// place, and a line that short is no hike.
    static let minimumKeptMeters = 50.0
    /// How near its end a cut has to be to count as standing on it.
    static let endToleranceMeters = 0.5

    /// Moves when the whole line is put together anew — a load, or an answer
    /// changed — which is rare; the map and the screen read ``line`` when it
    /// does.
    private(set) var lineRevision = 0
    @ObservationIgnored private(set) var line: RouteTrimLine?
    /// What the visit works from. Kept to tell the same hike again from a
    /// new one, and for what a save compares against.
    @ObservationIgnored private(set) var sources: RouteEditSources?

    /// Where the kept line begins and ends, in metres along ``line``.
    private(set) var startMeters = 0.0
    private(set) var endMeters = 0.0
    /// The pauses standing on the line's own two ends that the cuts take
    /// off, which no distance along the line can say — see
    /// ``RouteTrim/EndPauses``. Only an offer sets one
    /// (``takeOff(_:at:)``); placing that handle by hand clears it.
    private(set) var pausesTakenOff: RouteTrim.EndPauses = []

    /// The stretches to check, as the hiker has answered them. Empty for a
    /// hike with none. An answer is here the moment it is given, and the
    /// line catches up with it — see ``settled()``.
    private(set) var checks: [RouteCheck] = []
    /// The stretch the hiker is looking at, which the map picks out.
    private(set) var focusedCheckID: Int?
    /// Whether the hike still asks for a look — see ``RouteEdit/isOwedALook``.
    private(set) var isOwedALook = false
    /// How long the line the hike has now is, which the figures measure
    /// what a save would take off, or give back, against.
    @ObservationIgnored private(set) var currentLengthMeters = 0.0
    /// How long each stretch is under each of its answers, by the stretch's
    /// id: what tells two answers apart in the list.
    @ObservationIgnored private(set) var choiceMeters: [Int: [RouteCheck.Choice: Double]] = [:]
    /// The stretches of the hike's own line, as the map still draws it, that
    /// an answer changed in this visit has replaced. The map covers them.
    @ObservationIgnored private(set) var staleStretches: [[CLLocationCoordinate2D]] = []

    /// Whether a save or a revert is under way, which holds the buttons.
    var isSaving = false
    /// Why the last one did not land, while its alert is up.
    var refusal: RouteEditRefusal?

    /// The Health replacement the last save or revert started, if it owed
    /// one — see ``RouteEditWorkout``. Kept so a suite can wait for it.
    @ObservationIgnored var workoutReplacement: Task<Void, Never>?

    @ObservationIgnored private weak var preview: RouteTrimPreview?
    @ObservationIgnored private(set) var isEnded = false
    /// Which load is the newest, so an older one landing late is dropped,
    /// and a rebuild that a load overtook with it.
    @ObservationIgnored private var loads = 0
    /// The rebuild under way, if any, and which one is the newest — see
    /// ``catchUp()``.
    @ObservationIgnored private var rebuilding: Task<Void, Never>?
    @ObservationIgnored private var rebuilds = 0
    /// Where each cut was last placed, and on which line: by the hike's own
    /// trim, or by hand. An answer moves a cut from here, never from where
    /// the answer before it left the cut, so changing an answer and changing
    /// it back puts the cut back where it was.
    @ObservationIgnored private var anchors: [RouteTrimHandle: (line: RouteTrimLine, meters: Double)] = [:]
    /// The ends the hike's own trim took something off when the visit
    /// opened, which is what a save tells a moved end from a kept one by —
    /// see ``EditedLine/ClockEnd``.
    @ObservationIgnored private(set) var cutWhenLoaded: Set<RouteTrimHandle> = []
    /// Whether the line the hike has, which is the one the map draws for it,
    /// is the whole line this visit opened on: nothing was cut off it before.
    @ObservationIgnored private var ownLineIsWhole = true

    var totalMeters: Double { line?.totalMeters ?? 0 }

    /// Whether either cut takes anything off the whole line.
    var isTrimmed: Bool { cuts(.start) || cuts(.end) }

    var keptRange: ClosedRange<Double> { startMeters...max(startMeters, endMeters) }

    /// The cuts as a save would store them: `nil` while neither takes
    /// anything off, which is no trim at all.
    var trim: ClosedRange<Double>? { isTrimmed ? keptRange : nil }

    /// The pieces of the line with the answers that stand now.
    var assembly: RouteAssembly? {
        guard var pieces = sources?.edit?.assembly else { return nil }
        pieces.checks = checks
        return pieces
    }

    /// Whether a save would change the hike: a cut moved, or an answer.
    var hasChanges: Bool {
        // Read before anything can return: the Save button asks this before
        // the line has loaded, and what it read then is all it is told of.
        // With nothing read, it never heard that there was a line, or that a
        // cut on it had moved.
        _ = lineRevision
        guard let sources, line != nil else { return false }
        return checks != (sources.edit?.assembly?.checks ?? [])
            || !Self.isSame(trim, sources.edit?.trim)
            || pausesTakenOff != (sources.edit?.endPausesTakenOff ?? [])
    }

    /// Whether the map has to draw the kept line itself, because the hike's
    /// own line on it is not that line: an earlier trim cut ground off that
    /// a handle can now be dragged back over, or the line is drawn under an
    /// answer changed in this visit.
    var drawsKeptLine: Bool {
        guard let sources, let line else { return false }
        return !ownLineIsWhole || line.choices != RouteTrimLine.choices(of: sources.edit?.assembly?.checks ?? [])
    }

    /// The ways `check` can be drawn on this device, in the order it offers
    /// them — see ``RouteEditSources/choices(of:)``.
    func choices(of check: RouteCheck) -> [RouteCheck.Choice] {
        sources?.choices(of: check) ?? check.availableChoices
    }

    private static func isSame(_ one: ClosedRange<Double>?, _ other: ClosedRange<Double>?) -> Bool {
        guard let one, let other else { return one == nil && other == nil }
        return abs(one.lowerBound - other.lowerBound) <= endToleranceMeters
            && abs(one.upperBound - other.upperBound) <= endToleranceMeters
    }

    // MARK: The line

    /// Starts over on `sources`: the whole line under the hike's answers,
    /// with the hike's trim as its cuts. The same sources again change
    /// nothing, so coming back to the screen keeps what was moved.
    func load(_ sources: RouteEditSources) async {
        guard sources.current.count > 1, sources != self.sources else { return }
        if sources.isMissingOriginal || sources.isMissingTrace {
            refusal = .notHereYet
            return
        }
        loads += 1
        let mine = loads
        let saved = sources.edit?.assembly
        guard let measured = try? await RouteTrimLine.measuring(sources, under: saved),
              !Task.isCancelled, mine == loads
        else { return }
        // Everything measured before anything is shown: the list draws each
        // answer's length the moment it has the answers.
        let lengths = await Self.lengths(in: sources)
        guard !Task.isCancelled, mine == loads else { return }
        (currentLengthMeters, choiceMeters) = lengths
        self.sources = sources
        checks = saved?.checks ?? []
        isOwedALook = sources.edit?.isOwedALook ?? false
        focusedCheckID = nil
        staleStretches = []
        ownLineIsWhole = measured.route == sources.current
        line = measured
        let stored = sources.edit?.trim
        startMeters = min(max(stored?.lowerBound ?? 0, 0), measured.totalMeters)
        endMeters = min(max(stored?.upperBound ?? measured.totalMeters, startMeters), measured.totalMeters)
        pausesTakenOff = sources.edit?.endPausesTakenOff ?? []
        anchors = [.start: (measured, startMeters), .end: (measured, endMeters)]
        cutWhenLoaded = Set([RouteTrimHandle.start, .end].filter { cuts($0) })
        lineRevision += 1
    }

    /// A hike with nothing but its line — see ``load(_:)``.
    func load(_ route: [RouteCoordinate]) async {
        await load(RouteEditSources(current: route))
    }

    // MARK: The cuts

    func position(of handle: RouteTrimHandle) -> Double {
        switch handle {
        case .start: startMeters
        case .end: endMeters
        }
    }

    /// Whether the cut at `handle` takes anything off: it has left its end
    /// of the line, or takes off the pause standing on it.
    func cuts(_ handle: RouteTrimHandle) -> Bool {
        if pausesTakenOff.contains(handle.endPause) { return true }
        return switch handle {
        case .start: startMeters > 0
        case .end: endMeters < totalMeters
        }
    }

    /// Moves one cut, held at least ``minimumKeptMeters`` short of the other
    /// and inside the line. A handle moved by hand stands where it was put,
    /// so it no longer takes off a pause on its end. A touch that leaves it
    /// where it was, as the chart's drag makes on the way down, moves
    /// nothing.
    func move(_ handle: RouteTrimHandle, to meters: Double) {
        let total = totalMeters
        guard total > 0, meters.isFinite else { return }
        let gap = min(Self.minimumKeptMeters, total)
        let before = position(of: handle)
        switch handle {
        case .start: startMeters = min(max(meters, 0), max(endMeters - gap, 0))
        case .end: endMeters = max(min(meters, total), min(startMeters + gap, total))
        }
        let moved = position(of: handle)
        guard moved != before else { return }
        if let line { anchors[handle] = (line, moved) }
        if pausesTakenOff.contains(handle.endPause) { pausesTakenOff.remove(handle.endPause) }
    }

    /// Cuts `stretch` off the end of the line `handle` stands on: what the
    /// offer under *Not on Foot* does — see ``RouteCarriedEnds``.
    ///
    /// A drive that ends the line paused, with only the fix it took up again
    /// on after it, has no length on the line, so its inner edge is the
    /// line's own end. The cut stands there, and takes off the pause.
    func takeOff(_ stretch: RouteCarriedEnds.Stretch, at handle: RouteTrimHandle) {
        let edge = Self.innerEdge(of: stretch, at: handle)
        move(handle, to: edge)
        let isOnTheEnd = switch handle {
        case .start: edge <= 0
        case .end: edge >= totalMeters
        }
        if isOnTheEnd { pausesTakenOff.insert(handle.endPause) }
    }

    /// Whether the cut at `handle` already takes `stretch` off: it stands at
    /// the stretch's inner edge or past it, and is a cut.
    func hasTakenOff(_ stretch: RouteCarriedEnds.Stretch, at handle: RouteTrimHandle) -> Bool {
        let edge = Self.innerEdge(of: stretch, at: handle)
        let isPast = switch handle {
        case .start: startMeters >= edge
        case .end: endMeters <= edge
        }
        return isPast && cuts(handle)
    }

    /// The edge of `stretch` the walk is on.
    private static func innerEdge(of stretch: RouteCarriedEnds.Stretch, at handle: RouteTrimHandle) -> Double {
        switch handle {
        case .start: stretch.range.upperBound
        case .end: stretch.range.lowerBound
        }
    }

    /// Slides one cut along the line towards where a finger is on the map.
    func move(_ handle: RouteTrimHandle, toward coordinate: CLLocationCoordinate2D) {
        guard let meters = line?.distance(nearest: coordinate, around: position(of: handle)) else { return }
        move(handle, to: meters)
    }

    // MARK: The stretches to check

    /// Picks a stretch out on the map, or none.
    func focus(onCheck id: Int?) {
        guard focusedCheckID != id else { return }
        focusedCheckID = id
    }

    /// Answers for a stretch. The answer stands at once; the whole line is
    /// put together again under it, and each cut goes back to the ground
    /// it was placed on — see ``anchors``.
    func choose(_ choice: RouteCheck.Choice, forCheck id: Int) async {
        guard line != nil, !isSaving,
              let index = checks.firstIndex(where: { $0.id == id }),
              checks[index].choice != choice,
              choices(of: checks[index]).contains(choice)
        else { return }
        checks[index].choice = choice
        focusedCheckID = id
        await catchUp()
    }

    /// Puts the line together again under ``checks``, after any rebuild
    /// already under way and never beside it. Each takes the answers as they
    /// stand when it begins, so one given while another is being drawn is
    /// not lost, and the last answer given is the one the line ends under.
    private func catchUp() async {
        rebuilds += 1
        let mine = rebuilds
        let previous = rebuilding
        let next = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await rebuildUnderChecks()
            // The newest lets ``settled()`` go; an older one leaves it
            // waiting on the newest.
            if rebuilds == mine { rebuilding = nil }
        }
        rebuilding = next
        await next.value
    }

    /// Waits until the line is drawn under every answer given: what Save and
    /// *Looks Good* do first.
    func settled() async {
        while let pending = rebuilding { await pending.value }
    }

    private func rebuildUnderChecks() async {
        guard let sources, let before = line, var pieces = sources.edit?.assembly else { return }
        pieces.checks = checks
        let wanted = RouteTrimLine.choices(of: pieces.checks)
        guard wanted != before.choices else { return }
        let loaded = loads
        guard let after = try? await RouteTrimLine.measuring(sources, under: pieces), loaded == loads else { return }
        staleStretches = Self.staleStretches(of: pieces, in: sources)
        line = after
        let start = anchors[.start].map { $0.line.meters(matching: $0.meters, on: after, for: .start) } ?? 0
        let end = anchors[.end].map { $0.line.meters(matching: $0.meters, on: after, for: .end) } ?? after.totalMeters
        startMeters = min(max(start, 0), after.totalMeters)
        endMeters = min(max(end, startMeters), after.totalMeters)
        lineRevision += 1
    }

    /// The length of the hike's line, and of every stretch under every
    /// answer it can take.
    @concurrent
    nonisolated private static func lengths(
        in sources: RouteEditSources
    ) async -> (current: Double, choices: [Int: [RouteCheck.Choice: Double]]) {
        var choices: [Int: [RouteCheck.Choice: Double]] = [:]
        for check in sources.edit?.assembly?.checks ?? [] {
            for choice in sources.choices(of: check) {
                let stretch = RouteAssembly.stretch(of: check, choosing: choice, saved: sources.saved, raw: sources.raw)
                choices[check.id, default: [:]][choice] = stretch.lengthMeters
            }
        }
        return (sources.current.lengthMeters, choices)
    }

    /// Each stretch whose answer differs from the hike's, as the hike's own
    /// line draws it. A handful of stretches, each a slice.
    private static func staleStretches(
        of assembly: RouteAssembly,
        in sources: RouteEditSources
    ) -> [[CLLocationCoordinate2D]] {
        let stored = sources.edit?.assembly?.checks ?? []
        return assembly.checks.compactMap { check in
            guard let before = stored.first(where: { $0.id == check.id }), before.choice != check.choice else {
                return nil
            }
            return RouteAssembly.stretch(of: before, saved: sources.saved, raw: sources.raw).map(\.clCoordinate)
        }
    }

    /// Takes `looked` as what the visit works from, where the hike's edit
    /// record has changed under it and its line has not: the stretches'
    /// looks, kept on the answers that stand in this visit.
    func adopt(_ looked: RouteEditSources) {
        guard looked.current == sources?.current else { return }
        let stored = looked.edit?.assembly?.checks ?? []
        sources = looked
        isOwedALook = looked.edit?.isOwedALook ?? false
        checks = checks.map { check in
            var merged = check
            if let saved = stored.first(where: { $0.id == check.id }) { merged.isChecked = saved.isChecked }
            return merged
        }
    }

    // MARK: Saving

    /// The line the cuts and the answers leave, measured for a save — see
    /// ``EditedLine``. `nil` while nothing has changed. Waits for the line
    /// to be drawn under every answer given first.
    func editedLine() async -> EditedLine? {
        await settled()
        // A line drawn under other answers than the ones it would be saved
        // with is no line to keep.
        guard let line, let sources, hasChanges, line.choices == RouteTrimLine.choices(of: checks) else { return nil }
        var pieces = assembly
        // A save is a look: the hiker has had every stretch in front of them.
        for index in (pieces?.checks ?? []).indices { pieces?.checks[index].isChecked = true }
        let cuts = EditedLine.Cuts(range: trim, takingOff: pausesTakenOff)
        return await Self.edited(
            line,
            cuts: cuts,
            assembly: pieces,
            replacing: sources.current,
            cutBefore: cutWhenLoaded
        )
    }

    @concurrent
    nonisolated private static func edited(
        _ line: RouteTrimLine,
        cuts: EditedLine.Cuts,
        assembly: RouteAssembly?,
        replacing current: [RouteCoordinate],
        cutBefore: Set<RouteTrimHandle>
    ) async -> EditedLine? {
        EditedLine(
            whole: line.route,
            distances: line.distances,
            cuts: cuts,
            replacing: current,
            cutBefore: cutBefore,
            assembly: assembly
        )
    }

    /// Where the cut at `handle` stands on the map, or `nil` with no line.
    func spot(of handle: RouteTrimHandle) -> RouteTrimLine.Spot? {
        guard let line else { return nil }
        let takesOffPause = pausesTakenOff.contains(handle.endPause)
        return switch handle {
        case .start: line.startSpot(at: startMeters, takingOffPause: takesOffPause)
        case .end: line.endSpot(at: endMeters, takingOffPause: takesOffPause)
        }
    }

    /// The clock at the cut at `handle`, or `nil` where the line has none.
    func timestamp(of handle: RouteTrimHandle) -> Date? {
        line?.timestamp(
            of: handle,
            at: position(of: handle),
            takingOffPause: pausesTakenOff.contains(handle.endPause)
        )
    }

    // MARK: The map

    /// Puts the cuts on the map. An ended session is never shown again: the
    /// pop that ended it builds its screen once more on the way out.
    func show(on preview: RouteTrimPreview) {
        guard !isEnded else { return }
        self.preview = preview
        preview.present(self)
    }

    /// Takes the cuts off the map, for good — see the file header.
    func end() {
        isEnded = true
        preview?.withdraw(self)
    }
}

/// The trim the map draws, if a screen has one up: held in a reference type
/// for the reason ``WalkHighlight`` is, so the map observes it directly and
/// no SwiftUI view re-renders for a handle that moved.
@Observable
final class RouteTrimPreview {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    private(set) var session: RouteTrimSession?

    /// Called by ``RouteTrimSession/show(on:)`` and nothing else.
    func present(_ session: RouteTrimSession) {
        guard self.session !== session else { return }
        self.session = session
    }

    /// Called by ``RouteTrimSession/end()`` and nothing else.
    func withdraw(_ session: RouteTrimSession) {
        guard self.session === session else { return }
        self.session = nil
    }
}
