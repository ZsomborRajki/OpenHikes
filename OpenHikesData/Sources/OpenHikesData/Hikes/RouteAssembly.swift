//
//  RouteAssembly.swift
//  OpenHikes
//
//  What a saved recording's line was put together from: the stretches trail
//  matching moved, bridged or could not decide, each with the other ways it
//  could be drawn, and the stretches between them it left alone.
//
//  ## Why a saved hike keeps this
//
//  A recording the matcher had touched used to stop before it was saved,
//  until the hiker had answered for every such stretch. Stop now saves at
//  once, with each stretch drawn the way that needs no answer (see
//  ``RouteCheck/savedChoice``), and the question is kept with the hike for
//  *Edit Route* to ask whenever the hiker looks. So the answer has to be
//  changeable on a line that is already saved, on any of the hiker's
//  devices, and that takes knowing which points of the line each stretch is.
//
//  ## Rebuilt, never patched
//
//  ``line(saved:raw:)`` puts the whole line together again from its pieces
//  under whatever choices stand now, exactly as the matcher's own result is
//  resolved at Stop: piece after piece, a point two pieces share written
//  once. Nothing is cut out of a line and spliced, so changing an answer and
//  changing it back gives the line there was.
//
//  ## Where the other ways are kept
//
//  Not here, where they would be most of a long hike over again. A stretch
//  as it was saved is in the line as it was saved, and the recorded fixes
//  are the hike's ``Hike/rawRoute``: a stretch names its points in each by
//  index. Only the routes offered across an ambiguous stretch exist nowhere
//  else, and those are short, few and bounded
//  (``maximumAlternativeCoordinates``), because this travels in a field of
//  the hike's record and not as an asset.
//
//  ## A trace that has not come yet
//
//  Both lines are assets, and iCloud can bring the hike before the trace. A
//  stretch drawn as its fixes then has nothing to be drawn from, and drawing
//  it as it was saved instead would put the old line back under the new
//  answer, for the next save to keep. So an answer is drawn only where
//  ``canDraw(_:of:raw:)`` says it can be, and a line whose answers cannot
//  all be (``isDrawable(raw:)``) is not edited until they can.
//

import CoreLocation
import Foundation

/// One stretch of a saved recording the hiker can still answer for.
nonisolated public struct RouteCheck: Codable, Equatable, Identifiable, Sendable {
    /// Why the stretch is one to check.
    public enum Kind: String, Codable, Sendable {
        /// More than one mapped route fits the fixes either side.
        case ambiguous = "ambiguous"
        /// The recording lost its fixes across it.
        case gap = "gap"
        /// Matching moved the line onto a mapped trail, and is confident of it.
        case snapped = "snapped"
    }

    /// A way of drawing the stretch.
    public enum Choice: Codable, Hashable, Sendable {
        /// One of ``RouteCheck/alternatives``, by its id.
        case alternative(Int)
        /// The recorded fixes and nothing else: across a gap, a straight line.
        case gps
        /// The mapped trail the matcher found.
        case matched
    }

    /// A mapped route across an ambiguous stretch.
    public struct Alternative: Codable, Equatable, Identifiable, Sendable {
        public var id: Int
        public var points: [RouteCoordinate]
        /// The trails it follows, where they have names.
        public var trailNames: [String]

        public init(id: Int, points: [RouteCoordinate], trailNames: [String] = []) {
            self.id = id
            self.points = points
            self.trailNames = trailNames
        }
    }

    public var id: Int
    public var kind: Kind
    /// The trail the stretch was matched to, where it has a name.
    public var trailName: String?
    /// How long the recording went without a fix across it, for a gap.
    public var unobservedSeconds: Double?
    /// Whether a mapped route was found across a gap. `true` for a stretch
    /// that is not one.
    public var isBridged: Bool
    /// How the stretch was drawn when the hike was saved: the answer that
    /// needs no asking. An ambiguous stretch keeps the measurement, a
    /// confident one the trail, and a gap the mapped route where there is
    /// one.
    public var savedChoice: Choice
    /// The stretch's points in the line as it was saved.
    public var savedRange: ClosedRange<Int>
    /// The fixes it spans in the recorded trace.
    public var rawRange: ClosedRange<Int>
    public var alternatives: [Alternative]
    /// How the stretch is drawn now.
    public var choice: Choice
    /// Whether the hiker has looked: answered for it, or said the line is
    /// right as it is.
    public var isChecked: Bool

    public init(
        id: Int,
        kind: Kind,
        savedChoice: Choice,
        savedRange: ClosedRange<Int>,
        rawRange: ClosedRange<Int>,
        trailName: String? = nil,
        unobservedSeconds: Double? = nil,
        isBridged: Bool = true,
        alternatives: [Alternative] = []
    ) {
        self.id = id
        self.kind = kind
        self.trailName = trailName
        self.unobservedSeconds = unobservedSeconds
        self.isBridged = isBridged
        self.savedChoice = savedChoice
        self.savedRange = savedRange
        self.rawRange = rawRange
        self.alternatives = alternatives
        choice = savedChoice
        isChecked = false
    }

    /// Every way the stretch can be drawn, in the order it is offered. A gap
    /// no mapped route crosses has one, which makes it a notice and not a
    /// question.
    public var availableChoices: [Choice] {
        switch kind {
        case .snapped: [.matched, .gps]
        case .ambiguous: [.gps] + alternatives.map { .alternative($0.id) }
        case .gap: isBridged ? [.matched, .gps] : [.gps]
        }
    }

    /// Whether there is anything to choose between.
    public var isQuestion: Bool { availableChoices.count > 1 }
}

