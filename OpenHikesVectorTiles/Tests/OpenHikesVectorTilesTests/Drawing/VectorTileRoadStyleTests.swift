//
//  VectorTileRoadStyleTests.swift
//  OpenHikesVectorTilesTests
//
//  Which of the archive's roads, railways and lifts are drawn, and as what:
//  the kinds that are track and the ones that only carry a `railway` tag, a
//  runway, a lift's marks, a service road that is a parking aisle, and the
//  lines of the vector extras' own layers.
//

import CoreGraphics
import Foundation
@testable import OpenHikesVectorTiles
import Testing

@Suite("Vector tile road style")
struct VectorTileRoadStyleTests {
    /// The archive files every way with a `railway` tag as `rail`: a
    /// station's outline was drawn as a ring of track around it.
    @Test("only track is drawn as a railway", arguments: [
        "station", "turntable", "traverser", "ventilation_shaft", "wash", "platform", "signal_box", "",
    ])
    func notTrack(detail: String) {
        #expect(VectorTileStyle.road(kind: "rail", detail: detail) == nil)
        #expect(VectorTileStyle.road(kind: "rail", detail: nil) == nil)
    }

    @Test("a main line carries its white dashes, and a narrow-gauge line, a light railway or a funicular none")
    func railwayLooks() throws {
        let mainLine = try #require(VectorTileStyle.road(kind: "rail", detail: "rail"))
        #expect(mainLine.line.center != nil)
        for detail in ["narrow_gauge", "light_rail", "funicular", "monorail"] {
            let light = try #require(VectorTileStyle.road(kind: "rail", detail: detail), "\(detail)")
            #expect(light.line.center == nil, "\(detail)")
            #expect(light.line.width.value(at: 14) < mainLine.line.width.value(at: 14), "\(detail)")
        }
        #expect(VectorTileStyle.road(kind: "rail", detail: "tram") != nil)
        #expect(VectorTileStyle.road(kind: "rail", detail: "subway") != nil)
        #expect(VectorTileStyle.road(kind: "rail", detail: "disused") != nil)
    }

    /// A marshalling yard drawn as main line was a black slab beside its
    /// station.
    @Test("a railway's sidings are drawn paler and narrower than its line, from zoom 13", arguments: [
        "spur", "siding", "yard",
    ])
    func sidings(service: String) throws {
        let mainLine = try #require(VectorTileStyle.road(kind: "rail", detail: "rail"))
        let siding = try #require(VectorTileStyle.road(kind: "rail", detail: "rail", service: service))

        #expect(siding.line.width.value(at: 12) == 0)
        #expect(siding.line.width.value(at: 13) > 0)
        #expect(siding.line.width.value(at: 13) < mainLine.line.width.value(at: 13))
        #expect(siding.line.color != mainLine.line.color)
        #expect(siding.line.center != nil, "the dashes are kept")
        #expect(siding.order == mainLine.order)
    }

    @Test("a tram's sidings wait for zoom 15 and a light railway's for 14; any other service is the line itself")
    func minorTrackage() throws {
        let depot = try #require(VectorTileStyle.road(kind: "rail", detail: "tram", service: "yard"))
        let loop = try #require(VectorTileStyle.road(kind: "rail", detail: "light_rail", service: "siding"))
        let lightRail = try #require(VectorTileStyle.road(kind: "rail", detail: "light_rail"))
        let crossover = try #require(VectorTileStyle.road(kind: "rail", detail: "light_rail", service: "crossover"))

        #expect(depot.line.width.value(at: 14) == 0)
        #expect(depot.line.width.value(at: 15) > 0)
        #expect(loop.line.width.value(at: 13) == 0)
        #expect(loop.line.width.value(at: 14) > 0)
        #expect(loop.line.width.value(at: 14) < lightRail.line.width.value(at: 14))
        #expect(crossover.line.width.value(at: 14) == lightRail.line.width.value(at: 14))
        #expect(VectorTileStyle.road(kind: "rail", detail: "station", service: "yard") == nil)
    }

