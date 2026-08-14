//
//  MercatorTests.swift
//  OpenHikesSharedTests
//
//  `Mercator` replaced hand-written `tan`/`log` in two shipped places at
//  once — tile indices (which decide what gets downloaded for offline use)
//  and the widget's basemap registration. The first group of tests below is
//  the regression net for that: the original formulas, kept verbatim, and
//  checked against the shared ones over the whole world.
//

import Foundation
@testable import OpenHikesShared
import Testing

// The formulas `SlippyTileMath` used before `Mercator` existed. Kept exactly
// as they were — if these ever disagree with the shared implementation, tiles
// move, and a user's saved offline maps stop covering their trail.
private enum LegacyTileMath {
    static func tileX(_ lon: Double, z: Int) -> Int { Int(floor((lon + 180) / 360 * Double(1 << z))) }

    static func tileY(_ lat: Double, z: Int) -> Int {
        let r = lat * .pi / 180
        return Int(floor((1 - log(tan(r) + 1 / cos(r)) / .pi) / 2 * Double(1 << z)))
    }

    static func lon(x: Int, z: Int) -> Double { Double(x) / Double(1 << z) * 360 - 180 }

    static func lat(y: Int, z: Int) -> Double {
        let n = .pi - 2 * .pi * Double(y) / Double(1 << z)
        return 180 / .pi * atan(0.5 * (exp(n) - exp(-n)))
    }
}

@Suite("Mercator")
struct MercatorTests {
    /// Every zoom the app actually uses, against every provider's maximum.
    static let zoomLevels = [0, 5, 10, 14, 17, 19, 20, 22]

    /// Seeded per zoom level, so a coordinate the two formulas disagree on can
    /// be generated again — re-run with `OPENHIKES_TEST_SEED` set to the seed
    /// quoted in the failure.
    @Test("tile indices match the formulas they replaced", arguments: zoomLevels)
    func tileIndicesUnchanged(z: Int) {
        var generator = SeededGenerator(seed: SeededGenerator.defaultSeed &+ UInt64(z))
        let seed = generator.seed
        for _ in 0..<20_000 {
            let latitude = Double.random(in: -Mercator.latitudeLimit...Mercator.latitudeLimit, using: &generator)
            let longitude = Double.random(in: -180...180, using: &generator)
            #expect(
                Int(floor(Mercator.unitX(longitude: longitude) * Double(1 << z)))
                    == LegacyTileMath.tileX(longitude, z: z),
                "longitude \(longitude) at z\(z) (seed \(seed))"
            )
            #expect(
                Int(floor(Mercator.unitY(latitude: latitude) * Double(1 << z)))
                    == LegacyTileMath.tileY(latitude, z: z),
                "latitude \(latitude) at z\(z) (seed \(seed))"
            )
        }
    }

    @Test("tile edge coordinates match the formulas they replaced", arguments: zoomLevels)
    func tileEdgesUnchanged(z: Int) {
        let n = 1 << z
        for index in stride(from: 0, to: n, by: max(1, n / 512)) {
            #expect(
                abs(Mercator.longitude(unitX: Double(index) / Double(n)) - LegacyTileMath.lon(x: index, z: z)) < 1e-9
            )
            #expect(
                abs(Mercator.latitude(unitY: Double(index) / Double(n)) - LegacyTileMath.lat(y: index, z: z)) < 1e-9
            )
        }
    }

    @Test("projection round trips")
    func roundTrip() {
        var generator = SeededGenerator()
        let seed = generator.seed
        for _ in 0..<10_000 {
            let latitude = Double.random(in: -85...85, using: &generator)
            let longitude = Double.random(in: -180...180, using: &generator)
            let unit = Mercator.unitPoint(latitude: latitude, longitude: longitude)
            #expect(abs(Mercator.latitude(unitY: unit.y) - latitude) < 1e-9, "latitude \(latitude) (seed \(seed))")
            #expect(abs(Mercator.longitude(unitX: unit.x) - longitude) < 1e-9, "longitude \(longitude) (seed \(seed))")
        }
    }

    @Test("the world is a unit square")
    func worldBounds() {
        #expect(abs(Mercator.unitY(latitude: Mercator.latitudeLimit)) < 1e-9)
        #expect(abs(Mercator.unitY(latitude: -Mercator.latitudeLimit) - 1) < 1e-9)
        #expect(abs(Mercator.unitX(longitude: -180)) < 1e-12)
        #expect(abs(Mercator.unitX(longitude: 180) - 1) < 1e-12)
    }

    @Test("latitude clamps rather than trapping", arguments: [89.0, 90.0, -90.0, 1e6])
    func latitudeClamps(latitude: Double) {
        let y = Mercator.unitY(latitude: latitude)
        #expect(y.isFinite)
        #expect((0...1).contains(y))
    }

    /// Longitude is cyclic, so clamping it would be wrong: `SlippyTileMath`
    /// relies on out-of-range columns surviving to be wrapped by its caller.
    @Test("longitude is left unclamped so callers can wrap it")
    func longitudeWraps() {
        #expect(Mercator.unitX(longitude: 190) > 1)
        #expect(Mercator.unitX(longitude: -190) < 0)
    }

    @Test("scale is largest at the equator and shrinks toward the poles")
    func metersPerUnit() {
        #expect(abs(Mercator.metersPerUnit(atLatitude: 0) - Mercator.equatorialCircumferenceMeters) < 1e-6)
        #expect(Mercator.metersPerUnit(atLatitude: 60) < Mercator.metersPerUnit(atLatitude: 0))
        // 60° is where cos φ is exactly ½.
        #expect(abs(Mercator.metersPerUnit(atLatitude: 60) - Mercator.equatorialCircumferenceMeters / 2) < 1)
    }

    @Test("representability check rejects what the projection can't hold")
    func representable() {
        #expect(Mercator.isRepresentable(latitude: 37.33, longitude: -122.01))
        #expect(!Mercator.isRepresentable(latitude: 89, longitude: 0))
        #expect(!Mercator.isRepresentable(latitude: 0, longitude: 181))
    }
}
