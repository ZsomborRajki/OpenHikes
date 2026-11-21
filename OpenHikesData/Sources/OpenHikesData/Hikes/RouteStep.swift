//
//  RouteStep.swift
//  OpenHikes
//
//  What *Edit Route* does to a line beyond cutting its ends and answering for
//  its sections: a stretch drawn along another path, straightened or taken
//  out, and the whole line turned round, started somewhere else, closed or
//  doubled back.
//
//  ## Steps, in the order they were made
//
//  The hike's line is derived, never patched: the line as it was saved, put
//  together under the answers that stand (``RouteAssembly``), then each step
//  here in turn, then the two cuts. So a step is undone by leaving it out,
//  the last one first, on any of the hiker's devices, and *Revert to
//  Original* is leaving all of them out.
//
//  A step says where it works in metres along the line as it stood when the
//  step was made, which is the line every step before it left. That is why
//  they are a list and not a set, and why a cut the hiker had placed is kept
//  as a step of its own (``RouteStep/trim(_:endPauses:)``) once another step
//  is made on what it left.
//
//  ## A guess says it is one
//
//  A stretch drawn where nobody recorded the hiker walking is marked
//  ``RouteProvenance/inferred`` and carries no times: a rerouted stretch, a
//  straightened one, the way a loop is closed and the way back of an out and
//  back. The points either side keep theirs. A line turned round or started
//  somewhere else keeps its ground and loses its clock, because times that
//  run backwards along a line are nobody's.
//
//  ## The clock a step leaves
//
//  A stretch drawn along other ground was still walked, and for as long as
//  it was: the recorded time across it (``RouteTrim/recordedSeconds(of:)``)
//  is what it was before, a pause inside it included. A pause the new way
//  draws over stays with the line as a pause of the same length, standing
//  where the stretch begins, so the walk's active time and its segments are
//  what they were. A stretch taken out loses its time, as a cut does.
//
//  A line that has lost its clock still had one when the steps before began,
//  so ``RouteSteps/Applied/recordedSeconds`` carries the figure through a
//  step that clears it: the same steps give the same figure whichever of
//  them were saved first.
//
//  ## A step that changes nothing
//
//  A step that does not fit the line leaves it as it was — its distances lie
//  outside it, it would leave less than a line, or a line whose ends already
//  meet is asked to come back again — and so does one that would grow it
//  past twice its points and the paths the steps may carry
//  (``RouteSteps/maximumPoints(from:)``): a line doubled back, cut and
//  doubled back again would otherwise double with every pair.
//
//  ## What travels
//
//  Only a path drawn along other ground has points of its own to keep, and
//  those are kept small — a latitude and a longitude a point, see
//  ``RoutePath`` — and few (``RouteSteps/maximumPathCoordinates``), because
//  they travel in a field of the hike's record beside ``RouteAssembly``.
//

import CoreLocation
import Foundation

/// Ground a step draws that the line did not have: a way round, or the way
/// a loop is closed.
nonisolated public struct RoutePath: Codable, Equatable, Sendable {
    /// Latitude then longitude, a pair a point, to about a decimetre.
    public var flat: [Double]

    /// Nothing between the two ends: a straight line.
    public static let straight = Self(flat: [])

    public init(flat: [Double]) {
        self.flat = flat
    }

    public init(_ coordinates: [CLLocationCoordinate2D]) {
        flat = coordinates.flatMap { [Self.rounded($0.latitude), Self.rounded($0.longitude)] }
    }

    private static let precision = 1_000_000.0
    private static let pair = 2

    private static func rounded(_ degrees: Double) -> Double {
        (degrees * precision).rounded() / precision
    }

    public var count: Int { flat.count / Self.pair }

    /// The path as points of a line: inferred, with no height and no time.
    public var points: [RouteCoordinate] {
        (0..<count).map { index in
            RouteCoordinate(
                latitude: flat[index * Self.pair],
                longitude: flat[index * Self.pair + 1],
                provenance: .inferred
            )
        }
    }
}

