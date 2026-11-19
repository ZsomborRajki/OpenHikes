//
//  VectorTileRoadStyle.swift
//  OpenHikes
//
//  What the map draws each road, path, railway and lift as: the `roads`
//  layer of the Protomaps basemap, and the lifts and light railways the
//  vector extras add to it. Colors and widths are OpenStreetMap Carto's
//  (`roads.mss`, `aerialways.mss`), in the pixels of a 256-pixel tile, as the
//  rest of ``VectorTileStyle`` is.
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
        /// The look where the way's `access` closes it, for the kinds Carto
        /// draws a closed one of differently.
        var closed: Line?
    }

    /// The style of a feature in the `roads` layer, or `nil` for one not drawn
    /// as a road: its `kind` and `kind_detail` first, then its `kind` alone.
    /// A pier is drawn with the water (``isPier(kind:detail:)``). A path,
    /// track or flight of steps whose `access` closes it is drawn as Carto
    /// draws one: paler, and not before ``closedPathZ``. A service road
    /// whose `service` makes it a minor one is drawn as Carto draws those.
    ///
    /// Carto reads a path's `foot` (or `bicycle`, or `horse`) before its
    /// `access`, and the archive carries `access` alone, so a path closed to
    /// all but walkers is drawn closed. The archive carries `access` from
    /// zoom 15, where Carto starts drawing closed paths, and leaves out a
    /// way with `access=no` or `private` before it.
    static func road(kind: String, detail: String?, access: String? = nil, service: String? = nil) -> Road? {
        guard !isPier(kind: kind, detail: detail),
              let listed = roads["\(kind)/\(detail ?? "")"] ?? roads["\(kind)/*"]
        else { return nil }
        var road = listed
        if kind == "minor_road", detail == "service", let service, minorServices.contains(service) {
            road = Road(line: minorService, order: listed.order)
        }
        guard let access, closingAccess.contains(access), let closed = road.closed else { return road }
        return Road(line: closed, order: road.order)
    }

    /// The `service` values of a service road Carto draws as a minor one:
    /// narrower, and not before zoom 16.
    static let minorServices: Set<String> = ["parking_aisle", "driveway", "drive-through"]

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
            ("path/steps", steps),
            ("path/*", footpath),
            ("path/cycleway", cycleway),
            ("path/bridleway", bridleway),
            ("path/track", track),
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
            (entry.0, Road(line: entry.1, order: order, closed: closedPaths[entry.0]))
        }
    )

    /// Carto's look for each kind of path where its `access` closes it:
    /// `roads.mss`'s `-fill-noaccess` colors, and nothing before
    /// ``closedPathZ``, where Carto still draws only the open ones.
    private static let closedPaths: [String: Line] = [
        "path/steps": steps.closed("#BBBBBB"),
        "path/*": footpath.closed("#BBBBBB"),
        "path/cycleway": cycleway.closed("#9999FF"),
        "path/bridleway": bridleway.closed("#AADDAA"),
        "path/track": track.closed("#E2C5BB"),
    ]
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
    static let service = Line(
        color: color("#FFFFFF"),
        width: ZoomCurve([(13, 0.5), (14, 1), (16, 3), (20, 12)]),
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
    static let track = Line(
        color: color("#996600"),
        width: ZoomCurve([(12, 0.5), (14, 1), (16, 2), (20, 3)]),
        dash: [5, 3]
    )
    static let steps = Line(
        color: color("#FA8072"),
        width: ZoomCurve([(13, 1), (15, 2), (20, 4)]),
        dash: [1, 1]
    )
    static let cycleway = Line(
        color: color("#0000FF"),
        width: ZoomCurve([(13, 0.5), (15, 1), (20, 2)]),
        dash: [1, 3]
    )
    static let bridleway = Line(
        color: color("#008000"),
        width: ZoomCurve([(13, 0.5), (15, 1), (20, 2)]),
        dash: [4, 2]
    )
    static let pedestrian = Line(
        color: color("#DDDDE8"),
        width: ZoomCurve([(13, 1), (14, 2), (16, 6), (20, 24)]),
        casing: color("#999999")
    )
    /// Footways, paths and every path kind not listed: what a hiker walks.
    static let footpath = Line(
        color: color("#FA8072"),
        width: ZoomCurve([(12, 0.5), (14, 0.75), (16, 1), (20, 2)]),
        dash: [2, 3]
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

nonisolated private extension VectorTileStyle.Line {
    /// This path as Carto draws it where its `access` closes it: in `hex`,
    /// and not before ``VectorTileStyle/closedPathZ``.
    func closed(_ hex: String) -> Self {
        Self(
            color: VectorTileStyle.color(hex),
            width: width.starting(at: VectorTileStyle.closedPathZ),
            casing: casing,
            dash: dash,
            alpha: alpha,
            center: center
        )
    }
}