    @Test("a runway and a taxiway are drawn from zoom 11, the runway wider, both over the roads")
    func aeroways() throws {
        let runway = try #require(VectorTileStyle.road(kind: "aeroway", detail: "runway"))
        let taxiway = try #require(VectorTileStyle.road(kind: "aeroway", detail: "taxiway"))
        let motorway = try #require(VectorTileStyle.road(kind: "highway", detail: "motorway"))

        #expect(runway.line.width.value(at: 10) == 0)
        #expect(runway.line.width.value(at: 11) > 0)
        #expect(runway.line.width.value(at: 14) > taxiway.line.width.value(at: 14))
        #expect(taxiway.order > motorway.order)
        #expect(VectorTileStyle.road(kind: "aeroway", detail: "apron") == nil)
    }

    @Test("every lift is drawn from zoom 12, with marks down its line", arguments: [
        "cable_car", "gondola", "mixed_lift", "goods", "chair_lift", "drag_lift", "t-bar", "platter",
    ])
    func lifts(detail: String) throws {
        let lift = try #require(VectorTileStyle.road(kind: "aerialway", detail: detail))
        let marks = try #require(lift.line.center)

        #expect(lift.line.width.value(at: 11) == 0)
        #expect(lift.line.width.value(at: 12) > 0)
        #expect(marks.dash.count == 2, "a mark and the gap to the next")
        #expect(marks.width.value(at: 12) > lift.line.width.value(at: 12))
    }

    @Test("a cable car's and a gondola's marks are dots; a chair lift's are ticks")
    func liftMarks() throws {
        let gondola = try #require(VectorTileStyle.road(kind: "aerialway", detail: "gondola")?.line.center)
        let chairLift = try #require(VectorTileStyle.road(kind: "aerialway", detail: "chair_lift")?.line.center)

        #expect(gondola.cap == .round)
        #expect(chairLift.cap == .butt)
    }

    @Test("a parking aisle or a driveway is a minor service road: narrower, and not before zoom 16", arguments: [
        "parking_aisle", "driveway", "drive-through",
    ])
    func minorService(service: String) throws {
        let plain = try #require(VectorTileStyle.road(kind: "minor_road", detail: "service"))
        let minor = try #require(VectorTileStyle.road(kind: "minor_road", detail: "service", service: service))

        #expect(plain.line.width.value(at: 14) > 0)
        #expect(minor.line.width.value(at: 15) == 0)
        #expect(minor.line.width.value(at: 16) > 0)
        #expect(minor.line.width.value(at: 16) < plain.line.width.value(at: 16))
        #expect(minor.order == plain.order)
    }

    @Test("a service road with another service, and a street that carries the tag, are drawn as before")
    func otherServices() throws {
        let plain = try #require(VectorTileStyle.road(kind: "minor_road", detail: "service"))
        let alley = try #require(VectorTileStyle.road(kind: "minor_road", detail: "service", service: "alley"))
        let street = try #require(VectorTileStyle.road(kind: "minor_road", detail: "residential", service: "driveway"))

        #expect(alley.line.width.value(at: 14) == plain.line.width.value(at: 14))
        #expect(street.line.width.value(at: 14) > 0)
    }

    // MARK: The extras' own lines

    @Test("a power line is drawn from zoom 14 and a minor one from 16")
    func powerLines() {
        #expect(VectorTileStyle.powerLine(kind: "line").width.value(at: 13) == 0)
        #expect(VectorTileStyle.powerLine(kind: "line").width.value(at: 14) > 0)
        #expect(VectorTileStyle.powerLine(kind: "minor_line").width.value(at: 15) == 0)
        #expect(VectorTileStyle.powerLine(kind: "minor_line").width.value(at: 16) > 0)
    }

    @Test("a dam, a weir and a lock gate are drawn from zoom 13, the weir broken")
    func waterBarriers() {
        for kind in ["dam", "weir", "lock_gate"] {
            #expect(VectorTileStyle.waterBarrier(kind: kind).width.value(at: 12) == 0, "\(kind)")
            #expect(VectorTileStyle.waterBarrier(kind: kind).width.value(at: 13) > 0, "\(kind)")
        }
        #expect(!VectorTileStyle.waterBarrier(kind: "weir").dash.isEmpty)
        #expect(VectorTileStyle.waterBarrier(kind: "dam").dash.isEmpty)
    }

