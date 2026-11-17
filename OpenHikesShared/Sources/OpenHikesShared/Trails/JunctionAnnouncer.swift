//
//  JunctionAnnouncer.swift
//  OpenHikesShared
//
//  When to say what about the next junction, given where along the trail the
//  hiker now is.
//
//  The phone speaks and the watch taps, and both ask this, so a hiker with
//  both hears and feels the same junction at the same distance. Neither has
//  a test bundle that could hold the rule otherwise: the watch has none at
//  all, and the phone's speech cannot be listened to by a suite.
//
//  ## Two cues a junction
//
//  The first comes when the junction is ``aheadMeters`` off, and says how
//  far: time to look up and find the turn. The second comes at
//  ``imminentMeters``, which is a few steps, and says only what to do. A
//  hiker first placed closer than ``aheadFloorMeters`` hears the second only,
//  because a distance said that late is one they have already walked.
//
//  ## Which way the hiker is going
//
//  Read off the matches themselves: a run of ``directionStepMeters`` along
//  the line one way says the hiker is going that way. A step shorter than
//  that is GPS wandering around one spot and says nothing. Until a step has
//  said, nothing is announced, unless the caller knew the direction already
//  — the phone's walk does (`TrailWalkCoverage.direction`).
//
//  Turning round takes more. A fix is delivered only once it has moved a
//  distance filter's ten or twenty metres, and may be fifty metres out, so
//  one fix that far back is what a hiker standing at a fork produces, and
//  read as a turn it has them told the other direction's way at the fork in
//  front of them. A reversal is ``reversalMeters`` back from the furthest
//  point reached, on ``reversalFixes`` fixes in a row. A hiker who really
//  turns round after a fork is a few seconds later hearing the way back,
//  which is the cheap side to be wrong on: they have just walked it.
//
//  ## Said once
//
//  Each cue is said once per junction and direction. A hiker who walks on
//  more than ``rearmMeters`` from a junction, either way, is no longer at it,
//  and a later pass — a loop that crosses itself, the walk back down an
//  out-and-back — is a new arrival there and hears it again.
//
//  ## One junction at a time
//
//  Only the nearest junction ahead that still has its second cue to come is
//  considered. Two junctions twenty metres apart would otherwise have the
//  second's distance said before the first's turn, and the hiker would hear
//  them out of the order they meet them. And a junction whose second cue has
//  been said holds the next one back until the hiker reaches it: said
//  ``imminentMeters`` early, the next one's turn would be heard while the
//  first fork was still in front of them, and taken there.
//

import Foundation

/// Something to say about a junction.
public struct JunctionCue: Equatable, Sendable {
    /// Which of the announcer's junctions it is about.
    public let junctionIndex: Int
    public let maneuver: JunctionManeuver
    /// How far ahead the junction is, for the first cue; `nil` for the
    /// second, which is said at the junction.
    public let metersAhead: Double?

    public init(junctionIndex: Int, maneuver: JunctionManeuver, metersAhead: Double?) {
        self.junctionIndex = junctionIndex
        self.maneuver = maneuver
        self.metersAhead = metersAhead
    }

    /// Whether this is the cue at the junction rather than the one before it.
    public var isImminent: Bool { metersAhead == nil }

    /// The distance as it is said: to the nearest ten metres, or fifty feet
    /// where the reader's region measures a road in miles, and never less
    /// than one step of that. `nil` for the cue at the junction.
    ///
    /// Rounded because a hiker hears "in a hundred and forty metres" as an
    /// estimate whatever it says, and "a hundred and thirty-seven" as a figure
    /// that will be wrong by the time it has been said.
    public func roundedDistance(locale: Locale = .autoupdatingCurrent) -> Measurement<UnitLength>? {
        guard let metersAhead, metersAhead.isFinite else { return nil }
        let imperial = WidgetFormat.prefersImperialRoadUnits(in: locale)
        let unit: UnitLength = imperial ? .feet : .meters
        let step: Double = imperial ? Self.imperialStepFeet : Self.metricStepMeters
        let value = Measurement(value: metersAhead, unit: UnitLength.meters).converted(to: unit).value
        return Measurement(value: max(step, (value / step).rounded() * step), unit: unit)
    }

    /// ``roundedDistance(locale:)`` in words, for a sentence that is read
    /// aloud: "150 meters", "500 feet".
    public func spokenDistance(locale: Locale = .autoupdatingCurrent) -> String? {
        roundedDistance(locale: locale)?.formatted(.measurement(width: .wide, usage: .asProvided).locale(locale))
    }

    /// ``roundedDistance(locale:)`` as a figure on a screen: "150 m".
    public func shortDistance(locale: Locale = .autoupdatingCurrent) -> String? {
        roundedDistance(locale: locale)?
            .formatted(.measurement(width: .abbreviated, usage: .asProvided).locale(locale))
    }

    private static let metricStepMeters: Double = 10
    private static let imperialStepFeet: Double = 50
}

