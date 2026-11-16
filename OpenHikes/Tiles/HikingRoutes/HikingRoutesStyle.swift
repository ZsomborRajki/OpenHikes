//
//  HikingRoutesStyle.swift
//  OpenHikes
//
//  How the hiking-routes layer looks at each zoom: which lines are stroked,
//  how wide and in which colour, and which routes get a sign and how close
//  two signs may stand.
//
//  **The look is Waymarked Trails'.** It is the layer this one replaced and
//  the one hikers already read, so its map style is followed figure for
//  figure rather than imitated by eye. A first attempt that only resembled
//  it gave every local route a sign from a region's view and drew each twice
//  the size, and a valley disappeared under its own numbers. The figures are
//  read out of the style the project publishes (`waymarkedtrails-backend`,
//  under `wmt_db/data/map-styles`, and `waymarkedtrails-shields`), and the
//  *Hiking Routes* pictures' caption credits it for them
//  (``HikingRoutesPicker``). What the style does, zoom by zoom:
//
//  | Zooms  | Lines                                         | Signs                      |
//  |--------|-----------------------------------------------|----------------------------|
//  | 7–8    | international and national, hairlines         | international              |
//  | 9      | the same, wider                               | national and up            |
//  | 10–11  | regional and up, and no local routes at all   | regional and up            |
//  | 12     | all, a local route a hairline on a pale band  | regional and up            |
//  | 13 on  | all, each network wider                       | every route's              |
//
//  Routes that share a way are stacked rather than chosen between: the most
//  important network widest and underneath, each lesser one narrower on top.
//  An international route along a national one is a red edge on a blue line,
//  and a regional route along a national one is orange dots on it.
//
//  **Where the figures are this layer's own.** Waymarked Trails cuts a route
//  at every junction and gives each piece one sign below zoom 13, and from a
//  continent's view it signs a route as a whole. A line here runs as far as
//  the same routes do, and no square holds a whole route, so below zoom 13 a
//  line's signs are spaced to come out about as often as its pieces' would.
//  Its special cases are left out: the Swiss and Italian difficulty networks,
//  node networks, and the downgraded regional routes drawn as hairlines.
//
//  **Measured in tile pixels.** Every width, size and distance here is in the
//  pixels of a 256-pixel map tile at the tile's own zoom — `1 / zoomScale`
//  map points — because that is what Waymarked Trails' pictures were drawn in
//  and how MapKit showed them. A phone shows a tile pixel a third to two
//  thirds of a point wide, so a sixteen-pixel sign stands five to ten points
//  high there, beside a base map lettered at the same scale.
//

import CoreGraphics
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The networks among the routes that share one line.
nonisolated struct RouteNetworkSet: OptionSet, Hashable, Sendable {
    let rawValue: UInt8

    static let local = Self(rawValue: 1 << 0)
    static let regional = Self(rawValue: 1 << 1)
    static let national = Self(rawValue: 1 << 2)
    static let international = Self(rawValue: 1 << 3)

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// The set of one network. A route whose network OpenStreetMap's hiking
    /// scheme does not have is a local one, as Waymarked Trails reads it.
    init(_ network: RouteNetwork) {
        switch network {
        case .other, .local: self = .local
        case .regional: self = .regional
        case .national: self = .national
        case .international: self = .international
        }
    }
}

/// One pass over a tile's lines: which of them, and how they are stroked.
nonisolated struct RouteStroke: Sendable {
    /// Every one of these is among a line's networks.
    var all: RouteNetworkSet
    /// At least one of these is, where any is named.
    var any: RouteNetworkSet = []
    /// None of these is.
    var none: RouteNetworkSet = []
    var color: CGColor
    /// In tile pixels.
    var width: CGFloat
    /// A dash and its gap in tile pixels, or empty for a solid line.
    var dash: [CGFloat] = []

    func draws(_ networks: RouteNetworkSet) -> Bool {
        networks.isSuperset(of: all)
            && (any.isEmpty || !networks.isDisjoint(with: any))
            && networks.isDisjoint(with: none)
    }
}

/// Which routes get a sign at a zoom, and how close signs may stand. Every
/// distance is in tile pixels.
nonisolated struct WaymarkRule: Equatable, Sendable {
    /// The least important network whose routes get a sign.
    var minimumNetwork: RouteNetwork
    /// How far apart one line's signs stand. A line shorter than this still
    /// gets one, in its middle.
    var spacing: Double
    /// How close two of the same sign may stand.
    var repeatDistance: Double
    /// The room left around every sign.
    var margin: Double
}

