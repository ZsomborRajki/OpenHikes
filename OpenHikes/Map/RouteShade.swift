//
//  RouteShade.swift
//  OpenHikes
//
//  The one scale the selected hike's line is coloured on, whichever way it
//  is being read — by OpenStreetMap's difficulty grade or by how steep the
//  ground is (see ``RouteColoring``). Six steps from green to black, so a
//  black stretch means "the hardest this line gets" in either mode, and the
//  key under the switch does not change when the mode does.
//
//  The Difficulty section draws its bar in these colours too, through
//  ``TrailDifficulty/shade``, so the map and the bar beneath it are read with
//  one legend.
//

import SwiftUI

/// One step of the route colour scale. The raw value is the step, easiest
/// at zero; the cases are declared alphabetically, and the order they are
/// *presented* in is ``scale``.
nonisolated enum RouteShade: Int, CaseIterable, Comparable, Sendable {
    case easiest = 0
    case easy = 1
    case hard = 3
    case harder = 4
    case hardest = 5
    case moderate = 2

    /// Every step, easiest first.
    static let scale: [Self] = [.easiest, .easy, .moderate, .hard, .harder, .hardest]

    /// Written as hex, the way a route's own colour is stored.
    private static let burgundy = Color(hex: "#800021") ?? .red
    /// A touch off pure black, which reads as a hole in the map rather than
    /// as a line.
    private static let black = Color(hex: "#141417") ?? .black

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Green, yellow, orange, red, burgundy, black: warm colours climbing to
    /// dark ones, with no hue the map itself uses for something else (water,
    /// parks) and none that reads as decoration. The two darkest steps are
    /// fixed colours rather than adaptive ones, because they are named for
    /// what they are — a black stretch should be black in dark mode too.
    var color: Color {
        switch self {
        case .easiest: .green
        case .easy: .yellow
        case .moderate: .orange
        case .hard: .red
        case .harder: Self.burgundy
        case .hardest: Self.black
        }
    }
}
