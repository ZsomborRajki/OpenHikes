//
//  TrailWalkSession+Junctions.swift
//  OpenHikes
//
//  What junction warnings read of the walk under way: the line it is along,
//  and which way along it the hiker is going. See ``JunctionGuide``.
//

import OpenHikesData
import OpenHikesShared

extension TrailWalkSession {
    /// The walked line, for the warnings to find its junctions on and match
    /// fixes against: the profile in hand, or one read for the purpose — the
    /// line a *Record Instead* carries, by the same read. `nil` when there is
    /// no walk, its row is gone or the read failed.
    func lineForJunctions() async -> RouteProfile? {
        guard case let .along(profile) = await carriedLine() else { return nil }
        return profile
    }

    /// Which way along its line the walk is going, as far as its matches
    /// have said, in the terms junction warnings speak.
    var travelDirection: RouteTravelDirection? {
        switch record?.coverage.direction {
        case .towardsEnd: .towardsEnd
        case .towardsStart: .towardsStart
        case nil: nil
        }
    }
}