nonisolated enum HikingRoutesStyle {
    /// The strokes a tile at `zoom` is drawn with, the bottom one first.
    static func strokes(atZoom zoom: Int) -> [RouteStroke] {
        switch zoom {
        case ..<wideContinentZoom: continentStrokes
        case wideContinentZoom: wideContinentStrokes
        case ..<regionZoom: countryStrokes
        case regionZoom: regionStrokes
        case ..<closeZoom: localStrokes
        default: closeStrokes
        }
    }

    /// The widest stroke at `zoom`, in tile pixels: how far beside a tile a
    /// line that reaches into it can run.
    static func widestStroke(atZoom zoom: Int) -> CGFloat {
        strokes(atZoom: zoom).map(\.width).max() ?? 0
    }

    /// Whether a line with `networks` is stroked at any zoom `level`'s
    /// squares are drawn at. A square's local routes are not, from a
    /// country's view, and are not worth joining or holding there.
    static func isDrawn(_ networks: RouteNetworkSet, at level: RouteSquareLevel) -> Bool {
        let deeper = RouteSquareLevel.shallowestFirst.first { $0.firstZoom > level.firstZoom }
        let zooms = level.firstZoom..<(deeper?.firstZoom ?? level.firstZoom + 1)
        return zooms.contains { zoom in
            strokes(atZoom: zoom).contains { $0.draws(networks) }
        }
    }

    /// Which signs stand at `zoom`.
    static func waymarkRule(atZoom zoom: Int) -> WaymarkRule {
        switch zoom {
        case ..<wideContinentZoom:
            WaymarkRule(
                minimumNetwork: .international,
                spacing: continentSpacing,
                repeatDistance: continentRepeat,
                margin: continentMargin
            )
        case wideContinentZoom:
            WaymarkRule(
                minimumNetwork: .national,
                spacing: wideContinentSpacing,
                repeatDistance: wideContinentRepeat,
                margin: continentMargin
            )
        case ..<localZoom:
            WaymarkRule(
                minimumNetwork: .regional,
                spacing: regionSpacing,
                repeatDistance: regionRepeat,
                margin: margin
            )
        default:
            WaymarkRule(minimumNetwork: .local, spacing: localSpacing, repeatDistance: localRepeat, margin: margin)
        }
    }

    /// How far along a line a sign may be moved from where its spacing puts
    /// it, to stand clear of another, and the step it is moved by.
    static let positionTolerance: Double = 200
    static let positionStep: Double = 8

    /// The colour that frames a route's sign: its network's.
    static func signFrame(of network: RouteNetwork) -> CGColor {
        switch network {
        case .international: internationalFrame
        case .national: nationalFrame
        case .regional: regionalFrame
        case .local, .other: localFrame
        }
    }

    /// The opaque colour a `#RRGGBB` names, written the way a style sheet
    /// writes one.
    static func color(_ hex: String) -> CGColor {
        let color = Color(hex: hex) ?? .gray
        #if canImport(UIKit)
        return UIColor(color).cgColor
        #else
        return NSColor(color).cgColor
        #endif
    }
}

// MARK: - The figures