    @Test("a ridge is drawn broken and an arête unbroken, both from zoom 14")
    func ridges() {
        #expect(VectorTileStyle.ridge(kind: "ridge").width.value(at: 13) == 0)
        #expect(VectorTileStyle.ridge(kind: "ridge").width.value(at: 14) > 0)
        #expect(!VectorTileStyle.ridge(kind: "ridge").dash.isEmpty)
        #expect(VectorTileStyle.ridge(kind: "arete").dash.isEmpty)
    }

    @Test("a protected area's border is a line from zoom 8, with a band inside it from zoom 10")
    func protectedBorders() {
        let border = VectorTileStyle.protectedBorder(kind: "protected_area")

        #expect(border.line.value(at: 7) == 0)
        #expect(border.line.value(at: 8) > 0)
        #expect(border.band.value(at: 9) == 0)
        #expect(border.band.value(at: 10) > border.line.value(at: 10))
        #expect(border.alpha.value(at: 8) > border.alpha.value(at: 10), "fainter once the band joins the line")
        #expect(VectorTileStyle.protectedBorder(kind: "aboriginal_lands").color != border.color)
    }

    // MARK: The ground

    /// The basemap files most national parks as a park, so a park's fill is
    /// kept for the vector extras' own parks layer.
    @Test("the basemap's park has no fill of its own")
    func parkIsNotLanduse() {
        #expect(VectorTileStyle.landuseFills["park"] == nil)
        #expect(VectorTileStyle.landuseFills["national_park"] == nil)
    }

    @Test("the ground the extras bring has Carto's fills", arguments: [
        "scree", "heath", "shingle", "retail", "quarry", "vineyard", "orchard", "farmyard", "construction",
        "landfill", "garages", "camp_site", "grave_yard", "stadium", "track", "power", "apron", "rest_area",
    ])
    func extrasGround(kind: String) {
        #expect(VectorTileStyle.landuseFills[kind] != nil)
    }

    @Test("heath is not scrub's green, and a farmyard not farmland's")
    func distinctGround() {
        #expect(VectorTileStyle.landuseFills["heath"] != VectorTileStyle.landuseFills["scrub"])
        #expect(VectorTileStyle.landuseFills["farmyard"] != VectorTileStyle.landuseFills["farmland"])
    }

    // MARK: The extras' schema

    private func schema() throws -> String {
        try String(
            contentsOf: Checkout.extrasSchema,
            encoding: .utf8
        )
    }

    /// A layer the extras build and the app never asks its decoder for is
    /// megabytes on the server that no tile draws.
    @Test("every layer the extras build is one the rasterizer reads")
    func extrasLayersAreRead() throws {
        let layers = try schema().split(separator: "\n")
            .filter { $0.hasPrefix("- id: ") }
            .map { String($0.dropFirst("- id: ".count)) }

        #expect(layers.count > 8)
        #expect(Set(layers).isSubset(of: VectorTileRasterizer.layerNames))
    }

    @Test("every lift and light railway the extras keep has a line to be drawn with")
    func extrasLinesHaveStyles() throws {
        let lines = try schema().split(separator: "\n")
        let lifts = try #require(lines.first { $0.contains("aerialway: [gondola") })
        let railways = lines.filter { $0.contains("railway: [narrow_gauge") || $0.contains("railway: [tram") }
        let values = { (line: Substring) -> [String] in
            let list = line.split(separator: "[").last?.split(separator: "]").first ?? ""
            return list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }

        #expect(values(lifts).count > 8)
        for lift in values(lifts) {
            #expect(VectorTileStyle.road(kind: "aerialway", detail: lift) != nil, "\(lift)")
        }
        #expect(railways.count == 2)
        for railway in railways.flatMap(values) {
            #expect(VectorTileStyle.road(kind: "rail", detail: railway) != nil, "\(railway)")
        }
    }
}
