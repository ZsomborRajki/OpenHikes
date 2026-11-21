//
//  VectorTilePathStyle.swift
//  OpenHikesVectorTiles
//
//  What the map draws a path, a cycleway, a bridleway, a track and a flight
//  of steps as: OpenStreetMap Carto's own figures for each (`roads.mss`), in
//  the pixels of a 256-pixel tile. They are what a hiker reads the map by,
//  and Carto says a good deal with them: a track's grade by how broken its
//  line is, a path's surface by its dashes, a way closed to those it is for
//  by a paler color, and from zoom 15 a pale band under every one of them,
//  which is what keeps a path readable through a wood or across scree.
//
//  A path is a step function of the zoom in Carto, and its dashes are in
//  pixels whatever its width, so neither is a ``ZoomCurve`` or a ``Line``:
//  ``path(_:z:)`` gives the look at one zoom.
//
//  What a path is comes from the vector extras' `paths` layer, where a tile
//  has it (`VectorTilePainter+Roads.swift`), because the basemap keeps none
//  of a track's grade, a path's surface or who it is for. A tile without
//  the extras says what the basemap can (``pathTraits(detail:access:)``):
//  the kind and its own `access`, and so a path of unknown surface.
//

import CoreGraphics

extension VectorTileStyle {
    /// What a path is, as Carto's roads query files it: a `highway=path`
    /// designated for bicycles is a cycleway, and one for horses a
    /// bridleway (`carto_path_type`), and a footway and a plain path are
    /// drawn alike.
    enum PathKind: String, Sendable, CaseIterable {
        case footway = "footway"
        case cycleway = "cycleway"
        case bridleway = "bridleway"
        case track = "track"
        case steps = "steps"
    }

    /// A way's surface as Carto reads it (`carto_highway_int_surface`).
    enum PathSurface: String, Sendable {
        case paved = "paved"
        case unpaved = "unpaved"
    }

    /// One path, as its tile describes it.
    struct PathTraits: Sendable, Equatable {
        var kind: PathKind
        /// `nil` for a surface nobody mapped, or one Carto does not know.
        var surface: PathSurface?
        /// A track's grade, 1 for the firmest to 5, or `nil` for none mapped.
        var grade: Int?
        /// Whether it is closed to those it is for.
        var isClosed = false
    }

    /// How a path is drawn at one zoom.
    struct PathLook: Sendable, Equatable {
        let color: CGColor
        let width: CGFloat
        /// Dash and gap lengths in pixels; empty for an unbroken line.
        let dash: [CGFloat]
        /// How each dash ends.
        let cap: CGLineCap
        let alpha: CGFloat
        /// How wide the pale band under it is: under an open stretch from
        /// ``pathBandZ``, and under a bridge or through a tunnel at every
        /// zoom, inside the casing.
        let bandWidth: CGFloat

        /// The casing round a bridge's band, and round a tunnel's.
        var bridgeCasingWidth: CGFloat { bandWidth + 2 * VectorTileStyle.pathBridgeCasing }
        var tunnelCasingWidth: CGFloat { bandWidth + 2 * VectorTileStyle.pathTunnelCasing }
    }

    /// Carto lays the band under a path from this zoom.
    static let pathBandZ = 15
    /// How much of the ground the band lets through.
    static let pathBandAlpha: CGFloat = 0.4
    static let pathBand = color("#FFFFFF")
    static let pathBridgeCasingColor = color("#000000")
    static let pathTunnelCasingColor = color("#808080")
    static let pathTunnelCasingDash: [CGFloat] = [4, 2]
    /// Each side of the casing of a path's bridge, and of its tunnel.
    static let pathBridgeCasing: CGFloat = 0.5
    static let pathTunnelCasing: CGFloat = 1
    /// A path's bridge is cased from this zoom, as Carto cases one.
    static let pathBridgeZ = 14