/// One change to a line — see the file header.
nonisolated public enum RouteStep: Codable, Equatable, Sendable {
    /// Both ends joined: the path from the line's end back to its start.
    case closeLoop(RoutePath)
    /// The line, and then the same way back.
    case outAndBack
    /// The stretch taken out, as a pause is: no distance, and no trail.
    case pause(ClosedRange<Double>)
    /// The stretch drawn along `with` instead.
    case replace(ClosedRange<Double>, with: RoutePath)
    /// The line the other way round.
    case reverse
    /// A loop begun at this distance along it instead.
    case startAt(Double)
    /// The two cuts the hiker had placed when the next step was made, with
    /// ``RouteTrim/EndPauses`` as its raw value.
    case trim(ClosedRange<Double>, endPauses: Int)

    /// How many points of its own the step carries.
    public var pathCoordinateCount: Int {
        switch self {
        case let .closeLoop(path), let .replace(_, path): path.count
        case .outAndBack, .pause, .reverse, .startAt, .trim: 0
        }
    }

    /// Whether the line keeps its times through the step, so what the step
    /// does to the recorded time can be read off the line it leaves.
    var keepsClock: Bool {
        switch self {
        case .reverse, .startAt: false
        case .closeLoop, .outAndBack, .pause, .replace, .trim: true
        }
    }
}

