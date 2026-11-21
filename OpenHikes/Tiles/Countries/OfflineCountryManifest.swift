//
//  OfflineCountryManifest.swift
//  OpenHikes
//
//  What the tile server offers to download: one entry an area, which is a
//  country, or a state or province of one of the few countries too big for
//  one download (`group` names the country). Each area is four archives cut
//  out of the planet build the OpenHikes map draws, with the outline they
//  were cut along: the basemap and its extras to zoom 14, which every
//  download takes, and the two at zoom 15, which *Extra Detail* adds. It
//  lives at `countries/manifest.json` on `tiles.openhikes.app`, beside the
//  files, and `Scripts/offline-countries.sh` writes it.
//
//  The tool compiles this file as it stands, so it imports Foundation and
//  nothing of the app's and says `nonisolated` on every declaration.
//
//  A country's name is not here: the app names it in the hiker's language
//  from its ISO code (`Locale.localizedString(forRegionCode:)`). A region's
//  is, in each of the app's languages, from Natural Earth.
//
//  Every installed build reads this list, so it is read to leave the server
//  room to move. A file of a role a build does not know is left out, not
//  refused with the whole list. An area says which generation of the extras
//  it was cut from, and a build leaves off one it would draw wrong. And an
//  area may be listed more than once, the last build cut for older apps
//  beside the newest: each app takes the newest it draws.
//
//  Only the list a build chooses a download from is read that way
//  (``catalog(from:)``). The device's index and the tool keep an area too,
//  and read strictly: a file left out of what owns it would be swept, and
//  one left out of a list the tool writes back would be gone from it.
//

import Foundation
// The app reaches `VectorTileSchema` through the package that draws the map.
// The tool that cuts the countries compiles this file and that one into one
// module, where there is nothing to import.
#if canImport(OpenHikesVectorTiles)
import OpenHikesVectorTiles
#endif