    /// The look of a path with `traits` at zoom `z`, or `nil` where Carto
    /// does not draw it yet: an open one from its kind's first zoom, and a
    /// closed one from ``closedPathZ``.
    static func path(_ traits: PathTraits, z: Int) -> PathLook? {
        let figures = PathFigures.of(traits.kind)
        guard z >= (traits.isClosed ? max(closedPathZ, figures.firstZ) : figures.firstZ) else { return nil }
        let width = figures.width.value(at: z)
        // The firmer tracks are drawn heavier, and Carto narrows their band.
        let isFirmTrack = traits.kind == .track && (traits.grade == 1 || traits.grade == 2)
        let banded = isFirmTrack && z >= pathBandZ ? PathFigures.firmTrackBand : width
        return PathLook(
            color: traits.isClosed ? figures.closed : figures.open,
            width: width,
            dash: PathFigures.dash(traits, z: z),
            cap: figures.cap,
            alpha: figures.alpha,
            bandWidth: banded + 2
        )
    }

    /// What the basemap can say of one of its own paths: the kind its
    /// `kind_detail` names, and whether its `access` closes it. Carto reads
    /// `foot`, `bicycle` or `horse` before `access`, and the basemap keeps
    /// `access` alone, so a path closed to all but walkers reads as closed
    /// here; the extras' `paths` layer says it as Carto does. `nil` for what
    /// is no path: a pedestrian street is a road, and Carto draws no platform
    /// or corridor as one.
    static func pathTraits(detail: String?, access: String?) -> PathTraits? {
        guard let detail, !notPaths.contains(detail) else { return nil }
        return PathTraits(
            kind: PathKind(rawValue: detail) ?? .footway,
            isClosed: access.map(closingAccess.contains) ?? false
        )
    }

    /// What the extras' `paths` layer says of one of its paths: the kind
    /// Carto files it as, its surface, a track's grade, and `no` for an
    /// `access` Carto reads as closed to those the way is for. `nil` for a
    /// kind this build does not know.
    static func pathTraits(kind: String?, surface: String?, tracktype: String?, access: String?) -> PathTraits? {
        guard let filed = kind.flatMap(PathKind.init(rawValue:)) else { return nil }
        return PathTraits(
            kind: filed,
            surface: surface.flatMap(PathSurface.init(rawValue:)),
            grade: trackGrade(tracktype),
            isClosed: access == closedAccess
        )
    }

    private static let closedAccess = "no"

    /// The basemap's details of a `path` that are drawn as something else,
    /// or not at all.
    private static let notPaths: Set<String> = ["pedestrian", "pier", "platform", "corridor"]

    /// A track's grade out of its `tracktype`, `grade1` to `grade5`.
    static func trackGrade(_ tracktype: String?) -> Int? {
        guard let tracktype, tracktype.hasPrefix(gradePrefix) else { return nil }
        return Int(tracktype.dropFirst(gradePrefix.count)).flatMap { (1...5).contains($0) ? $0 : nil }
    }

    private static let gradePrefix = "grade"
}

/// Carto's figures for each kind of path.
private struct PathFigures {
    let firstZ: Int
    let open: CGColor
    let closed: CGColor
    let width: ZoomCurve
    var cap: CGLineCap = .butt
    var alpha: CGFloat = 1

    static func of(_ kind: VectorTileStyle.PathKind) -> Self {
        switch kind {
        case .footway: footway
        case .cycleway: cycleway
        case .bridleway: bridleway
        case .track: track
        case .steps: steps
        }
    }

    // Widths, each `@<kind>-width-z<zoom>` of `roads.mss`.
    private static let footwayZ14: CGFloat = 0.7
    private static let footwayZ16: CGFloat = 1.3
    private static let footwayZ19: CGFloat = 1.6
    private static let cyclewayZ13: CGFloat = 0.7
    private static let cyclewayZ15: CGFloat = 0.9
    private static let cyclewayZ19: CGFloat = 1.3
    private static let bridlewayZ13: CGFloat = 0.3
    private static let bridlewayZ15: CGFloat = 1.2
    private static let trackZ15: CGFloat = 1.5
    private static let stepsZ14: CGFloat = 0.7
    /// `@track-grade1-width-z15`, which only the band is measured from.
    static let firmTrackBand: CGFloat = 0.75
    private static let z17 = VectorTileStyle.z17
    private static let z18 = VectorTileStyle.z18
    private static let z19 = VectorTileStyle.z19

