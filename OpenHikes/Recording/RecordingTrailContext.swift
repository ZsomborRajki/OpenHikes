//
//  RecordingTrailContext.swift
//  OpenHikes
//
//  What the matcher can say about the trail under the walker *right now*,
//  as opposed to what a finished walk turned out to have followed.
//

import Foundation

/// The trail the live matcher has the walker on: its name, and what
/// OpenStreetMap records about the way itself.
///
/// The name and the tags are read from two different places on purpose. The
/// name is the one ``TrailMatcher`` has always published — the trail the last
/// leg ran *along*, which for a leg that crossed several ways is the trail as
/// a whole rather than whichever way the walker happens to be standing on.
/// The tags come from that single way, because "gravel" and "T2" are
/// properties of ground underfoot and averaging them across a leg would
/// describe a surface nobody is walking on.
///
/// Both halves can be absent and neither implies the other: an unnamed
/// forestry track is tagged and nameless, and a famous long-distance route can
/// be named and carry no `surface` or `sac_scale` at all. A context exists
/// whenever the matcher was confident about where the walker is, which is the
/// only claim it makes.
nonisolated struct RecordingTrailContext: Equatable, Sendable {
    let name: String?
    let surface: TrailSurface
    let difficulty: TrailDifficulty

    init(name: String?, surface: TrailSurface, difficulty: TrailDifficulty) {
        self.name = name
        self.surface = surface
        self.difficulty = difficulty
    }

    init(name: String?, edge: TrailGraphEdge) {
        self.init(
            name: name,
            surface: TrailSurface(edge: edge),
            difficulty: TrailDifficulty(edge: edge)
        )
    }

    /// The tags worth putting beside the name, hardest fact first.
    ///
    /// Only *surveyed* categories appear. `TrailSurface.unknown` and
    /// `TrailDifficulty.unknown` say that OSM is silent, and a chip reading
    /// "Unknown" beside a trail name is worse than no chip: it occupies the
    /// space a real grade would and reads, at a glance, like a grade.
    var descriptors: [String] {
        var surveyed: [String] = []
        if difficulty.isSurveyed { surveyed.append(difficulty.displayName) }
        if surface.isSurveyed { surveyed.append(surface.displayName) }
        return surveyed
    }

    /// Whether there is anything here worth drawing. A context with no name
    /// and nothing surveyed is the matcher saying only "you are on *a* mapped
    /// path", which the map already shows.
    var isEmpty: Bool {
        name == nil && descriptors.isEmpty
    }
}
