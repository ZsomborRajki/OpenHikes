//
//  VectorTileRoadStyle.swift
//  OpenHikes
//
//  What the map draws each road, railway and lift as: the `roads` layer of
//  the Protomaps basemap, and the lifts, the light railways, the service
//  roads and the roads being built that the vector extras add to it. Colors
//  and widths are OpenStreetMap Carto's (`roads.mss`, `aerialways.mss`,
//  `power.mss`), in the pixels of a 256-pixel tile, as the rest of
//  ``VectorTileStyle`` is. The paths are `VectorTilePathStyle.swift`'s.
//

import CoreGraphics

nonisolated extension VectorTileStyle {
    /// Each side of a road's casing, which separates a road from the ground
    /// and from the road beside it. None below zoom 12, where a road is
    /// narrower than its casing would be.
    static let casingWidth = ZoomCurve([(12, 0.5), (14, 0.75), (16, 1), (20, 2)])

    /// A road's look, and its place among the roads of its level: a road
    /// with a higher ``order`` is drawn over one with a lower.
    struct Road: Sendable {
        let line: Line
        let order: Int
        /// The look before ``casingWidth``'s first zoom, for the classes
        /// Carto draws in the gray of an unimportant road until then.
        var far: Line?

        /// The look at zoom `z`.
        func line(at z: Int) -> Line {
            z < VectorTileStyle.surfacedRoadZ ? far ?? line : line
        }
    }

    /// Carto draws a road as a surface between casings from this zoom.
    static let surfacedRoadZ = 12

    /// The style of a feature in the `roads` layer, or `nil` for one not drawn
    /// as a road: its `kind` and `kind_detail` first, then its `kind` alone.
    /// A pier is drawn with the water (``isPier(kind:detail:)``), and a path
    /// with the paths (``pathTraits(detail:access:)``): only a pedestrian
    /// street among the basemap's paths is a road. A service road whose
    /// `service` makes it a minor one is drawn as Carto draws those; the
    /// basemap keeps no `service` on a road, so that is said of the extras'
    /// service roads alone (``serviceRoad(service:)``).
    static func road(kind: String, detail: String?, service: String? = nil) -> Road? {
        guard !isPier(kind: kind, detail: detail),
              let listed = roads["\(kind)/\(detail ?? "")"] ?? roads["\(kind)/*"]
        else { return nil }
        var road = listed
        if isServiceRoad(kind: kind, detail: detail), let service, minorServices.contains(service) {
            road = Road(line: minorService, order: listed.order)
        }
        if kind == "rail", let service, sidingServices.contains(service), let detail, let siding = sidings[detail] {
            road = Road(line: siding, order: listed.order)
        }
        return road
    }

    /// The basemap's kind for every path, track and flight of steps, and
    /// for a pedestrian street.
    static let pathKind = "path"

    /// Whether the basemap files a road as a service road, which the
    /// extras' `service_roads` layer stands in for where a tile has it.
    /// The basemap gives every `highway=service` the detail `service`,
    /// whatever its own `service` tag says. A minor road with another
    /// detail is a street: a street with a `service` tag of its own has
    /// that tag's value as its detail, a residential street's `driveway`
    /// among them, and Carto draws it as the street it is.
    static func isServiceRoad(kind: String, detail: String?) -> Bool {
        kind == "minor_road" && detail == "service"
    }

    /// The style of one of the extras' service roads, by its `service`:
    /// absent on a road that serves a place.
    static func serviceRoad(service: String?) -> Road? {
        road(kind: "minor_road", detail: "service", service: service)
    }

    /// The `service` values of a service road Carto draws as a minor one:
    /// narrower, and not before zoom 16.
    static let minorServices: Set<String> = ["parking_aisle", "driveway", "drive-through"]

    /// The `service` values of a railway's minor trackage, which Carto draws
    /// lighter and thinner than the line it serves, and not before zoom 13:
    /// a station's sidings, a yard, the spur into a works.
    static let sidingServices: Set<String> = ["spur", "siding", "yard"]

    /// The look of each class of railway's minor trackage: a main line's
    /// keeps its dashes, in a paler gray; every other class shares one thin
    /// line, a tram's from zoom 15 and the rest from 14.
    private static let sidings: [String: Line] = [
        "rail": railSiding,
        "tram": tramSiding,
        "light_rail": minorTrackage,
        "funicular": minorTrackage,
        "narrow_gauge": minorTrackage,
        "monorail": minorTrackage,
        "subway": subwaySiding,
    ]

    /// Carto draws a closed path from this zoom, and an open one before it.
    static let closedPathZ = 15

    /// The `access` values that close a way to the public, as Carto reads
    /// them (`carto_int_access` in its `functions.sql`).
    static let closingAccess: Set<String> = [
        "no", "private", "permit", "agricultural", "forestry", "agricultural;forestry",
    ]

    /// Keyed `kind/kind_detail`, with `kind/*` for every detail not listed,
    /// and listed in the order they are drawn: OpenStreetMap Carto's
    /// `z_order`, so the more important road's surface runs through a
    /// junction. The archive cannot say this: it gives every road the same
    /// `sort_rank`.
    ///
    /// Links come under every street, as Carto has them, and runways,
    /// railways and lifts over the roads they cross. The archive files a
    /// highway it has no kind for as `other`, with the highway as its detail:
    /// of those only the living street, a street people walk down, is drawn.
    ///
    /// The archive files every way with a `railway` tag as `rail`, with the
    /// tag's value as its detail: a station's outline, a turntable, a
    /// ventilation shaft. Only the details that are track are listed, so the
    /// rest is not drawn as track. A lift is drawn by its kind too: the
    /// basemap keeps the cable cars and the vector extras bring the rest.
    private static let roads: [String: Road] = Dictionary(
        uniqueKeysWithValues: [
            ("ferry/*", ferry),
            ("minor_road/service", service),
            ("major_road/tertiary_link", tertiary),
            ("major_road/secondary_link", secondary),
            ("major_road/primary_link", primary),
            ("major_road/trunk_link", trunk),
            ("highway/motorway_link", motorway),
            ("path/pedestrian", pedestrian),
            ("other/living_street", livingStreet),
            ("minor_road/*", minorRoad),
            ("major_road/*", tertiary),
            ("major_road/secondary", secondary),
            ("major_road/primary", primary),
            ("major_road/trunk", trunk),
            ("highway/*", motorway),
            ("aeroway/taxiway", taxiway),
            ("aeroway/runway", runway),
            ("rail/subway", subway),
            ("rail/disused", disusedRailway),
            ("rail/miniature", miniatureRailway),
            ("rail/tram", tram),
            ("rail/light_rail", lightRail),
            ("rail/narrow_gauge", lightRail),
            ("rail/funicular", lightRail),
            ("rail/monorail", lightRail),
            ("rail/preserved", railway),
            ("rail/rail", railway),
            ("aerialway/goods", goodsLift),
            ("aerialway/cable_car", cabinLift),
            ("aerialway/gondola", cabinLift),
            ("aerialway/mixed_lift", cabinLift),
            ("aerialway/*", chairLift),
        ].enumerated().map { order, entry in
            (entry.0, Road(line: entry.1, order: order, far: farRoads[entry.0]))
        }
    )

    /// Carto's look for a secondary and a tertiary road before zoom 12: a
    /// thin line in the gray of an unimportant road, where their own pale
    /// yellow and white would be lost on the ground.
    private static let farRoads: [String: Line] = [
        "major_road/secondary": Line(
            color: unimportantRoad,
            width: ZoomCurve([(9, 1), (10, farSecondary), (11, farSecondary)])
        ),
        "major_road/*": Line(color: unimportantRoad, width: ZoomCurve([(10, farTertiary), (11, farTertiary)])),
    ]
    private static let unimportantRoad = color("#BBBBBB")
    private static let farSecondary: CGFloat = 1.1
    private static let farTertiary: CGFloat = 0.7

    // MARK: Roads being built

    /// A road being built, from the extras' `construction` layer: the color
    /// of the road it is to be, a minor one's in gray, with dashes down it
    /// in the color of the road's own surface (`roads.mss`'s
    /// `highway_construction`). A service road's `service` is given where it
    /// makes it a minor one, which Carto draws narrower and not before zoom
    /// 17. `nil` for a kind Carto draws no such line for, and before the
    /// zoom it first draws one.
    static func construction(kind: String?, z: Int, service: String? = nil) -> Line? {
        guard let kind, let listed = constructionClasses[kind] else { return nil }
        let shapes = kind == "service" && service.map(minorServices.contains) == true
            ? minorServiceConstruction
            : listed.shapes
        guard let shape = shapes.last(where: { z >= $0.z }) else { return nil }
        return Line(
            color: listed.color,
            width: ZoomCurve([(z, shape.width)]),
            center: Center(
                color: listed.center,
                width: ZoomCurve([(z, shape.dashes)]),
                dash: [shape.dash / shape.dashes, shape.gap / shape.dashes]
            )
        )
    }

    /// The look of one class of road being built: the line's color, its
    /// dashes', and its shape from each zoom.
    private struct ConstructionClass {
        let color: CGColor
        var center = VectorTileStyle.color("#FFFFFF")
        let shapes: [ConstructionShape]
    }

    private static let constructionGray = color("#AAAAAA")
    private static let constructionClasses: [String: ConstructionClass] = {
        let major = { (line: Line) in ConstructionClass(color: line.color, shapes: majorConstruction) }
        let minor = ConstructionClass(color: constructionGray, shapes: minorConstruction)
        return [
            "motorway": major(motorway),
            "motorway_link": major(motorway),
            "trunk": major(trunk),
            "trunk_link": major(trunk),
            "primary": major(primary),
            "primary_link": major(primary),
            "secondary": major(secondary),
            "secondary_link": major(secondary),
            "tertiary": ConstructionClass(color: constructionGray, shapes: majorConstruction),
            "tertiary_link": ConstructionClass(color: constructionGray, shapes: majorConstruction),
            "residential": minor,
            "unclassified": minor,
            "living_street": ConstructionClass(
                color: constructionGray,
                center: livingStreet.color,
                shapes: minorConstruction
            ),
            "pedestrian": ConstructionClass(
                color: constructionGray,
                center: pedestrian.color,
                shapes: minorConstruction
            ),
            "service": ConstructionClass(color: constructionGray, shapes: serviceConstruction),
            "road": ConstructionClass(color: constructionGray, center: unpavedRoad, shapes: serviceConstruction),
            "raceway": ConstructionClass(color: constructionGray, center: unpavedRoad, shapes: serviceConstruction),
        ]
    }()
    /// Carto's `@road-fill`, the surface of a road of unknown class.
    private static let unpavedRoad = color("#DDDDDD")

    /// From zoom `z`: the line's width, the width of the dashes down it,
    /// and their dash and gap, in pixels.
    private struct ConstructionShape {
        let z: Int
        let width: CGFloat
        let dashes: CGFloat
        let dash: CGFloat
        let gap: CGFloat
    }

    private static let majorConstruction = [
        ConstructionShape(z: 12, width: 2, dashes: 2, dash: 4, gap: 2),
        ConstructionShape(z: 13, width: 4, dashes: majorDashes, dash: 6, gap: 4),
        ConstructionShape(z: 16, width: 8, dashes: 7, dash: 8, gap: 6),
    ]
    private static let minorConstruction = [
        ConstructionShape(z: 14, width: 3, dashes: 2, dash: 6, gap: 4),
        ConstructionShape(z: 15, width: 5, dashes: minorDashesZ15, dash: 6, gap: 4),
        ConstructionShape(z: 16, width: 6, dashes: minorDashesZ16, dash: 8, gap: 6),
        ConstructionShape(z: z17, width: 8, dashes: 7, dash: 8, gap: 6),
    ]
    /// A service road's and a road's of unknown class, from zoom 15, the
    /// dashes as wide as the line at first.
    private static let serviceConstruction = [
        ConstructionShape(z: 15, width: 2, dashes: 2, dash: 6, gap: 4),
        ConstructionShape(z: 16, width: serviceZ16.width, dashes: serviceZ16.dashes, dash: 8, gap: 6),
        ConstructionShape(z: z17, width: 7, dashes: serviceZ17Dashes, dash: 8, gap: 6),
        ConstructionShape(z: z18, width: 8, dashes: 7, dash: 8, gap: 6),
    ]
    /// A driveway's, a parking aisle's and a drive-through's, from zoom 17.
    private static let minorServiceConstruction = [
        ConstructionShape(z: z17, width: minorServiceZ17.width, dashes: minorServiceZ17.dashes, dash: 8, gap: 6),
        ConstructionShape(z: z18, width: minorServiceZ18.width, dashes: minorServiceZ18.dashes, dash: 8, gap: 6),
        ConstructionShape(z: z19, width: minorServiceZ19.width, dashes: minorServiceZ19.dashes, dash: 8, gap: 6),
    ]
    private static let majorDashes: CGFloat = 3.5
    private static let minorDashesZ15: CGFloat = 3.8
    private static let minorDashesZ16: CGFloat = 4.8
    private static let serviceZ16: (width: CGFloat, dashes: CGFloat) = (3.5, 2.3)
    private static let serviceZ17Dashes: CGFloat = 5.4
    private static let minorServiceZ17: (width: CGFloat, dashes: CGFloat) = (3.5, 1.9)
    private static let minorServiceZ18: (width: CGFloat, dashes: CGFloat) = (4.75, 3.15)
    private static let minorServiceZ19: (width: CGFloat, dashes: CGFloat) = (3.9, 2.3)

    // MARK: Power lines' towers

    /// A tower or a pole of a power line, as a square of `side` pixels: a
    /// tower's with Carto's white eye, and from zoom 15 its cross.
    struct PowerPoint: Sendable {
        let color: CGColor
        let side: CGFloat
        /// The white eye's width, or zero for none.
        let eye: CGFloat
        let hasCross: Bool
    }

    static let powerPointEye = color("#FFFFFF")
    /// How many of the cross's strokes side by side would fill the square.
    static let powerPointCrossShare: CGFloat = 13

    /// The mark of a feature in the extras' `power_points` layer
    /// (`power.mss`): a tower from zoom 14, larger from 15 and from 17, and
    /// a pole from 16.
    static func powerPoint(kind: String?, z: Int) -> PowerPoint? {
        switch kind {
        case "tower" where z == towerZ:
            return PowerPoint(color: towerGray, side: 3, eye: 1, hasCross: false)
        case "tower" where z > towerZ:
            return PowerPoint(color: towerGray, side: z >= z17 ? 7 : 5, eye: z >= z17 ? 5 : towerEye, hasCross: true)
        case "pole" where z >= poleZ:
            return PowerPoint(color: color("#928F8F"), side: 3, eye: 0, hasCross: false)
        default:
            return nil
        }
    }

    private static let towerZ = 14
    private static let poleZ = 16
    private static let towerGray = color("#868686")
    /// The eye of a tower five pixels across: five sevenths of it, as the
    /// seven-pixel one's is.
    private static let towerEye: CGFloat = 3.6
}