nonisolated public enum RouteSteps {
    /// How many points the paths of one hike's steps may carry between them.
    /// About twenty bytes a point, in a record whose fields have to add up to
    /// less than a megabyte.
    public static let maximumPathCoordinates = 6000

    /// A line with its steps applied.
    public struct Applied: Equatable, Sendable {
        public let route: [RouteCoordinate]
        /// Whether a step took something off the line's start, or put the
        /// start somewhere else: the hike no longer begins where and when the
        /// line it was made from did.
        public let movesStart: Bool
        /// The same of its end.
        public let movesEnd: Bool
        /// How long the line was being recorded, by
        /// ``RouteTrim/recordedSeconds(of:)``, carried through the steps that
        /// take its clock away — see *The clock a step leaves* in the file
        /// header. The line's own figure while every step kept its times.
        public let recordedSeconds: TimeInterval
        /// Whether the last step changed the line: one that did not fit it
        /// is kept with nothing done, and is no step to make.
        public let lastStepChangedLine: Bool
    }

    public static func pathCoordinateCount(of steps: [RouteStep]) -> Int {
        steps.reduce(0) { $0 + $1.pathCoordinateCount }
    }

    /// The most points the steps may leave a line of `count` points with:
    /// doubled back once, and every path they may carry.
    public static func maximumPoints(from count: Int) -> Int {
        count * 2 + maximumPathCoordinates
    }

    /// `line` with every step applied, in order.
    public static func applying(_ steps: [RouteStep], to line: [RouteCoordinate]) -> Applied {
        var route = line
        var movesStart = false
        var movesEnd = false
        var clock = RouteTrim.recordedSeconds(of: line)
        var recorded = clock
        var lastStepChangedLine = false
        let limit = maximumPoints(from: line.count)
        for step in steps {
            let before = route
            let after = applying(step, to: before)
            lastStepChangedLine = after != before && after.count <= limit
            guard lastStepChangedLine else { continue }
            route = after
            let recordedNow = RouteTrim.recordedSeconds(of: after)
            if step.keepsClock { recorded += recordedNow - clock }
            clock = recordedNow
            switch step {
            case .closeLoop, .outAndBack:
                movesEnd = true
            case .reverse, .startAt:
                // The line now begins and ends at other points than it did.
                movesStart = true
                movesEnd = true
            case .pause, .replace, .trim:
                if route.first != before.first { movesStart = true }
                if route.last != before.last { movesEnd = true }
            }
        }
        return Applied(
            route: route,
            movesStart: movesStart,
            movesEnd: movesEnd,
            recordedSeconds: recorded,
            lastStepChangedLine: lastStepChangedLine
        )
    }

    /// `line` with one step applied. A step that does not fit the line — see
    /// *A step that changes nothing* in the file header — leaves the line as
    /// it was: a step kept with a hike must never be what loses the hike its
    /// line.
    public static func applying(_ step: RouteStep, to line: [RouteCoordinate]) -> [RouteCoordinate] {
        guard line.count > 1 else { return line }
        let result: [RouteCoordinate]
        switch step {
        case let .closeLoop(path): result = closed(line, along: path)
        case .outAndBack: result = endsMeet(line) ? line : line + returning(line).dropFirst()
        case let .pause(range): result = paused(line, across: range)
        case let .replace(range, path): result = replaced(line, across: range, with: path)
        case .reverse: result = withoutTimes(turned(line))
        case let .startAt(meters): result = rotated(line, to: meters)
        case let .trim(range, endPauses):
            result = RouteTrim.trimmed(line, keeping: range, takingOff: RouteTrim.EndPauses(rawValue: endPauses))
        }
        return result.count > 1 && result.lengthMeters > 0 ? result : line
    }

    // MARK: A stretch

    /// The line either side of a stretch.
    private struct Sides {
        /// Up to where the stretch begins: the line's own first point alone
        /// where the stretch reaches the start.
        var head: [RouteCoordinate]
        /// On from where it ends: the line's own last point alone where the
        /// stretch reaches the end.
        var tail: [RouteCoordinate]
        var reachesStart: Bool
        var reachesEnd: Bool
    }

    private static func sides(of line: [RouteCoordinate], around range: ClosedRange<Double>) -> Sides? {
        let distances = RouteTrim.distances(along: line)
        guard let total = distances.last, let first = line.first, let last = line.last else { return nil }
        let lower = max(range.lowerBound, 0)
        let upper = min(range.upperBound, total)
        guard upper > lower else { return nil }
        let head = lower > 0 ? RouteTrim.trimmed(line, distances: distances, keeping: 0...lower) : [first]
        let tail = upper < total ? RouteTrim.trimmed(line, distances: distances, keeping: upper...total) : [last]
        guard !head.isEmpty, !tail.isEmpty else { return nil }
        return Sides(head: head, tail: tail, reachesStart: lower <= 0, reachesEnd: upper >= total)
    }

    private static func replaced(
        _ line: [RouteCoordinate],
        across range: ClosedRange<Double>,
        with path: RoutePath
    ) -> [RouteCoordinate] {
        guard var sides = sides(of: line, around: range) else { return line }
        // The leg that arrives where the line takes up again is the last of
        // the guess, and says so on the point it arrives at.
        sides.tail[0].provenance = .inferred
        sides.tail[0].boundary = nil
        let way = between(path.points, after: sides.head.last, before: sides.tail.first)
        let drawn = sides.head + way + sides.tail
        // The time the stretch stood paused, which its new ground has no
        // pause to leave out — see *The clock a step leaves* in the file
        // header.
        let paused = RouteTrim.recordedSeconds(of: drawn) - RouteTrim.recordedSeconds(of: line)
        guard paused > 0, let stop = pause(lasting: paused, after: sides.head) else { return drawn }
        return sides.head + [stop] + way + sides.tail
    }

    /// A pause of `seconds` on the spot where `head` ends: a leg of no
    /// length from its last point, stamped that long after the last time
    /// `head` has. `nil` for a head with no time to count from.
    private static func pause(lasting seconds: TimeInterval, after head: [RouteCoordinate]) -> RouteCoordinate? {
        guard let spot = head.last, let began = head.last(where: { $0.timestamp != nil })?.timestamp else {
            return nil
        }
        return RouteCoordinate(
            latitude: spot.latitude,
            longitude: spot.longitude,
            elevation: spot.elevation,
            timestamp: began.addingTimeInterval(seconds),
            boundary: .paused
        )
    }

    /// Whether `line` already ends where it began, near enough to have come
    /// back (``RouteShape/closingToleranceMeters``): doubling it back would
    /// walk the whole of it again to arrive where it is.
    public static func endsMeet(_ line: [RouteCoordinate]) -> Bool {
        guard let first = line.first, let last = line.last else { return false }
        return endsMeet(first.clCoordinate, last.clCoordinate)
    }

    /// The same, of a line's two ends.
    public static func endsMeet(_ start: CLLocationCoordinate2D, _ end: CLLocationCoordinate2D) -> Bool {
        RouteGeometry.distanceMeters(from: start, to: end) <= RouteShape.closingToleranceMeters
    }

    private static func paused(_ line: [RouteCoordinate], across range: ClosedRange<Double>) -> [RouteCoordinate] {
        guard var sides = sides(of: line, around: range) else { return line }
        // A stretch that reaches an end leaves nothing either side of the
        // pause to pause between: it is a cut.
        if sides.reachesStart { return sides.tail }
        if sides.reachesEnd { return sides.head }
        sides.tail[0].boundary = .paused
        sides.tail[0].provenance = nil
        return sides.head + sides.tail
    }

    /// A path's points without the ones that are the line's own either side
    /// of it: a router answers from one end to the other, ends included.
    private static func between(
        _ points: [RouteCoordinate],
        after first: RouteCoordinate?,
        before last: RouteCoordinate?
    ) -> ArraySlice<RouteCoordinate> {
        var kept = points[...]
        if let first, let start = kept.first, isSameSpot(first, start) { kept = kept.dropFirst() }
        if let last, let end = kept.last, isSameSpot(last, end) { kept = kept.dropLast() }
        return kept
    }

    private static func isSameSpot(_ one: RouteCoordinate, _ other: RouteCoordinate) -> Bool {
        RouteGeometry.distanceMeters(from: one.clCoordinate, to: other.clCoordinate) <= RouteAssembly.joinMeters
    }

    // MARK: The whole line

    /// The line the other way round. What a point says of the leg arriving
    /// at it — a pause, a guess — goes to the point at that leg's other end,
    /// which is where it arrives now.
    private static func turned(_ line: [RouteCoordinate]) -> [RouteCoordinate] {
        let last = line.count - 1
        return line.indices.map { index in
            var point = line[last - index]
            point.boundary = index == 0 ? nil : line[last - index + 1].boundary
            point.provenance = index == 0 ? nil : line[last - index + 1].provenance
            return point
        }
    }

    private static func withoutTimes(_ line: [RouteCoordinate]) -> [RouteCoordinate] {
        line.map { point in
            var plain = point
            plain.timestamp = nil
            return plain
        }
    }

    /// The way back along `line`: nobody recorded it being walked.
    private static func returning(_ line: [RouteCoordinate]) -> [RouteCoordinate] {
        withoutTimes(turned(line)).enumerated().map { index, point in
            var back = point
            // A pause on the way out is a pause on the way back.
            if index > 0, !back.isPauseBoundary { back.provenance = .inferred }
            return back
        }
    }

    private static func closed(_ line: [RouteCoordinate], along path: RoutePath) -> [RouteCoordinate] {
        guard let first = line.first, let last = line.last, !isSameSpot(first, last) else { return line }
        var home = RouteCoordinate(latitude: first.latitude, longitude: first.longitude, elevation: first.elevation)
        home.provenance = .inferred
        return line + between(path.points, after: last, before: home) + [home]
    }

    private static func rotated(_ line: [RouteCoordinate], to meters: Double) -> [RouteCoordinate] {
        let distances = RouteTrim.distances(along: line)
        guard let total = distances.last, meters > 0, meters < total else { return line }
        let onward = RouteTrim.trimmed(line, distances: distances, keeping: meters...total)
        var round = RouteTrim.trimmed(line, distances: distances, keeping: 0...meters)
        guard let seam = onward.last, let begun = round.first else { return line }
        if isSameSpot(seam, begun) {
            round.removeFirst()
        } else {
            // The gap a loop leaves between its two ends is ground nobody
            // recorded, and it is now in the middle of the line.
            round[0].provenance = .inferred
            round[0].boundary = nil
        }
        return withoutTimes(onward + round)
    }
}