nonisolated struct OfflineCountryManifest: Codable, Equatable, Sendable {
    /// The manifest format this reader takes. A manifest of another is not
    /// read at all.
    static let currentVersion = 1
    /// The generation of the Protomaps basemap's layers that the map's
    /// renderer draws, which is the renderer's to say
    /// (`VectorTileSchema.basemap`). A country cut from a build of another
    /// is left off the list, because it would draw wrong or not at all.
    static let readableSchema = VectorTileSchema.basemap
    /// The newest layout of the extras' layers that the renderer draws, as
    /// the tile server's own manifest counts them
    /// (`VectorTileSchema.extrasGeneration`). It draws every earlier one
    /// too. An area cut from later extras is left off the list, as one of
    /// another schema is.
    static let readableExtrasGeneration = VectorTileSchema.extrasGeneration

    var version: Int
    /// The countries, by ISO code.
    var countries: [Country]

    /// The areas this app can draw: of its schema and of extras it reads,
    /// with a basemap, and with names the device can keep them under, each
    /// of them the area's own. Of an area listed more than once, the newest
    /// build among those, where the first of them stands.
    var readableCountries: [Country] {
        guard version == Self.currentVersion else { return [] }
        var readable: [Country] = []
        var places: [String: Int] = [:]
        for country in countries where country.isReadable {
            if let place = places[country.id] {
                if country.build > readable[place].build { readable[place] = country }
            } else {
                places[country.id] = readable.count
                readable.append(country)
            }
        }
        return readable
    }

    /// An area to download: a whole country, or a region of one.
    struct Country: Codable, Equatable, Hashable, Sendable, Identifiable {
        /// ISO 3166-1 alpha-2 for a country (`SI`), ISO 3166-2 for a region
        /// (`US-CO`), upper case.
        var id: String
        /// The country a region is part of, by its ISO 3166-1 code, which the
        /// list files it under; `nil` for a country downloaded whole.
        var group: String?
        /// A region's name by language code, `en` among them. A country's is
        /// empty: the device names it.
        var names: [String: String]
        /// The planet build the files were cut from, as `yyyymmdd`. A newer
        /// build of a country already downloaded is an update.
        var build: String
        var schema: Int
        /// The generation of the extras its files were cut from. `nil` for
        /// an area listed before the list said, which every build draws.
        var extrasGeneration: Int?
        var bounds: Bounds
        /// The outline the files were cut along: each polygon's outer ring,
        /// as longitude and latitude pairs. What the map draws and a tap or a
        /// trail is tested against.
        var outline: [[[Double]]]
        var files: [File]

        /// The files a download takes, with *Extra Detail* or without.
        func files(withDetail: Bool) -> [File] {
            files.filter { withDetail || !$0.role.isDetail }
        }

        /// What downloading it costs, in bytes, with *Extra Detail* or without.
        func byteCount(withDetail: Bool) -> Int64 {
            files(withDetail: withDetail).reduce(0) { $0 + $1.byteCount }
        }
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

    enum Role: String, Codable, Sendable, CaseIterable {
        /// The Protomaps basemap's tiles, to zoom 14.
        case basemap = "basemap"
        /// The extras drawn into them (``VectorTileSource/Extras``).
        case extras = "extras"
        /// The basemap's zoom 15, where its buildings and most of its points
        /// are: what *Extra Detail* adds.
        case detail = "detail"
        /// The extras' zoom 15.
        case detailExtras = "detail-extras"

        var isDetail: Bool { self == .detail || self == .detailExtras }
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

    /// Whether the name is one the tile server's route serves — an area's
    /// code, then `-detail`, `-extras`, both or neither, then a build's eight
    /// digits — so that no name off the network can reach outside the
    /// directory it is kept in.
    var hasSafeName: Bool {
        guard fileName.hasSuffix(Self.fileExtension) else { return false }
        let stem = String(fileName.dropLast(Self.fileExtension.count))
        var parts = stem.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return false }
        let build = parts.removeLast()
        guard build.count == 8, build.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        if parts.last == "extras" { parts.removeLast() }
        if parts.last == "detail" { parts.removeLast() }
        return OfflineCountryManifest.isAreaCode(parts.joined(separator: "-"))
    }
}

nonisolated extension OfflineCountryManifest {
    /// Two capitals, as an ISO 3166-1 alpha-2 code is, then for a region a
    /// hyphen and one to three capitals or digits, as ISO 3166-2's are.
    static func isAreaCode(_ code: String) -> Bool {
        let parts = code.split(separator: "-", omittingEmptySubsequences: false)
        guard let country = parts.first, country.count == 2, country.allSatisfy(isCapital),
              parts.count <= 2
        else { return false }
        guard parts.count == 2 else { return true }
        let region = parts[1]
        return (1...3).contains(region.count) && region.allSatisfy { isCapital($0) || ($0.isASCII && $0.isNumber) }
    }

    private static func isCapital(_ character: Character) -> Bool {
        character.isASCII && character.isUppercase
    }
}

nonisolated extension OfflineCountryManifest {
    // swiftlint:disable force_unwrapping
    /// Set on a decoder's `userInfo` to read the server's list as a catalog,
    /// leaving out every file of a role this build does not know.
    static let readsCatalog = CodingUserInfoKey(rawValue: "OfflineCountryManifest.readsCatalog")!
    // swiftlint:enable force_unwrapping

    /// The server's list as a build chooses a download from it, which no
    /// file of a later role refuses. A list read any other way refuses one,
    /// because it is a list of what is kept.
    static func catalog(from data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.userInfo[readsCatalog] = true
        return try decoder.decode(Self.self, from: data)
    }
}

nonisolated extension OfflineCountryManifest.Country {
    /// Reads an area, and in a catalog leaves out any file of a role this
    /// build does not know: read as the compiler would write it, one such
    /// file refused the whole list.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        group = try container.decodeIfPresent(String.self, forKey: .group)
        names = try container.decode([String: String].self, forKey: .names)
        build = try container.decode(String.self, forKey: .build)
        schema = try container.decode(Int.self, forKey: .schema)
        extrasGeneration = try container.decodeIfPresent(Int.self, forKey: .extrasGeneration)
        bounds = try container.decode(OfflineCountryManifest.Bounds.self, forKey: .bounds)
        outline = try container.decode([[[Double]]].self, forKey: .outline)
        files = try container.decode([ListedFile].self, forKey: .files).compactMap(\.file)
    }

    /// A file as the list gives it, or, in a catalog, nothing for one of a
    /// role this build does not know.
    private struct ListedFile: Decodable {
        let file: OfflineCountryManifest.File?

        init(from decoder: any Decoder) throws {
            let role = try decoder.container(keyedBy: RoleKey.self).decode(String.self, forKey: .role)
            let isCatalog = decoder.userInfo[OfflineCountryManifest.readsCatalog] as? Bool == true
            file = isCatalog && OfflineCountryManifest.Role(rawValue: role) == nil
                ? nil
                : try OfflineCountryManifest.File(from: decoder)
        }

        private enum RoleKey: String, CodingKey {
            case role = "role"
        }
    }

    /// Whether this app can draw the area and keep its files: see
    /// ``OfflineCountryManifest/readableCountries``.
    var isReadable: Bool {
        schema == OfflineCountryManifest.readableSchema
            && (1...OfflineCountryManifest.readableExtrasGeneration).contains(extrasGeneration ?? 1)
            && hasAreaCode
            && files.contains { $0.role == .basemap }
            && files.allSatisfy { $0.hasSafeName && $0.fileName.hasPrefix(id + "-") }
    }

    /// Whether the id is a country's code with no group, or a region's
    /// under the group its code starts with.
    var hasAreaCode: Bool {
        guard OfflineCountryManifest.isAreaCode(id) else { return false }
        guard let group else { return !id.contains("-") }
        return id.hasPrefix(group + "-") && OfflineCountryManifest.isAreaCode(group) && !group.contains("-")
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