// MARK: - The figures

nonisolated private extension VectorTileStyle {
    static let motorway = Line(
        color: color("#E892A2"),
        width: ZoomCurve([(5, 0.5), (8, 1), (10, 2), (12, 3), (14, 6), (16, 12), (20, 48)]),
        casing: color("#DC2A67")
    )
    static let trunk = Line(
        color: color("#F9B29C"),
        width: ZoomCurve([(6, 0.5), (9, 1), (11, 2), (12, 3), (14, 5), (16, 10), (20, 40)]),
        casing: color("#C84E2F")
    )
    static let primary = Line(
        color: color("#FCD6A4"),
        width: ZoomCurve([(8, 0.5), (10, 1), (12, 2), (14, 5), (16, 9), (20, 36)]),
        casing: color("#A06B00")
    )
    static let secondary = Line(
        color: color("#F7FABF"),
        width: ZoomCurve([(9, 0.5), (11, 1), (12, 2), (14, 4), (16, 8), (20, 32)]),
        casing: color("#707D05")
    )
    /// Tertiary and every other major road.
    static let tertiary = Line(
        color: color("#FFFFFF"),
        width: ZoomCurve([(10, 0.5), (12, 1), (14, 4), (16, 7), (20, 25)]),
        casing: color("#8F8F8F")
    )
    /// From zoom 14, where Carto first draws one.
    static let service = Line(
        color: color("#FFFFFF"),
        width: ZoomCurve([(14, 1), (16, 3), (20, 12)]),
        casing: color("#BBBBBB")
    )
    static let minorRoad = Line(
        color: color("#FFFFFF"),
        width: ZoomCurve([(12, 0.5), (13, 1), (14, 2), (16, 6), (20, 24)]),
        casing: color("#BBBBBB")
    )
    /// A minor road in Carto's paler gray.
    static let livingStreet = Line(
        color: color("#EDEDED"),
        width: ZoomCurve([(12, 0.5), (13, 1), (14, 2), (16, 6), (20, 24)]),
        casing: color("#BBBBBB")
    )
    static let pedestrian = Line(
        color: color("#DDDDE8"),
        width: ZoomCurve([(13, 1), (14, 2), (16, 6), (20, 24)]),
        casing: color("#999999")
    )
    static let subway = Line(color: color("#999999"), width: ZoomCurve([(12, 0.5), (16, 1)]), alpha: 0.5)
    /// Carto's railway: a gray line with white dashes down it from zoom 12,
    /// a thin gray one before.
    static let railway = Line(
        color: color("#707070"),
        width: ZoomCurve([(10, 0.5), (11, 1), (12, 2), (13, 3), (z17, 3), (z18, 4)]),
        center: Center(
            color: color("#FFFFFF"),
            width: ZoomCurve([(12, 0.75), (13, 1), (z17, 1), (z18, 2)]),
            dash: [8, 8]
        )
    )
    static let tram = Line(color: color("#6E6E6E"), width: ZoomCurve([(12, 0.75), (14, 1), (z17, 2)]))
    /// A main line's sidings: paler, a pixel narrower, the dashes kept.
    static let railSiding = Line(
        color: color("#AAAAAA"),
        width: ZoomCurve([(13, 2), (z17, 2), (z18, 3)]),
        center: Center(
            color: color("#FFFFFF"),
            width: ZoomCurve([(13, sidingCenter), (z17, sidingCenter), (z18, 1)]),
            dash: [10, 10]
        )
    )
    static let sidingCenter: CGFloat = 0.8
    static let tramSidingZ = 15
    static let minorTrackageWidth = ZoomCurve([(14, 0.5), (16, 0.5), (z17, 1), (z18, minorTrackageZ18), (z19, 2)])
    static let minorTrackageZ18: CGFloat = 1.5
    static let minorTrackage = Line(color: color("#6E6E6E"), width: minorTrackageWidth)
    static let tramSiding = Line(color: color("#6E6E6E"), width: minorTrackageWidth.starting(at: tramSidingZ))
    static let subwaySiding = Line(
        color: color("#999999"),
        width: ZoomCurve([(14, 0.75), (16, 0.75), (z17, 1), (z18, minorTrackageZ18), (z19, 2)])
    )
    /// Carto draws an unused line light and broken, and only up close.
    static let disusedRailway = Line(color: color("#AAAAAA"), width: ZoomCurve([(15, 2)]), dash: [1, 2])
    static let ferry = Line(color: color("#6666FF"), width: ZoomCurve([(8, 0.5), (12, 1), (16, 2)]), dash: [6, 4])

    /// A service road Carto draws as a minor one (`@minor-service-width`).
    static let minorServiceWidthZ17: CGFloat = 3.5
    static let minorServiceWidthZ18: CGFloat = 4.75
    static let minorServiceWidthZ19: CGFloat = 5.5
    static let minorService = Line(
        color: color("#FFFFFF"),
        width: ZoomCurve([
            (16, 2), (z17, minorServiceWidthZ17), (z18, minorServiceWidthZ18), (z19, minorServiceWidthZ19),
        ]),
        casing: color("#BBBBBB")
    )

    /// Carto's `#aeroways`: a runway and a taxiway in one blue-gray, from
    /// zoom 11.
    static let aerowayFill = color("#BBBBCC")
    static let runwayWidthZ15: CGFloat = 18
    static let runway = Line(
        color: aerowayFill,
        width: ZoomCurve([(11, 2), (12, 4), (13, 6), (14, 12), (15, runwayWidthZ15), (16, 24)])
    )
    static let taxiway = Line(
        color: aerowayFill,
        width: ZoomCurve([(11, 1), (12, 1), (13, 2), (14, 4), (15, 6), (16, 8)])
    )

    /// A light railway, a narrow-gauge line or a funicular: a plain gray
    /// line, paler the wider the map.
    static let lightRail = Line(color: color("#666666"), width: ZoomCurve([(10, 0.75), (12, 1), (13, 2)]))
    static let miniatureRailway = Line(color: color("#999999"), width: ZoomCurve([(15, 1), (z17, 2)]))

    /// Carto's lifts (`aerialways.mss`), each a thin gray line from zoom 12
    /// with marks along it: dots for the cabins of a cable car or a gondola,
    /// long gray marks for a goods lift, and ticks for the chairs and bars
    /// of every other kind.
    static let liftGray = color("#808080")
    static let liftInk = color("#000000")
    static let liftWidth = ZoomCurve([(12, 1)])
    /// Carto's dash and gap for each, in pixels, which a mark's own width
    /// divides into the multiples of it a ``Center`` is given.
    static let cabinDash: (dot: CGFloat, gap: CGFloat, width: CGFloat) = (0.4, 13, 3)
    static let goodsDash: (mark: CGFloat, gap: CGFloat, width: CGFloat) = (6, 25, 3.5)
    static let chairDash: (tick: CGFloat, gap: CGFloat, width: CGFloat) = (1, 30, 4)
    static let cabinLift = Line(
        color: liftGray,
        width: liftWidth,
        center: Center(
            color: liftInk,
            width: ZoomCurve([(12, cabinDash.width)]),
            dash: [cabinDash.dot / cabinDash.width, cabinDash.gap / cabinDash.width],
            cap: .round
        )
    )
    static let goodsLift = Line(
        color: liftGray,
        width: liftWidth,
        center: Center(
            color: color("#707070"),
            width: ZoomCurve([(12, goodsDash.width)]),
            dash: [goodsDash.mark / goodsDash.width, goodsDash.gap / goodsDash.width]
        )
    )
    static let chairLift = Line(
        color: liftGray,
        width: liftWidth,
        center: Center(
            color: liftInk,
            width: ZoomCurve([(12, chairDash.width)]),
            dash: [chairDash.tick / chairDash.width, chairDash.gap / chairDash.width]
        )
    )
}