nonisolated private extension HikingRoutesStyle {
    static let wideContinentZoom = 9
    static let regionZoom = 12
    static let localZoom = 13
    static let closeZoom = 14

    // Signs: one line's spacing, the same sign's distance, and the room
    // around any sign, from a continent's view inward.
    static let continentSpacing: Double = 400
    static let continentRepeat: Double = 200
    static let continentMargin: Double = 30
    static let wideContinentSpacing: Double = 300
    static let wideContinentRepeat: Double = 150
    static let regionSpacing: Double = 150
    static let regionRepeat: Double = 100
    static let localSpacing: Double = 300
    static let localRepeat: Double = 50
    static let margin: Double = 10

    static let international = color("#B20303")
    static let internationalBright = color("#E10404")
    static let internationalDark = color("#AE2929")
    static let national = color("#152EEC")
    static let nationalBright = color("#2B43F8")
    static let regional = color("#FFA304")
    static let regionalLight = color("#FFCC00")
    static let regionalPale = color("#FDB23A")
    static let regionalShadow = translucent("#A76F0F")
    static let local = color("#7D31C6")
    static let localLight = color("#AF64F8")
    static let localBand = color("#C19AE6")
    static let localShadow = translucent("#565256")

    static let internationalFrame = color("#B20303")
    static let nationalFrame = color("#142EEB")
    static let regionalFrame = color("#FCA305")
    static let localFrame = color("#8C00DB")

    static let shadowAlpha: CGFloat = 0.5

    static func translucent(_ hex: String) -> CGColor {
        let opaque = color(hex)
        return opaque.copy(alpha: shadowAlpha) ?? opaque
    }

    // Widths, in tile pixels.
    static let hairline: CGFloat = 1.3
    static let thin: CGFloat = 1.5
    static let slim: CGFloat = 2
    static let localWidth: CGFloat = 2.5
    static let regionalWidth: CGFloat = 3
    static let nationalWidth: CGFloat = 4
    static let internationalWidth: CGFloat = 5
    static let wideInternational: CGFloat = 5.5
    static let closeWidth: CGFloat = 6
    static let brightInternational: CGFloat = 7
    static let countryInternational: CGFloat = 8
    static let closeInternational: CGFloat = 9

    /// Dots along a wider line: a regional route on a national one.
    static let dots: [CGFloat] = [1, 7]
    static let closeDots: [CGFloat] = [2, 10]

    static let withRegionalOrNational: RouteNetworkSet = [.regional, .national]
    static let aboveLocal: RouteNetworkSet = [.regional, .national, .international]

    /// Zooms 7 and 8: threads across a continent.
    static let continentStrokes = [
        RouteStroke(all: .national, color: national, width: hairline),
        RouteStroke(all: .international, color: international, width: slim),
    ]

    /// Zoom 9.
    static let wideContinentStrokes = [
        RouteStroke(all: [.international, .national], color: international, width: wideInternational),
        RouteStroke(all: .international, none: .national, color: international, width: nationalWidth),
        RouteStroke(all: .national, color: national, width: regionalWidth),
    ]

    /// Zooms 10 and 11: a country's long routes, and none of its local ones.
    static let countryStrokes = [
        RouteStroke(
            all: .international,
            any: withRegionalOrNational,
            color: international,
            width: countryInternational
        ),
        RouteStroke(
            all: .international,
            none: withRegionalOrNational,
            color: international,
            width: internationalWidth
        ),
        RouteStroke(all: .national, color: national, width: nationalWidth),
        RouteStroke(all: .regional, none: .national, color: regional, width: regionalWidth),
        RouteStroke(all: [.regional, .national], color: regional, width: regionalWidth, dash: dots),
    ]

    /// Zoom 12: the local routes join in, a hairline on a pale band.
    static let regionStrokes = [
        RouteStroke(all: .local, color: localBand, width: nationalWidth),
        RouteStroke(all: .local, color: local, width: thin),
        RouteStroke(all: [.international, .regional], color: international, width: closeWidth),
        RouteStroke(
            all: .international,
            none: withRegionalOrNational,
            color: international,
            width: internationalWidth
        ),
        RouteStroke(all: [.international, .national], color: internationalBright, width: brightInternational),
        RouteStroke(all: .national, color: national, width: nationalWidth),
        RouteStroke(all: .regional, none: .national, color: regional, width: regionalWidth),
        RouteStroke(all: [.regional, .national], color: regional, width: regionalWidth, dash: dots),
    ]

    /// Zoom 13: every network at its full width.
    static let localStrokes = [
        RouteStroke(
            all: .international,
            any: withRegionalOrNational,
            color: international,
            width: closeInternational
        ),
        RouteStroke(
            all: .international,
            none: withRegionalOrNational,
            color: internationalDark,
            width: closeInternational
        ),
        RouteStroke(all: .national, color: nationalBright, width: closeWidth),
        RouteStroke(
            all: .regional,
            none: [.international, .national],
            color: regionalShadow,
            width: closeWidth
        ),
        RouteStroke(all: [.regional, .local], none: .national, color: regionalLight, width: closeWidth),
        RouteStroke(all: .regional, none: [.national, .local], color: regionalPale, width: internationalWidth),
        RouteStroke(all: [.regional, .national], color: regionalPale, width: internationalWidth, dash: closeDots),
        RouteStroke(all: .local, none: aboveLocal, color: local, width: localWidth),
        RouteStroke(all: .local, any: aboveLocal, color: localLight, width: slim),
    ]

    /// Zoom 14 and deeper: the same over a shadow under each local route.
    static let closeStrokes = [RouteStroke(all: .local, color: localShadow, width: nationalWidth)] + localStrokes
}
