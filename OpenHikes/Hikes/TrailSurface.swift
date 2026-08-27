//
//  TrailSurface.swift
//  OpenHikes
//
//  The handful of surface categories a hiker actually plans around, and the
//  mapping from OpenStreetMap's much longer `surface` vocabulary onto them.
//

import Foundation

/// What a stretch of route is underfoot.
///
/// OSM's `surface` key has dozens of values, most of which differ in ways no
/// walker cares about — `concrete:plates` and `paving_stones` are both "you
/// could push a pram along it". These are the distinctions worth drawing, plus
/// the two honest ways of not knowing.
///
/// The cases are declared alphabetically; the order they are *presented* in is
/// ``displayOrdering``.
nonisolated enum TrailSurface: String, CaseIterable, Codable, Hashable, Sendable, TrailCategory {
    /// Loose but engineered: gravel, fine gravel, compacted hardcore.
    case gravel = "gravel"
    /// Natural and unengineered: dirt, earth, grass, sand, mud, woodchips.
    case ground = "ground"
    /// Sealed and hard: asphalt, concrete, paving stones, cobbles, boardwalk.
    case paved = "paved"
    /// Bare rock and scree.
    case rock = "rock"
    /// Matched to a trail, but OSM records nothing about its surface.
    case unknown = "unknown"
    /// No OSM trail near this stretch at all — off-trail, or simply an area
    /// nobody has mapped. Kept separate from ``unknown`` because the two call
    /// for different responses: one is a gap in tagging, the other a gap in
    /// the map.
    case unmapped = "unmapped"

    /// Hardest surface first, with the two "no data" categories last —
    /// the order a legend reads best in, and the tie-break when two surfaces
    /// cover exactly the same distance.
    static let displayOrdering: [Self] = [
        .paved, .gravel, .ground, .rock, .unknown, .unmapped,
    ]

    /// Whether this category came from actual OSM tagging, as opposed to
    /// describing the absence of it.
    var isSurveyed: Bool {
        switch self {
        case .paved, .gravel, .ground, .rock: true
        case .unknown, .unmapped: false
        }
    }

    /// Position in ``displayOrdering``. Supplied by ``TrailCategory``.
    var displayName: String {
        switch self {
        case .paved: "Paved"
        case .gravel: "Gravel"
        case .ground: "Ground"
        case .rock: "Rock"
        case .unknown: "Unknown"
        case .unmapped: "Not mapped"
        }
    }

    /// A one-line gloss of what OSM values land in this category, shown under
    /// the legend so a percentage can be interpreted rather than just read.
    var summary: String {
        switch self {
        case .paved: "Asphalt, concrete, paving stones"
        case .gravel: "Gravel and compacted hardcore"
        case .ground: "Dirt, grass, sand, mud"
        case .rock: "Bare rock and scree"
        case .unknown: "Mapped trail, untagged surface"
        case .unmapped: "No mapped trail nearby"
        }
    }
}

// MARK: - OSM classification

nonisolated extension TrailSurface {
    private static let pavedValues: Set<String> = [
        "paved", "asphalt", "chipseal", "concrete", "concrete:lanes",
        "concrete:plates", "paving_stones", "paving_stones:lanes",
        "grass_paver", "sett", "cobblestone", "unhewn_cobblestone", "bricks",
        "brick", "metal", "metal_grid", "wood", "stone", "rubber", "tartan",
        "acrylic",
    ]
    private static let gravelValues: Set<String> = [
        "gravel", "fine_gravel", "compacted", "pebblestone", "shells",
        "gravel_turf",
    ]
    private static let groundValues: Set<String> = [
        "unpaved", "ground", "dirt", "earth", "soil", "grass", "mud", "sand",
        "woodchips", "snow", "ice", "salt", "clay",
    ]
    private static let rockValues: Set<String> = [
        "rock", "bare_rock", "scree", "stepping_stones",
    ]

    /// Classifies one OSM way.
    ///
    /// `tracktype` is consulted only when `surface` is missing. It is a
    /// firmness grade rather than a material, so it can't be more specific
    /// than "solid" or "soft" — but roughly a fifth of the untagged tracks in
    /// a typical alpine region carry one, which is a fifth of a route that
    /// would otherwise be reported as ``unknown``.
    init(osmSurface surface: String?, tracktype: String? = nil) {
        if let surface, let category = Self.category(forSurface: surface) {
            self = category
            return
        }
        if let tracktype, let category = Self.category(forTracktype: tracktype) {
            self = category
            return
        }
        self = .unknown
    }

    init(edge: TrailGraphEdge) {
        self.init(osmSurface: edge.surface, tracktype: edge.tracktype)
    }

    private static func category(forSurface value: String) -> Self? {
        // OSM allows `surface=gravel;dirt` for a way that changes partway
        // along. Without the geometry of where it changes, the leading value
        // is the best available answer.
        let normalized = normalized(value.split(separator: ";").first.map(String.init) ?? value)
        guard !normalized.isEmpty else { return nil }
        if pavedValues.contains(normalized) { return .paved }
        if gravelValues.contains(normalized) { return .gravel }
        if groundValues.contains(normalized) { return .ground }
        if rockValues.contains(normalized) { return .rock }
        return nil
    }

    /// grade1 is a sealed or otherwise solid surface; grade2 and grade3 are
    /// the gravel and hardcore range; grade4 and grade5 are soil and grass
    /// held together by nothing but use.
    private static func category(forTracktype value: String) -> Self? {
        switch normalized(value) {
        case "grade1": .paved
        case "grade2", "grade3": .gravel
        case "grade4", "grade5": .ground
        default: nil
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