nonisolated public struct RouteAssembly: Codable, Equatable, Sendable {
    /// One piece of the line, in order.
    public enum Piece: Codable, Equatable, Sendable {
        /// A ``RouteCheck``, by its id.
        case check(Int)
        /// Points of the line as it was saved that no check covers.
        case kept(ClosedRange<Int>)
    }

    /// The line rebuilt under the choices that stand.
    public struct Line: Equatable, Sendable {
        public let route: [RouteCoordinate]
        /// Where each check's stretch is in ``route``, by its id.
        public let checkRanges: [Int: ClosedRange<Int>]
        /// Where each of the assembly's ``RouteAssembly/pieces`` is in
        /// ``route``, in their order, or `nil` for one that drew nothing.
        /// Two pieces either share a point, or are joined by a leg of their
        /// own that neither piece holds.
        public let pieceRanges: [ClosedRange<Int>?]

        public init(
            route: [RouteCoordinate],
            checkRanges: [Int: ClosedRange<Int>] = [:],
            pieceRanges: [ClosedRange<Int>?] = []
        ) {
            self.route = route
            self.checkRanges = checkRanges
            self.pieceRanges = pieceRanges
        }
    }

    /// How many points the alternatives of one assembly may carry between
    /// them. About a hundred bytes a point as JSON, in a record whose fields
    /// have to add up to less than a megabyte.
    public static let maximumAlternativeCoordinates = 1500

    /// How near two pieces' meeting points have to be to be one point: the
    /// matcher's own rule for joining its legs.
    public static let joinMeters = 0.05

    public var pieces: [Piece]
    public var checks: [RouteCheck]

    public init(pieces: [Piece], checks: [RouteCheck]) {
        self.pieces = pieces
        self.checks = checks
    }

    /// How many stretches the hiker has not looked at yet.
    public var uncheckedCount: Int { checks.count { !$0.isChecked } }

    /// Whether every stretch is drawn the way it was saved.
    public var isAsSaved: Bool { checks.allSatisfy { $0.choice == $0.savedChoice } }

    /// Every stretch back to the way it was saved, the hiker's looks kept.
    public var asSaved: Self {
        var reset = self
        for index in reset.checks.indices { reset.checks[index].choice = reset.checks[index].savedChoice }
        return reset
    }

    /// Whether every stretch can be drawn the way it is answered from `raw`
    /// — see ``canDraw(_:of:raw:)``.
    public func isDrawable(raw: [RouteCoordinate]) -> Bool {
        checks.allSatisfy { Self.canDraw($0.choice, of: $0, raw: raw) }
    }

    /// Whether `check` can be drawn under `choice` from the recorded trace
    /// `raw`: as it was saved, always; as one of its alternatives, which
    /// travel with it; as its fixes only where `raw` holds them — see the
    /// file header.
    ///
    /// A hike that kept no trace kept none because its saved line never left
    /// it, so no stretch of it was saved as anything but its fixes, and
    /// drawing one as its fixes is drawing it as it was saved.
    public static func canDraw(_ choice: RouteCheck.Choice, of check: RouteCheck, raw: [RouteCoordinate]) -> Bool {
        guard choice != check.savedChoice else { return true }
        switch choice {
        case .matched:
            // Only ever the saved choice: a stretch saved as its fixes has
            // no mapped trail kept for it.
            return false
        case .alternative(let id):
            return check.alternatives.contains { $0.id == id && !$0.points.isEmpty }
        case .gps:
            return check.rawRange.lowerBound >= 0 && check.rawRange.upperBound < raw.count
        }
    }

    /// The line under the choices that stand — see the file header.
    ///
    /// A stretch that cannot be drawn under its choice (see
    /// ``canDraw(_:of:raw:)``) keeps the points it was saved with, so the
    /// line is never shorter than it was; a caller about to keep the line
    /// asks ``isDrawable(raw:)`` first.
    ///
    /// - Parameters:
    ///   - saved: The line as it was saved at Stop.
    ///   - raw: The recorded trace, or nothing where the hike kept none
    ///     because its saved line never left it.
    public func line(saved: [RouteCoordinate], raw: [RouteCoordinate]) -> Line {
        var route: [RouteCoordinate] = []
        route.reserveCapacity(saved.count)
        var ranges: [Int: ClosedRange<Int>] = [:]
        var pieceRanges: [ClosedRange<Int>?] = []
        let checksByID = Dictionary(checks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for piece in pieces {
            let points: [RouteCoordinate] = switch piece {
            case .kept(let range): Self.slice(saved, range)
            case .check(let id): checksByID[id].map { Self.stretch(of: $0, saved: saved, raw: raw) } ?? []
            }
            let drawn = Self.append(points, to: &route).map { $0...(route.count - 1) }
            pieceRanges.append(drawn)
            if case .check(let id) = piece, let drawn { ranges[id] = drawn }
        }
        return Line(route: route, checkRanges: ranges, pieceRanges: pieceRanges)
    }

    /// The points one check's stretch is drawn with under the choice it has.
    public static func stretch(
        of check: RouteCheck,
        saved: [RouteCoordinate],
        raw: [RouteCoordinate]
    ) -> [RouteCoordinate] {
        stretch(of: check, choosing: check.choice, saved: saved, raw: raw)
    }

    /// The points one check's stretch would be drawn with under `choice`.
    public static func stretch(
        of check: RouteCheck,
        choosing choice: RouteCheck.Choice,
        saved: [RouteCoordinate],
        raw: [RouteCoordinate]
    ) -> [RouteCoordinate] {
        let savedStretch = slice(saved, check.savedRange)
        guard choice != check.savedChoice, canDraw(choice, of: check, raw: raw) else { return savedStretch }
        switch choice {
        case .matched:
            return savedStretch
        case .alternative(let id):
            return check.alternatives.first { $0.id == id }?.points ?? savedStretch
        case .gps:
            var fixes = slice(raw, check.rawRange)
            guard !fixes.isEmpty else { return savedStretch }
            // A straight line across ground nobody observed is no measurement
            // whichever way it was chosen, so it says so on the point it
            // arrives at — see ``RouteProvenance``.
            if check.kind == .gap, fixes.count > 1 { fixes[fixes.count - 1].provenance = .inferred }
            return fixes
        }
    }

    private static func slice(_ points: [RouteCoordinate], _ range: ClosedRange<Int>) -> [RouteCoordinate] {
        guard range.lowerBound >= 0, range.upperBound < points.count else { return [] }
        return Array(points[range])
    }

    /// Appends `stretch`, writing a point it shares with the line's end once.
    ///
    /// - Returns: where the stretch begins in `route`, or `nil` for one with
    ///   no points.
    @discardableResult private static func append(
        _ stretch: [RouteCoordinate],
        to route: inout [RouteCoordinate]
    ) -> Int? {
        guard let first = stretch.first else { return nil }
        guard let last = route.last,
              RouteGeometry.distanceMeters(from: last.clCoordinate, to: first.clCoordinate) <= joinMeters
        else {
            route.append(contentsOf: stretch)
            return route.count - stretch.count
        }
        route.append(contentsOf: stretch.dropFirst())
        return route.count - stretch.count
    }
}
