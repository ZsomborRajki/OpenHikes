//
//  OfflineCountryManifestTests.swift
//  OpenHikesTests
//
//  What the app takes from the tile server's list of countries. The list
//  arrives off the network, so a name in it must never reach outside the
//  directory a country is kept in, and a country the app cannot draw must
//  never be offered.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Offline country manifest")
struct OfflineCountryManifestTests {
    private let slovenia = OfflineCountryFixture.country(bytes: Data("SI".utf8), extras: Data("extras".utf8))

    @Test("a country this app can draw is offered")
    func offersWhatItCanDraw() {
        #expect(OfflineCountryFixture.manifest([slovenia]).readableCountries == [slovenia])
    }

    @Test("a manifest of another format offers nothing")
    func otherFormat() {
        var manifest = OfflineCountryFixture.manifest([slovenia])
        manifest.version = OfflineCountryManifest.currentVersion + 1
        #expect(manifest.readableCountries.isEmpty)
    }

    /// Cut from a planet build whose layers the rasterizer does not know, a
    /// country would draw wrong or not at all.
    @Test("a country of another schema is left off")
    func otherSchema() {
        let newer = OfflineCountryFixture.country(
            bytes: Data("SI".utf8),
            schema: OfflineCountryManifest.readableSchema + 1
        )
        #expect(OfflineCountryFixture.manifest([newer]).readableCountries.isEmpty)
    }

    @Test("a country with no basemap, or no country code, is left off")
    func incomplete() {
        var extrasOnly = slovenia
        extrasOnly.files.removeAll { $0.role == .basemap }
        var unnamed = slovenia
        unnamed.id = "Slovenia"
        #expect(OfflineCountryFixture.manifest([extrasOnly, unnamed]).readableCountries.isEmpty)
    }

    @Test(
        "only the names the server's route serves are kept on the device",
        arguments: [
            ("countries/SI-20261117.pmtiles", true),
            ("countries/SI-extras-20261117.pmtiles", true),
            ("SI-20261117.pmtiles", true),
            ("countries/../SI-20261117.pmtiles", true),
            ("countries/si-20261117.pmtiles", false),
            ("countries/SI-2026111.pmtiles", false),
            ("countries/SI-20261117.pmtiles.json", false),
            ("countries/SI-roads-20261117.pmtiles", false),
            ("countries/SVN-20261117.pmtiles", false),
            ("countries/..", false),
            ("", false),
        ]
    )
    func safeNames(path: String, isSafe: Bool) {
        let file = OfflineCountryManifest.File(
            role: .basemap,
            path: path,
            byteCount: 1,
            sha256: "",
            minimumZoom: 0,
            maximumZoom: 15
        )
        #expect(file.hasSafeName == isSafe)
    }

    @Test("a country listing a file under an unsafe name is left off whole")
    func unsafeFile() {
        var country = slovenia
        country.files[1].path = "countries/../../Library/Preferences/x.pmtiles"
        #expect(OfflineCountryFixture.manifest([country]).readableCountries.isEmpty)
    }

    @Test("a point is inside the outline, not merely inside the bounds")
    func outlineContains() {
        var country = slovenia
        // A triangle in the square's lower left half.
        let bounds = country.bounds
        country.outline = [
            [
                [bounds.west, bounds.south], [bounds.east, bounds.south], [bounds.west, bounds.north],
                [bounds.west, bounds.south],
            ],
        ]
        #expect(country.contains(longitude: 13.5, latitude: 45.6))
        #expect(!country.contains(longitude: 16.4, latitude: 46.8))
        #expect(!country.contains(longitude: 12.0, latitude: 45.6))
    }

    /// The tool writes `bytes`; a renamed key would read every manifest as
    /// one the app cannot decode.
    @Test("the manifest decodes as the tool writes it")
    func decodesTheToolsKeys() throws {
        let json = Data(
            """
            {"version": 1, "countries": [{"id": "SI", "build": "20261117", "schema": 4,
            "bounds": {"west": 13.3, "south": 45.4, "east": 16.6, "north": 46.9},
            "outline": [[[13.3, 45.4], [16.6, 45.4], [16.6, 46.9], [13.3, 45.4]]],
            "files": [{"role": "basemap", "path": "countries/SI-20261117.pmtiles", "bytes": 460284649,
            "sha256": "57253cc4", "minimumZoom": 0, "maximumZoom": 15}]}]}
            """.utf8
        )
        let manifest = try JSONDecoder().decode(OfflineCountryManifest.self, from: json)
        let country = try #require(manifest.readableCountries.first)
        #expect(country.byteCount == 460_284_649)
        #expect(country.files.first?.fileName == "SI-20261117.pmtiles")
    }
}
