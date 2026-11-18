//
//  OfflineCountryManifest.swift
//  OpenHikes
//
//  What the tile server offers to download: one entry a country, each a
//  basemap archive and an extras archive cut out of the planet build the
//  OpenHikes map draws, with the outline they were cut along. It lives at
//  `countries/manifest.json` on `tiles.openhikes.app`, beside the files, and
//  `Scripts/offline-countries.sh` writes it.
//
//  The tool compiles this file as it stands, so it imports Foundation and
//  nothing of the app's and says `nonisolated` on every declaration.
//
//  A country's name is not here: the app names it in the hiker's language
//  from its ISO code (`Locale.localizedString(forRegionCode:)`).
//

import Foundation

nonisolated struct OfflineCountryManifest: Codable, Equatable, Sendable {
    /// The manifest format this reader takes. A manifest of another is not
    /// read at all.
    static let currentVersion = 1
    /// The generation of the Protomaps basemap's layers that
    /// ``VectorTileRasterizer`` draws. A country cut from a build of another
    /// is left off the list, because it would draw wrong or not at all.
    static let readableSchema = 4

    var version: Int
    /// The countries, by ISO code.
    var countries: [Country]

    /// The countries this app can draw: of its schema, with a basemap, and
    /// with names the device can keep them under.
    var readableCountries: [Country] {
        guard version == Self.currentVersion else { return [] }
        return countries.filter { country in
            country.schema == Self.readableSchema
                && country.hasCountryCode
                && country.files.contains { $0.role == .basemap }
                && country.files.allSatisfy(\.hasSafeName)
        }
    }

    struct Country: Codable, Equatable, Hashable, Sendable, Identifiable {
        /// ISO 3166-1 alpha-2, upper case.
        var id: String
        /// The planet build the files were cut from, as `yyyymmdd`. A newer
        /// build of a country already downloaded is an update.
        var build: String
        var schema: Int
        var bounds: Bounds
        /// The outline the files were cut along: each polygon's outer ring,
        /// as longitude and latitude pairs. What the map draws and a tap or a
        /// trail is tested against.
        var outline: [[[Double]]]
        var files: [File]

        /// What downloading it costs, in bytes.
        var byteCount: Int64 { files.reduce(0) { $0 + $1.byteCount } }
    }

    struct File: Codable, Equatable, Hashable, Sendable {
        var role: Role
        /// Where it is, from the manifest's own directory's parent: the
        /// server's root.
        var path: String
        var byteCount: Int64
        /// The SHA-256 of the whole file, in lower-case hex. A download that
        /// does not match is thrown away.
        var sha256: String
        var minimumZoom: Int
        var maximumZoom: Int

        enum CodingKeys: String, CodingKey {
            case byteCount = "bytes"
            case maximumZoom = "maximumZoom"
            case minimumZoom = "minimumZoom"
            case path = "path"
            case role = "role"
            case sha256 = "sha256"
        }
    }

    enum Role: String, Codable, Sendable {
        /// The Protomaps basemap's tiles.
        case basemap = "basemap"
        /// The extras drawn into them (``VectorTileSource/Extras``).
        case extras = "extras"
    }

    struct Bounds: Codable, Equatable, Hashable, Sendable {
        var west: Double
        var south: Double
        var east: Double
        var north: Double

        func contains(longitude: Double, latitude: Double) -> Bool {
            (west...east).contains(longitude) && (south...north).contains(latitude)
        }
    }
}

nonisolated extension OfflineCountryManifest.File {
    static let fileExtension = ".pmtiles"

    /// The last part of the path: what the file is kept under on the device.
    var fileName: String { path.split(separator: "/").last.map(String.init) ?? "" }

    /// Whether the name is one the tile server's route serves — a country
    /// code, `-extras` or not, a build's eight digits — so that no name off
    /// the network can reach outside the directory it is kept in.
    var hasSafeName: Bool {
        guard fileName.hasSuffix(Self.fileExtension) else { return false }
        var parts = fileName.dropLast(Self.fileExtension.count).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 || (parts.count == 3 && parts[1] == "extras") else { return false }
        let build = parts.removeLast()
        let code = parts[0]
        return code.count == 2 && code.allSatisfy { $0.isASCII && $0.isUppercase }
            && build.count == 8 && build.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

nonisolated extension OfflineCountryManifest.Country {
    /// Whether the id is two capitals, as an ISO 3166-1 alpha-2 code is.
    var hasCountryCode: Bool {
        id.count == 2 && id.allSatisfy { $0.isASCII && $0.isUppercase }
    }

    /// Whether the point is inside the outline: an even-odd test against each
    /// polygon's ring, after the cheap test against the bounds.
    func contains(longitude: Double, latitude: Double) -> Bool {
        guard bounds.contains(longitude: longitude, latitude: latitude) else { return false }
        return outline.contains { ring in Self.ring(ring, contains: (longitude, latitude)) }
    }

    private static func ring(_ ring: [[Double]], contains point: (x: Double, y: Double)) -> Bool {
        var inside = false
        var previous = ring.last
        for vertex in ring {
            guard vertex.count >= 2, let last = previous, last.count >= 2 else {
                previous = vertex
                continue
            }
            let (x1, y1, x2, y2) = (last[0], last[1], vertex[0], vertex[1])
            if (y1 > point.y) != (y2 > point.y), point.x < (x2 - x1) * (point.y - y1) / (y2 - y1) + x1 {
                inside.toggle()
            }
            previous = vertex
        }
        return inside
    }
}
