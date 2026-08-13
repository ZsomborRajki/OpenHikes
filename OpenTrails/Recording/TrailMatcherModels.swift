//
//  TrailMatcherModels.swift
//  OpenTrails
//

import Foundation

nonisolated struct TrailMatchAlternative: Equatable, Sendable {
    let id: Int
    let points: [RecordingPoint]
    let distanceMeters: Double
    let trailNames: [String]
}

nonisolated struct TrailMatchAmbiguity: Equatable, Identifiable, Sendable {
    let id: Int
    let gpsPoints: [RecordingPoint]
    let alternatives: [TrailMatchAlternative]
}

nonisolated enum TrailAmbiguityChoice: Equatable, Sendable {
    case alternative(Int)
    case gps
}

nonisolated struct TrailMatchLeg: Sendable {
    let index: Int
    let defaultPoints: [RecordingPoint]
    let alternatives: [TrailMatchAlternative]
}

nonisolated struct TrailMatchResult: Sendable {
    private static let mergeThresholdMeters = 0.05

    let points: [RecordingPoint]
    let matchedLegCount: Int
    let ambiguousLegCount: Int
    let matchedTrailName: String?
    let currentTrailName: String?
    let didMoveRoute: Bool
    let ambiguities: [TrailMatchAmbiguity]
    let legs: [TrailMatchLeg]

    func points(
        resolving choices: [Int: TrailAmbiguityChoice]
    ) -> [RecordingPoint] {
        guard !legs.isEmpty else {
            return points
        }
        var output: [RecordingPoint] = []
        for leg in legs {
            let selected: [RecordingPoint]
            switch choices[leg.index] ?? .gps {
            case .gps: selected = leg.defaultPoints
            case .alternative(let alternativeID):
                selected = leg.alternatives.first { alt in
                    alt.id == alternativeID
                }?.points ?? leg.defaultPoints
            }
            if output.isEmpty {
                output.append(contentsOf: selected)
            } else if let previous = output.last,
                      let first = selected.first,
                      RouteGeometry.distanceMeters(
                          from: previous.coordinate,
                          to: first.coordinate
                      ) <= Self.mergeThresholdMeters {
                output.append(contentsOf: selected.dropFirst())
            } else {
                output.append(contentsOf: selected)
            }
        }
        return output
    }
}
