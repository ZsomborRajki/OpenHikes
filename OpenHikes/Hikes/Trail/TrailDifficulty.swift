//
//  TrailDifficulty.swift
//  OpenHikes
//
//  The handful of hiking difficulty grades a hiker actually plans around,
//  derived from OpenStreetMap's `sac_scale` tag.
//

import Foundation

/// How demanding a stretch of trail is, drawn from OSM's `sac_scale` key.
///
/// SAC stands for the Swiss Alpine Club, whose six-grade hiking scale is the
/// most widely used difficulty system in OSM. The grades below map one-to-one
/// onto the six SAC values, plus the two honest ways of not knowing.
///
/// The cases are declared alphabetically; the order they are *presented* in —
/// easiest grade first — is ``displayOrdering``.
nonisolated enum TrailDifficulty: String, CaseIterable, Codable, Hashable, Sendable, TrailCategory {
    /// Broken terrain; continuous use of hands required.
    case alpineHiking = "alpine_hiking"
    /// Exposed and technically demanding; rope experience an advantage.
    case demandingAlpineHiking = "demanding_alpine_hiking"
    /// Narrow, exposed path; hands may be needed for balance on short sections.
    case demandingMountainHiking = "demanding_mountain_hiking"
    /// Glacier or high-alpine ground; full mountaineering equipment required.
    case difficultAlpineHiking = "difficult_alpine_hiking"
    /// A well-marked path on a gentle gradient. No special equipment needed.
    case hiking = "hiking"
    /// Clear path on steeper terrain; surefootedness helpful.
    case mountainHiking = "mountain_hiking"
    /// Matched to a trail, but OSM records no `sac_scale` tag.
    case unknown = "unknown"
    /// No OSM trail near this stretch — off-trail, or simply unmapped.
    case unmapped = "unmapped"

    /// The natural presentation order: easiest grade first, unsurveyed last.
    static let displayOrdering: [Self] = [
        .hiking, .mountainHiking, .demandingMountainHiking,
        .alpineHiking, .demandingAlpineHiking, .difficultAlpineHiking,
        .unknown, .unmapped,
    ]

    var displayName: String {
        switch self {
        case .hiking: String(localized: "Hiking")
        case .mountainHiking: String(localized: "Mountain Hiking")
        case .demandingMountainHiking: String(localized: "Demanding Mountain Hiking")
        case .alpineHiking: String(localized: "Alpine Hiking")
        case .demandingAlpineHiking: String(localized: "Demanding Alpine Hiking")
        case .difficultAlpineHiking: String(localized: "Difficult Alpine Hiking")
        case .unknown: String(localized: "Unknown")
        case .unmapped: String(localized: "Not mapped")
        }
    }

    /// A short note on what this grade means in practice.
    var summary: String {
        switch self {
        case .hiking: String(localized: "Marked path, gentle terrain")
        case .mountainHiking: String(localized: "Steeper path, surefootedness helpful")
        case .demandingMountainHiking: String(localized: "Hands occasionally needed for balance")
        case .alpineHiking: String(localized: "Broken terrain, hands used continuously")
        case .demandingAlpineHiking: String(localized: "Exposed, technically demanding")
        case .difficultAlpineHiking: String(localized: "Full mountaineering equipment required")
        case .unknown: String(localized: "Mapped trail, untagged difficulty")
        case .unmapped: String(localized: "No mapped trail nearby")
        }
    }

    /// Whether this category came from actual OSM tagging.
    var isSurveyed: Bool {
        let surveyed: Set<Self> = [
            .hiking, .mountainHiking, .demandingMountainHiking,
            .alpineHiking, .demandingAlpineHiking, .difficultAlpineHiking,
        ]
        return surveyed.contains(self)
    }
}

// MARK: - OSM classification

nonisolated extension TrailDifficulty {
    init(sacScale: String?) {
        guard let sacScale else {
            self = .unknown
            return
        }
        switch sacScale.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "hiking": self = .hiking
        case "mountain_hiking": self = .mountainHiking
        case "demanding_mountain_hiking": self = .demandingMountainHiking
        case "alpine_hiking": self = .alpineHiking
        case "demanding_alpine_hiking": self = .demandingAlpineHiking
        case "difficult_alpine_hiking": self = .difficultAlpineHiking
        default: self = .unknown
        }
    }

    init(edge: TrailGraphEdge) {
        self.init(sacScale: edge.sacScale)
    }
}
