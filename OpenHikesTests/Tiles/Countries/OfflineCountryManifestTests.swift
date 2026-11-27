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
            ("countries/SI-detail-20261117.pmtiles", true),
            ("countries/SI-detail-extras-20261117.pmtiles", true),
            ("countries/SI-extras-detail-20261117.pmtiles", false),
            ("countries/SI-trails-20261117.pmtiles", true),
            ("countries/US-CO-trails-20261117.pmtiles", true),
            ("countries/SI-detail-trails-20261117.pmtiles", false),
            ("countries/SI-trails-extras-20261117.pmtiles", false),
            ("countries/SI-TRAILS-20261117.pmtiles", false),
            ("countries/SI-elevation-20261117.pmtiles", true),
            ("countries/US-CO-elevation-20261117.pmtiles", true),
            ("countries/SI-trails-elevation-20261117.pmtiles", false),
            ("countries/SI-elevation-detail-20261117.pmtiles", false),
            ("countries/US-CO-20261117.pmtiles", true),
            ("countries/RU-MOW-detail-extras-20261117.pmtiles", true),
            ("countries/US-COLO-20261117.pmtiles", false),
            ("countries/US-co-20261117.pmtiles", false),
            ("countries/US-CO-X1-20261117.pmtiles", false),
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

    /// A region is listed under its country, so its code must start with
    /// that country's, and a country must not claim to be one.
    @Test("a region is offered under the country its code names, and nowhere else")
    func regions() {
        let colorado = OfflineCountryFixture.country(
            bytes: Data("CO".utf8),
            id: "US-CO",
            group: "US",
            names: ["en": "Colorado", "de": "Colorado"]
        )
        let misfiled = OfflineCountryFixture.country(bytes: Data("CO".utf8), id: "US-CO", group: "CA")
        let ungrouped = OfflineCountryFixture.country(bytes: Data("CO".utf8), id: "US-CO")
        let groupedCountry = OfflineCountryFixture.country(bytes: Data("SI".utf8), group: "SI")
        let manifest = OfflineCountryFixture.manifest([colorado, misfiled, ungrouped, groupedCountry])

        #expect(manifest.readableCountries == [colorado])
    }

    @Test("a file named for another area is left off with its area")
    func fileOfAnotherArea() {
        var country = slovenia
        country.files[1].path = "countries/AT-extras-20261117.pmtiles"
        #expect(OfflineCountryFixture.manifest([country]).readableCountries.isEmpty)
    }

    @Test("an area's download takes zoom 15 only with Extra Detail, and its day hikes and heights either way")
    func detailFiles() {
        let country = OfflineCountryFixture.country(
            bytes: Data(count: 10),
            extras: Data(count: 1),
            detail: Data(count: 20),
            detailExtras: Data(count: 2),
            trails: Data(count: 3),
            elevation: Data(count: 4)
        )
        let base: [OfflineCountryManifest.Role] = [.basemap, .extras, .trails, .elevation]
        #expect(country.files(withDetail: false, withElevation: true).map(\.role) == base)
        let noHeights: [OfflineCountryManifest.Role] = [.basemap, .extras, .detail, .detailExtras, .trails]
        #expect(country.files(withDetail: true, withElevation: false).map(\.role) == noHeights)
        #expect(country.byteCount(withDetail: false, withElevation: false) == 14)
        let everything: [OfflineCountryManifest.Role] = [.basemap, .extras, .detail, .detailExtras, .trails, .elevation]
        #expect(country.files(withDetail: true, withElevation: true).map(\.role) == everything)
        #expect(country.byteCount(withDetail: false, withElevation: true) == 18)
        #expect(country.byteCount(withDetail: true, withElevation: true) == 40)
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
            {"version": 1, "countries": [{"id": "SI", "names": {}, "build": "20261117", "schema": 4,
            "bounds": {"west": 13.3, "south": 45.4, "east": 16.6, "north": 46.9},
            "outline": [[[13.3, 45.4], [16.6, 45.4], [16.6, 46.9], [13.3, 45.4]]],
            "files": [{"role": "basemap", "path": "countries/SI-20261117.pmtiles", "bytes": 460284649,
            "sha256": "57253cc4", "minimumZoom": 0, "maximumZoom": 15}]}]}
            """.utf8
        )
        let manifest = try JSONDecoder().decode(OfflineCountryManifest.self, from: json)
        let country = try #require(manifest.readableCountries.first)
        #expect(country.byteCount(withDetail: true, withElevation: true) == 460_284_649)
        #expect(country.files.first?.fileName == "SI-20261117.pmtiles")
    }

    /// One area as the server lists it, with `fields` after its build and
    /// `files` after its basemap.
    private static func listing(fields: String = "", files: String = "") -> Data {
        Data(
            """
            {"version": 1, "countries": [{"id": "SI", "names": {}, "build": "20261117", "schema": 4, \(fields)
            "bounds": {"west": 13.3, "south": 45.4, "east": 16.6, "north": 46.9},
            "outline": [[[13.3, 45.4], [16.6, 45.4], [16.6, 46.9], [13.3, 45.4]]],
            "files": [{"role": "basemap", "path": "countries/SI-20261117.pmtiles", "bytes": 10,
            "sha256": "57253cc4", "minimumZoom": 0, "maximumZoom": 14}\(files)]}]}
            """.utf8
        )
    }

    /// An area as a later server may list it, with its hiking routes beside
    /// its basemap.
    private static let listingWithRoutes = listing(
        files: """
        , {"role": "routes", "path": "countries/SI-routes-20261117.pmtiles", "bytes": 5,
        "sha256": "9f86d081", "minimumZoom": 0, "maximumZoom": 14}
        """
    )

    /// A later server may list a file this build has no use for. Read
    /// strictly, that one file would cost every installed copy of this build
    /// its whole list.
    @Test("in the catalog, a file of a role this build does not know is left out, and its area is still offered")
    func unknownRole() throws {
        let manifest = try OfflineCountryManifest.catalog(from: Self.listingWithRoutes)
        #expect(manifest.readableCountries.first?.files.map(\.role) == [.basemap])
    }

    /// What every download takes beside its map since the day hikes were
    /// cut: a file of its own, which this build keeps.
    @Test("an area's day hikes are a file of its own, which this build reads")
    func trailsFile() throws {
        let json = Self.listing(
            files: """
            , {"role": "trails", "path": "countries/SI-trails-20261117.pmtiles", "bytes": 5,
            "sha256": "9f86d081", "minimumZoom": 11, "maximumZoom": 11}
            """
        )
        let catalog = try OfflineCountryManifest.catalog(from: json)
        #expect(catalog.readableCountries.first?.files.map(\.role) == [.basemap, .trails])
        let kept = try JSONDecoder().decode(OfflineCountryManifest.self, from: json)
        #expect(kept.readableCountries.first?.files.last?.fileName == "SI-trails-20261117.pmtiles")
    }

    /// What every download takes beside its map since the heights were cut:
    /// a file of its own, which this build keeps, and a build before it
    /// leaves off its list.
    @Test("an area's heights are a file of its own, which this build reads")
    func elevationFile() throws {
        let json = Self.listing(
            files: """
            , {"role": "elevation", "path": "countries/SI-elevation-20261117.pmtiles", "bytes": 5,
            "sha256": "9f86d081", "minimumZoom": 12, "maximumZoom": 12}
            """
        )
        let catalog = try OfflineCountryManifest.catalog(from: json)
        #expect(catalog.readableCountries.first?.files.map(\.role) == [.basemap, .elevation])
        let kept = try JSONDecoder().decode(OfflineCountryManifest.self, from: json)
        #expect(kept.readableCountries.first?.files.last?.fileName == "SI-elevation-20261117.pmtiles")
    }

    /// The index and the cutting tool read the same areas as a list of what
    /// is kept: a file left out there would be swept from the device, or
    /// dropped from the server's list when the tool writes it back.
    @Test("read as anything but the catalog, a file of a role this build does not know refuses the list")
    func unknownRoleKept() {
        let json = Self.listingWithRoutes
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(OfflineCountryManifest.self, from: json)
        }
    }

    /// The extras' layers change by generation, as the tile server's own
    /// manifest counts them, and a build draws a later one wrong.
    @Test("an area cut from extras of a later generation is left off")
    func laterExtras() throws {
        let later = OfflineCountryManifest.readableExtrasGeneration + 1
        let json = Self.listing(fields: "\"extrasGeneration\": \(later),")
        #expect(try JSONDecoder().decode(OfflineCountryManifest.self, from: json).readableCountries.isEmpty)

        let known = Self.listing(fields: "\"extrasGeneration\": \(OfflineCountryManifest.readableExtrasGeneration),")
        #expect(try JSONDecoder().decode(OfflineCountryManifest.self, from: known).readableCountries.count == 1)
    }

    /// What lets the server keep an area's last build for the apps that
    /// read only that, beside the one cut from newer extras.
    @Test("of several builds of an area, the newest this build draws is the one offered")
    func newestBuildItDraws() {
        let first = OfflineCountryFixture.country(bytes: Data("SI".utf8), build: "20261117")
        let second = OfflineCountryFixture.country(bytes: Data("SI".utf8), build: "20261201")
        var later = OfflineCountryFixture.country(bytes: Data("SI".utf8), build: "20270115")
        later.extrasGeneration = OfflineCountryManifest.readableExtrasGeneration + 1
        let austria = OfflineCountryFixture.country(bytes: Data("AT".utf8), id: "AT")

        let manifest = OfflineCountryFixture.manifest([later, first, austria, second])

        #expect(manifest.readableCountries == [second, austria])
    }
}
