//
//  OfflineCountries+Listing.swift
//  OpenHikes
//
//  What *Offline Maps* and the hike screen read off ``OfflineCountries``: the
//  areas to list, each named in the app's language, which of them the list
//  puts first, which a line crosses and how far one is from a hiker. Worked
//  out here rather than in the views, so that a suite can hold each of them.
//  The order the list is in is ``OfflineCountryDirectory``'s.
//

import Algorithms
import CoreLocation
import Foundation
import OpenHikesData

extension OfflineCountries {
    /// Every area to list: those offered, and those downloaded that no
    /// longer are, by name in the app's language.
    var listed: [Country] { Self.listed(offered: offered, installed: installed) }

    /// The same, of what a caller has already read.
    nonisolated static func listed(offered: [Country], installed: [String: Record]) -> [Country] {
        var byID = Dictionary(offered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for record in installed.values where byID[record.country.id] == nil {
            byID[record.country.id] = record.country
        }
        return sortedByName(Array(byID.values))
    }

    /// The bytes every downloaded area takes.
    var installedByteCount: Int64 {
        installed.values.reduce(0) { $0 + $1.byteCount }
    }

    func isInstalled(_ id: String) -> Bool { installed[id] != nil }

    /// Whether the server has a newer build of an area downloaded.
    func update(for id: String) -> Country? {
        guard let record = installed[id],
              let newer = offered.first(where: { $0.id == id }),
              newer.build > record.country.build
        else { return nil }
        return newer
    }

    /// What downloading `country` costs, as *Extra Detail* stands.
    func byteCount(of country: Country) -> Int64 {
        country.byteCount(withDetail: includesDetail)
    }

    /// What `country` takes where it is downloaded, and costs where it is
    /// not: the figure its row shows, and what largest first orders by.
    func listedByteCount(of country: Country) -> Int64 {
        installed[country.id]?.byteCount ?? byteCount(of: country)
    }

    /// Whether `provider` is a map the downloaded areas are drawn on: the
    /// one drawn from the tiles they are cut from.
    nonisolated static func areDrawn(on provider: TileProvider) -> Bool {
        provider.vectorSource != nil
    }

    // MARK: - Names

    /// An area's name in `language`: a country's from the device, a
    /// region's from the manifest, in English where it has none in that.
    nonisolated static func name(of country: Country, language: String = VectorTileLabels.appLanguage) -> String {
        guard !country.names.isEmpty else { return name(ofCountry: country.id, language: language) }
        return country.names[language] ?? country.names["en"] ?? country.id
    }

    /// A country's name in `language`, from its ISO code.
    nonisolated static func name(ofCountry code: String, language: String = VectorTileLabels.appLanguage) -> String {
        Locale(identifier: language).localizedString(forRegionCode: code) ?? code
    }

    /// An area's name, and for a region its country's after it, for a list
    /// that does not have it under its country: *Colorado, United States*.
    nonisolated static func fullName(of country: Country, language: String = VectorTileLabels.appLanguage) -> String {
        let area = name(of: country, language: language)
        guard let group = country.group else { return area }
        return String(localized: "\(area), \(name(ofCountry: group, language: language))")
    }

    /// Each named once rather than at every comparison: a name is a
    /// `Locale` lookup, and the list sorts hundreds of areas.
    nonisolated static func sortedByName(_ countries: [Country]) -> [Country] {
        countries.map { (name: name(of: $0), country: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map(\.country)
    }

    // MARK: - Sections

    /// *Offline Maps*' list in `sort`'s order: what is downloaded or coming
    /// down, then every other area as the order heads it.
    func sections(of directory: OfflineCountryDirectory, by sort: OfflineCountrySort) -> OfflineCountrySections {
        directory.sections(
            by: sort,
            isHeld: { isInstalled($0.id) || downloads[$0.id] != nil },
            byteCount: { listedByteCount(of: $0) }
        )
    }

    // MARK: - Where

    /// The areas a saved line passes through, tested every so many points:
    /// an area is tens of kilometres across, so one point every few hundred
    /// metres of a long trail still finds every one it reaches.
    func countries(alongRoute route: [RouteCoordinate], testing points: Int = 400) -> [Country] {
        guard !route.isEmpty else { return [] }
        let step = max(route.count / points, 1)
        var sampled = route.striding(by: step).map(\.clCoordinate)
        if let last = route.last { sampled.append(last.clCoordinate) }
        return countries(along: sampled)
    }

    /// The areas a line passes through, in the order it reaches them.
    func countries(along coordinates: [CLLocationCoordinate2D]) -> [Country] {
        let candidates = listed
        var found: [Country] = []
        for coordinate in coordinates {
            for country in candidates where !found.contains(where: { $0.id == country.id })
                && country.contains(longitude: coordinate.longitude, latitude: coordinate.latitude) {
                found.append(country)
            }
        }
        return found
    }
}

nonisolated extension OfflineCountryManifest.Country {
    /// How far `coordinate` is from the outline, in kilometres: none inside
    /// it. On a flat map round `coordinate`, near enough for the few hundred
    /// kilometres *Nearby* reaches, and to order the areas beyond by.
    ///
    /// Measured to the outline, not the bounds. A box holds much that is not
    /// the area: France's runs from the Antilles to Réunion, and an area
    /// across the antimeridian — Alaska, Chukotka, Fiji, New Zealand — has a
    /// box round the whole globe, which would put it next to every hiker at
    /// its latitudes.
    func kilometers(from coordinate: CLLocationCoordinate2D) -> Double {
        if contains(longitude: coordinate.longitude, latitude: coordinate.latitude) { return 0 }
        let shrink = cos(coordinate.latitude * .pi / 180)
        var nearest = Double.infinity
        for ring in outline {
            let vertices = ring.filter { $0.count >= 2 }
            guard var previous = vertices.last else { continue }
            // Each edge's longitudes taken from its first end's, so an edge is
            // never split round the globe from the point.
            var from = Self.wrapped(previous[0] - coordinate.longitude)
            for vertex in vertices {
                let to = from + vertex[0] - previous[0]
                nearest = min(nearest, Self.distanceFromOrigin(
                    (from * shrink, previous[1] - coordinate.latitude),
                    (to * shrink, vertex[1] - coordinate.latitude)
                ))
                previous = vertex
                from = Self.wrapped(vertex[0] - coordinate.longitude)
            }
        }
        return nearest * Self.kilometersPerDegree
    }

    private static let kilometersPerDegree = 111.32

    /// A difference of longitudes, brought between -180 and 180.
    private static func wrapped(_ longitude: Double) -> Double {
        let turned = (longitude + 180).truncatingRemainder(dividingBy: 360)
        return (turned < 0 ? turned + 360 : turned) - 180
    }

    /// How far the segment from `start` to `end` passes from the origin.
    private static func distanceFromOrigin(_ start: (Double, Double), _ end: (Double, Double)) -> Double {
        let (dx, dy) = (end.0 - start.0, end.1 - start.1)
        let length = dx * dx + dy * dy
        let along = length > 0 ? min(max(-(start.0 * dx + start.1 * dy) / length, 0), 1) : 0
        return hypot(start.0 + along * dx, start.1 + along * dy)
    }
}
