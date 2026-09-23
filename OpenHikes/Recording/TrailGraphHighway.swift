//
//  TrailGraphHighway.swift
//  OpenHikes
//
//  Which OpenStreetMap ways the trail graph downloads, and what each of them
//  is to the two kinds of question asked of it.
//
//  A recording asks *where did this hiker go*, and a road is the wrong answer
//  to that: snapping a trace in a valley onto the lane beside the path is
//  worse than leaving it alone. The trail maker asks *how does a hiker get
//  from here to there*, and a road is very often part of the right answer.
//  Measured 2026-09-23 on the z12 tile over the Königssee: with trails alone
//  the graph is 192 separate pieces and the largest holds a quarter of its
//  nodes, so two points in the same village routinely sat on islands no path
//  joined. The joins were the lanes — a named footpath mapped as six
//  `service` segments, a lakeside promenade mapped as `pedestrian` — and
//  adding the roads below put 99.4% of the nodes in one piece.
//
//  So the graph carries both, each edge says which it is, and
//  ``TrailMatcherGraphIndex`` decides per question: the recording, the
//  breakdowns and the watch index trails only, as they always did, and the
//  maker routes over everything with roads costed higher so a path is taken
//  whenever there is one.
//

import Foundation

nonisolated enum TrailGraphHighway {
    /// What a hiker follows. Everything a recording is matched against.
    static let trails: Set<String> = [
        "path", "footway", "track", "bridleway", "steps", "cycleway",
        "via_ferrata",
    ]

    /// Roads a drawn leg may use to join one trail to another, and how much
    /// dearer a metre of each is than a metre of trail.
    ///
    /// Relative, not absolute: a residential street at 1.5 means a path up to
    /// half as long again is still preferred to it. `pedestrian` is a walking
    /// street and costs what a trail does; the bigger roads cost enough that a
    /// route only follows one where nothing else goes. Motorways and trunk
    /// roads are not here at all — a hiker cannot use the first and should
    /// not be sent along the second.
    static let connectorCosts: [String: Double] = [
        "pedestrian": asTrail,
        "living_street": lane,
        "service": lane,
        "residential": street,
        "unclassified": street,
        "road": street,
        "tertiary": throughRoad,
        "tertiary_link": throughRoad,
        "secondary": mainRoad,
        "secondary_link": mainRoad,
        "primary": majorRoad,
        "primary_link": majorRoad,
    ]

    // The tiers above, lightest first.
    private static let asTrail = 1.0
    private static let lane = 1.2
    private static let street = 1.5
    private static let throughRoad = 2.0
    private static let mainRoad = 3.0
    private static let majorRoad = 4.0

    /// Every `highway` value the graph keeps, in the order the query names
    /// them.
    static let all: [String] = trails.union(connectorCosts.keys).sorted()

    /// Whether a way tagged `highway` is a trail.
    ///
    /// `nil` counts as one: every edge decoded before roads were downloaded
    /// has no tag, and every one of those was a trail.
    static func isTrail(_ highway: String?) -> Bool {
        highway.map(trails.contains) ?? true
    }

    /// What a metre of this way costs a drawn leg, relative to a metre of
    /// trail.
    static func walkingCost(of highway: String?) -> Double {
        highway.flatMap { connectorCosts[$0] } ?? 1
    }
}