    private static let footway = Self(
        firstZ: 14,
        open: VectorTileStyle.color("#FA8072"),
        closed: VectorTileStyle.color("#BBBBBB"),
        width: ZoomCurve([
            (14, footwayZ14), (15, 1), (16, footwayZ16), (z17, footwayZ16), (z18, footwayZ16), (z19, footwayZ19),
        ]),
        cap: .round
    )
    private static let cycleway = Self(
        firstZ: 13,
        open: VectorTileStyle.color("#0000FF"),
        closed: VectorTileStyle.color("#9999FF"),
        width: ZoomCurve([
            (13, cyclewayZ13), (14, cyclewayZ13), (15, cyclewayZ15), (16, cyclewayZ15), (z17, cyclewayZ15),
            (z18, 1), (z19, cyclewayZ19),
        ]),
        cap: .round
    )
    private static let bridleway = Self(
        firstZ: 13,
        open: VectorTileStyle.color("#008000"),
        closed: VectorTileStyle.color("#AADDAA"),
        width: ZoomCurve([(13, bridlewayZ13), (14, bridlewayZ13), (15, bridlewayZ15)])
    )
    private static let track = Self(
        firstZ: 13,
        open: VectorTileStyle.color("#996600"),
        closed: VectorTileStyle.color("#E2C5BB"),
        width: ZoomCurve([(13, 0.5), (14, 0.5), (15, trackZ15)]),
        cap: .round,
        alpha: trackAlpha
    )
    private static let trackAlpha: CGFloat = 0.8
    private static let steps = Self(
        firstZ: 14,
        open: VectorTileStyle.color("#FA8072"),
        closed: VectorTileStyle.color("#BBBBBB"),
        width: ZoomCurve([(14, stepsZ14), (15, 3)])
    )

    // Dashes, in pixels.
    private static let pavedGap: CGFloat = 3.5
    /// A track of each grade before zoom 15, and from it: an unbroken line
    /// for the firmest, and shorter dashes further apart the softer it is.
    private static let gradedTrack: [Int: (near: [CGFloat], far: [CGFloat])] = [
        1: ([], []),
        2: ([11, 4], [grade2Dash, grade2Gap]),
        3: ([7, 5], [grade3Dash, 4]),
        4: ([4, 6], [grade2Gap, grade4Gap]),
        5: ([2, 8], [grade5Dash, grade5Gap]),
    ]
    private static let grade2Dash: CGFloat = 8.8
    private static let grade2Gap: CGFloat = 3.2
    private static let grade3Dash: CGFloat = 5.6
    private static let grade4Gap: CGFloat = 4.8
    private static let grade5Dash: CGFloat = 1.6
    private static let grade5Gap: CGFloat = 6.4

    static func dash(_ traits: VectorTileStyle.PathTraits, z: Int) -> [CGFloat] {
        let isNear = z >= VectorTileStyle.pathBandZ
        switch traits.kind {
        case .steps:
            return [2, 1]
        case .bridleway:
            return [4, 2]
        case .track:
            guard let graded = traits.grade.flatMap({ gradedTrack[$0] }) else { return [5, 4, 2, 4] }
            return isNear ? graded.near : graded.far
        case .footway, .cycleway:
            guard isNear else { return [1, 3] }
            switch traits.surface {
            case .paved: return z >= z17 ? [3, 3] : [z == VectorTileStyle.pathBandZ ? 2 : 3, pavedGap]
            case .unpaved: return [1, 4]
            case nil: return z == VectorTileStyle.pathBandZ ? [1, 3, 2, 4] : [1, 4, 2, 3]
            }
        }
    }
}
