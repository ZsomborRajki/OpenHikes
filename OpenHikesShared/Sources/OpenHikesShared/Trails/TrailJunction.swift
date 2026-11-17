//
//  TrailJunction.swift
//  OpenHikesShared
//
//  A place on a trail where another trail meets it, and which way the trail
//  goes on from there.
//
//  The phone finds them, because the trail graph is the phone's: where the
//  line passes a node OpenStreetMap joins three or more trails at, it reads
//  the way the line comes in, the way it leaves and the ways it does not
//  take (`TrailJunctionFinder`). What crosses to the watch and what the
//  phone's own guide keeps is only the answer: how far along the line the
//  junction is, and what to say about it walking either way.
//
//  ## Both ways
//
//  A trail is walked in whichever direction the hiker chooses, and the same
//  fork is a *keep left* one way and a *turn sharp right* the other. So a
//  junction carries both, worked out once from the same geometry, and the
//  walk's direction picks between them. A direction the junction asks
//  nothing of — the line goes straight on and every other way leaves at a
//  wide angle — is `nil`, and nothing is said there.
//

import Foundation

/// Which way a hiker is walking a line: from its first point to its last,
/// or back.
public enum RouteTravelDirection: String, Codable, Sendable, Hashable, CaseIterable {
    case towardsEnd = "towardsEnd"
    case towardsStart = "towardsStart"
}

/// What a hiker has to do at a junction to stay on the trail.
///
/// Raw values are a wire format: they cross to the watch inside
/// ``WatchTrailPackage``.
public enum JunctionManeuver: String, Codable, Sendable, Hashable, CaseIterable {
    /// Two or more ways go on ahead, and the trail is the leftmost.
    case keepLeft = "keepLeft"
    /// Two or more ways go on ahead, and the trail is the rightmost.
    case keepRight = "keepRight"
    case sharpLeft = "sharpLeft"
    case sharpRight = "sharpRight"
    /// The trail goes straight on between ways that leave close to it.
    case straight = "straight"
    case turnLeft = "turnLeft"
    case turnRight = "turnRight"

    /// Whether the trail goes to the hiker's left, right or neither, for a
    /// glyph or a haptic that only has a side to say.
    public var side: Side {
        switch self {
        case .keepLeft, .turnLeft, .sharpLeft: .left
        case .keepRight, .turnRight, .sharpRight: .right
        case .straight: .ahead
        }
    }

    public enum Side: Sendable, Hashable {
        case ahead, left, right
    }

    /// The SF Symbol drawn beside the words, on the phone and the watch. Each
    /// is in SF Symbols 2, so older than either deployment floor.
    public var symbolName: String {
        switch self {
        case .keepLeft: "arrow.up.left"
        case .keepRight: "arrow.up.right"
        case .turnLeft, .sharpLeft: "arrow.turn.up.left"
        case .turnRight, .sharpRight: "arrow.turn.up.right"
        case .straight: "arrow.up"
        }
    }
}

/// One junction along a line.
public struct TrailJunction: Codable, Sendable, Equatable, Hashable {
    /// How far along the line the junction is, on the scale the line is
    /// measured on where this is read — see
    /// ``WatchTrailPackage/junctions`` for the watch's.
    public var distanceMeters: Double
    /// What to do there walking towards the line's last point, or `nil` when
    /// there is nothing to say.
    public var towardsEnd: JunctionManeuver?
    /// What to do there walking towards its first point, or `nil`.
    public var towardsStart: JunctionManeuver?

    public init(
        distanceMeters: Double,
        towardsEnd: JunctionManeuver?,
        towardsStart: JunctionManeuver?
    ) {
        self.distanceMeters = distanceMeters
        self.towardsEnd = towardsEnd
        self.towardsStart = towardsStart
    }

    /// What to do here walking `direction`.
    public func maneuver(traveling direction: RouteTravelDirection) -> JunctionManeuver? {
        switch direction {
        case .towardsEnd: towardsEnd
        case .towardsStart: towardsStart
        }
    }
}
