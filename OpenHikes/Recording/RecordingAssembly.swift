//
//  RecordingAssembly.swift
//  OpenHikes
//
//  What a recording saved at Stop keeps of trail matching: the pieces its
//  line was put together from, so the stretches the matcher moved, bridged or
//  could not decide can still be answered for on the saved hike — see
//  ``RouteAssembly``.
//
//  A stopped recording used to wait in a review until the hiker had gone
//  through every such stretch (#1519's part 2). It is now saved at once with
//  each stretch's own default (``RouteReviewSection/defaultChoice``), which is
//  the line that review saved when nothing in it was changed, and this is
//  what makes that reversible afterwards.
//
//  Built by walking the matcher's legs the way
//  ``TrailMatchResult/points(resolving:)`` joins them, so a piece names the
//  very points of the saved line it became. The caller holds the result to
//  that: an assembly that does not rebuild the line it was made beside is not
//  kept (``RecordingPreparation/forSave(points:startedAt:graph:gapDistances:)``).
//

import Foundation
import OpenHikesData

nonisolated extension RouteCheck.Choice {
    init(_ choice: TrailRouteChoice) {
        switch choice {
        case .alternative(let id): self = .alternative(id)
        case .gps: self = .gps
        case .matched: self = .matched
        }
    }
}

nonisolated extension RouteCheck.Kind {
    init(_ kind: RouteReviewSection.Kind) {
        switch kind {
        case .ambiguous: self = .ambiguous
        case .gap: self = .gap
        case .snapped: self = .snapped
        }
    }
}

nonisolated extension RouteReviewSection {
    /// Each section's default, on the legs it covers: the form
    /// ``TrailMatchResult/points(resolving:)`` takes its choices in.
    static func defaultLegChoices(of sections: [Self]) -> [Int: TrailRouteChoice] {
        var choices: [Int: TrailRouteChoice] = [:]
        for section in sections {
            for legIndex in section.legIndices { choices[legIndex] = section.defaultChoice }
        }
        return choices
    }
}

nonisolated extension RouteAssembly {
    /// The pieces `match` resolves into with every section at its default,
    /// or `nil` when there is no section to keep.
    static func saved(from match: TrailMatchResult, sections: [RouteReviewSection]) -> Self? {
        guard !sections.isEmpty, !match.legs.isEmpty else { return nil }
        var sectionOfLeg: [Int: Int] = [:]
        for (position, section) in sections.enumerated() {
            for legIndex in section.legIndices { sectionOfLeg[legIndex] = position }
        }

        var walk = Walk()
        for leg in match.legs {
            let position = sectionOfLeg[leg.index]
            let choice = position.map { sections[$0].defaultChoice } ?? .matched
            walk.append(leg.points(for: choice), ofSectionAt: position, sections: sections)
        }
        walk.closeKept()

        var budget = maximumAlternativeCoordinates
        let checks = sections.enumerated().compactMap { position, section -> RouteCheck? in
            guard let range = walk.ranges[position],
                  let firstLeg = section.legIndices.first,
                  let lastLeg = section.legIndices.last
            else { return nil }
            return RouteCheck(
                id: section.id,
                kind: RouteCheck.Kind(section.kind),
                savedChoice: RouteCheck.Choice(section.defaultChoice),
                savedRange: range,
                // Leg `i` runs from fix `i` to fix `i + 1`.
                rawRange: firstLeg...(lastLeg + 1),
                trailName: section.trailName,
                unobservedSeconds: section.unobservedDuration,
                isBridged: section.isBridged,
                alternatives: alternatives(of: section, within: &budget)
            )
        }
        guard !checks.isEmpty else { return nil }
        return Self(pieces: walk.pieces, checks: checks)
    }

    /// The section's other routes, as many as still fit — see
    /// ``maximumAlternativeCoordinates``. One left out is one the saved hike
    /// cannot offer, and the stretch keeps its fixes.
    private static func alternatives(
        of section: RouteReviewSection,
        within budget: inout Int
    ) -> [RouteCheck.Alternative] {
        section.alternatives.compactMap { alternative in
            guard alternative.points.count <= budget else { return nil }
            budget -= alternative.points.count
            return RouteCheck.Alternative(
                id: alternative.id,
                points: alternative.points.map(\.routeCoordinate),
                trailNames: alternative.trailNames
            )
        }
    }

    /// The legs joined end to end, keeping count of where each lands.
    private struct Walk {
        private(set) var pieces: [Piece] = []
        /// Where each section's points are in the joined line, by its place
        /// in the list of sections.
        private(set) var ranges: [Int: ClosedRange<Int>] = [:]
        private var kept: ClosedRange<Int>?
        private var count = 0
        private var last: RecordingPoint?

        mutating func append(
            _ points: [RecordingPoint],
            ofSectionAt position: Int?,
            sections: [RouteReviewSection]
        ) {
            guard let first = points.first, let end = points.last else { return }
            // The matcher's own rule for a point two legs share.
            let joins = last.map { previous in
                RouteGeometry.distanceMeters(from: previous.coordinate, to: first.coordinate)
                    <= TrailMatchResult.mergeThresholdMeters
            } ?? false
            let lower = joins ? count - 1 : count
            count += points.count - (joins ? 1 : 0)
            let range = lower...(count - 1)
            last = end
            guard let position else {
                kept = kept.map { $0.lowerBound...range.upperBound } ?? range
                return
            }
            closeKept()
            if let open = ranges[position] {
                ranges[position] = open.lowerBound...range.upperBound
            } else {
                ranges[position] = range
                pieces.append(.check(sections[position].id))
            }
        }

        mutating func closeKept() {
            guard let range = kept else { return }
            pieces.append(.kept(range))
            kept = nil
        }
    }
}