/// Decides, fix by fix, which junction cue is due.
public struct JunctionAnnouncer: Sendable, Equatable {
    /// How far before a junction its first cue is said. Two minutes' walk
    /// at an ordinary pace: time to look up, not so long that the turn is
    /// forgotten before it comes.
    public static let aheadMeters: Double = 150
    /// Closer than this, the first cue is too late to be worth a distance,
    /// and the second will follow in a few seconds anyway.
    public static let aheadFloorMeters: Double = 70
    /// How far before a junction the second cue is said: a few steps, close
    /// enough that the junction is the one in front of the hiker and not the
    /// one after it.
    public static let imminentMeters: Double = 30
    /// How far past a junction its second cue may still be said, for a fix
    /// that arrives a step late.
    public static let passedMeters: Double = 10
    /// How far along the line the matches must move one way to say the hiker
    /// is going that way, while nothing has said yet. Narrower than the gap
    /// between a junction's two cues.
    public static let directionStepMeters: Double = 10
    /// How far back from the furthest point reached the matches must come to
    /// say the hiker has turned round: wider than one fix's error at the
    /// accuracies the feeds accept, once the distance filter has let it
    /// through — see this file's header.
    public static let reversalMeters: Double = 30
    /// How many fixes in a row must be ``reversalMeters`` back to say so.
    public static let reversalFixes = 2
    /// How far from a junction a hiker has to be, either way, for its cues to
    /// be said again on the next pass.
    public static let rearmMeters: Double = 250

    /// The junctions along the line, ordered by distance.
    public let junctions: [TrailJunction]
    /// Which way the hiker is going, once that is known.
    public private(set) var direction: RouteTravelDirection?
    /// Where the direction was last decided, and once it has been, the
    /// furthest point reached going that way.
    private var anchorMeters: Double?
    /// How many fixes in a row have been ``reversalMeters`` back.
    private var reversalRun = 0
    /// Which cues have been said, by junction and direction.
    private var spoken: [SpokenKey: Stage] = [:]

    private struct SpokenKey: Hashable, Sendable {
        let index: Int
        let direction: RouteTravelDirection
    }

    private enum Stage: Sendable, Equatable {
        case ahead
        case imminent
    }

    /// - Parameter direction: which way the hiker is already known to be
    ///   going, or `nil` to wait for the matches to say.
    public init(junctions: [TrailJunction], direction: RouteTravelDirection? = nil) {
        self.junctions = junctions.sorted { $0.distanceMeters < $1.distanceMeters }
        self.direction = direction
    }

    /// Takes the hiker's position along the line and answers the cue due
    /// now, if any. At most one a fix.
    ///
    /// - Parameter isOnTrail: whether the fix matched the line. A hiker off
    ///   it is somewhere no junction on it applies to, and the off-trail
    ///   warning is what speaks to them there.
    public mutating func advance(to distanceMeters: Double, isOnTrail: Bool) -> JunctionCue? {
        guard isOnTrail, distanceMeters.isFinite else { return nil }
        updateDirection(at: distanceMeters)
        rearm(around: distanceMeters)
        guard let direction else { return nil }
        guard let (index, ahead) = nextPending(from: distanceMeters, traveling: direction),
              let maneuver = junctions[index].maneuver(traveling: direction)
        else { return nil }
        let key = SpokenKey(index: index, direction: direction)
        if ahead <= Self.imminentMeters {
            spoken[key] = .imminent
            return JunctionCue(junctionIndex: index, maneuver: maneuver, metersAhead: nil)
        }
        guard ahead > Self.aheadFloorMeters, spoken[key] == nil else { return nil }
        spoken[key] = .ahead
        return JunctionCue(junctionIndex: index, maneuver: maneuver, metersAhead: ahead)
    }

    /// Forgets where the hiker was, keeping which way they were going and
    /// what has been said: for a hiker who may have been carried somewhere
    /// while nothing was matched, as a resumed recording's may.
    public mutating func forgetPosition() {
        anchorMeters = nil
        reversalRun = 0
    }

    private mutating func updateDirection(at distance: Double) {
        guard let anchor = anchorMeters else {
            anchorMeters = distance
            return
        }
        guard let direction else {
            let step = distance - anchor
            if step >= Self.directionStepMeters {
                direction = .towardsEnd
                anchorMeters = distance
            } else if step <= -Self.directionStepMeters {
                direction = .towardsStart
                anchorMeters = distance
            }
            return
        }
        let back = direction == .towardsEnd ? anchor - distance : distance - anchor
        guard back > 0 else {
            anchorMeters = distance
            reversalRun = 0
            return
        }
        reversalRun = back >= Self.reversalMeters ? reversalRun + 1 : 0
        guard reversalRun >= Self.reversalFixes else { return }
        self.direction = direction == .towardsEnd ? .towardsStart : .towardsEnd
        anchorMeters = distance
        reversalRun = 0
    }

    private mutating func rearm(around distance: Double) {
        spoken = spoken.filter { key, _ in
            abs(junctions[key.index].distanceMeters - distance) <= Self.rearmMeters
        }
    }

    /// The nearest junction ahead within ``aheadMeters`` that has something
    /// to say walking `direction` and has not yet said its second cue, with
    /// how far ahead it is. `nil` while a junction whose second cue has been
    /// said is still ahead — see this file's header.
    private func nextPending(
        from distance: Double,
        traveling direction: RouteTravelDirection
    ) -> (index: Int, ahead: Double)? {
        let indices: [Int] = switch direction {
        case .towardsEnd: Array(junctions.indices)
        case .towardsStart: junctions.indices.reversed()
        }
        for index in indices {
            let junction = junctions[index]
            let ahead = direction == .towardsEnd
                ? junction.distanceMeters - distance
                : distance - junction.distanceMeters
            guard ahead > -Self.passedMeters else { continue }
            guard ahead <= Self.aheadMeters else { return nil }
            guard junction.maneuver(traveling: direction) != nil else { continue }
            if spoken[SpokenKey(index: index, direction: direction)] == .imminent {
                // Said, but not yet reached: the next junction waits for the
                // hiker to be at this one, or its turn would be taken here.
                guard ahead <= 0 else { return nil }
                continue
            }
            return (index, ahead)
        }
        return nil
    }
}
