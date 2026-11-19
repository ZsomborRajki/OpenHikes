//
//  OfflineCountries+Listing.swift
//  OpenHikes
//
//  What *Offline Maps* and the hike screen read off ``OfflineCountries``: the
//  areas to list, each named in the app's language, how they fall into the
//  list's sections, with a split country's regions all under it, and which
//  a line crosses or a hiker is near. Worked out here rather than in the
//  views, so that a suite can hold each of them.
//

import CoreLocation
import Foundation
import OpenHikesData

extension OfflineCountries {
    /// Every area to list: those offered, and those downloaded that no
    /// longer are, by name in the app's language.
    var listed: [Country] {
        var byID = Dictionary(offered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for record in installed.values where byID[record.country.id] == nil {
            byID[record.country.id] = record.country
        }
        return Self.sortedByName(Array(byID.values))
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

    /// *Offline Maps*' three sections: what is downloaded or coming down,
    /// what is near `coordinate`, then every other country, with each
    /// country split by region listed with all its regions under it.
    func sections(of listed: [Country], near coordinate: CLLocationCoordinate2D?) -> OfflineCountrySections {
        let held = listed.filter { isInstalled($0.id) || downloads[$0.id] != nil }
        let heldIDs = Set(held.map(\.id))
        let nearby = coordinate.map { self.nearby($0) }?.filter { !heldIDs.contains($0.id) } ?? []
        let nearbyIDs = Set(nearby.map(\.id))
        var rest: [OfflineCountryListing] = []
        var groups: [String: [Country]] = [:]
        for country in listed {
            if let group = country.group {
                groups[group, default: []].append(country)
            } else if !heldIDs.contains(country.id), !nearbyIDs.contains(country.id) {
                rest.append(.area(country))
            }
        }
        rest += groups.map { .group(id: $0.key, regions: Self.sortedByName($0.value)) }
        rest.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return OfflineCountrySections(held: held, nearby: nearby, rest: rest)
    }

    // MARK: - Where

    /// The areas a saved line passes through, tested every so many points:
    /// an area is tens of kilometres across, so one point every few hundred
    /// metres of a long trail still finds every one it reaches.
    func countries(alongRoute route: [RouteCoordinate], testing points: Int = 400) -> [Country] {
        guard !route.isEmpty else { return [] }
        let step = max(route.count / points, 1)
        var sampled = stride(from: 0, to: route.count, by: step).map { route[$0].clCoordinate }
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

    /// The areas nearest `coordinate`: the one it is in first, then those
    /// within `kilometers` of it.
    ///
    /// Measured to the outline, not the bounds. A box holds much that is not
    /// the area: France's runs from the Antilles to Réunion, and an area
    /// across the antimeridian — Alaska, Chukotka, Fiji, New Zealand — has a
    /// box round the whole globe, which would put it next to every hiker at
    /// its latitudes.
    func nearby(_ coordinate: CLLocationCoordinate2D, within kilometers: Double = 250) -> [Country] {
        let distances = listed.compactMap { country -> (Country, Double)? in
            let distance = country.kilometers(from: coordinate)
            return distance <= kilometers ? (country, distance) : nil
        }
        return distances.sorted { $0.1 < $1.1 }.map(\.0)
    }
}

nonisolated extension OfflineCountryManifest.Country {
    /// How far `coordinate` is from the outline, in kilometres: none inside
    /// it. On a flat map round `coordinate`, near enough for the few hundred
    /// kilometres *Nearby* reaches.
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

/// What *Offline Maps* lists, in the order it lists it.
struct OfflineCountrySections: Equatable {
    var held: [OfflineCountryManifest.Country]
    var nearby: [OfflineCountryManifest.Country]
    var rest: [OfflineCountryListing]

    /// Where the list goes to show `id`: its row in *Downloaded* or
    /// *Nearby* if it has one there, else its line in *All Countries*,
    /// opening the country a region is under.
    func scrollTarget(for id: String) -> (rowID: String, opening: String?) {
        if (held + nearby).contains(where: { $0.id == id }) { return (id, nil) }
        for case let .group(group, regions) in rest where regions.contains(where: { $0.id == id }) {
            return (Self.groupRowID(id), group)
        }
        return (id, nil)
    }

    /// A region's row under its country, apart from the same region's row in
    /// *Downloaded* or *Nearby*.
    static func groupRowID(_ id: String) -> String { "group-\(id)" }
}

/// A line of *All Countries*: an area, or a country split by region, which
/// holds all its regions.
enum OfflineCountryListing: Equatable, Identifiable {
    case area(OfflineCountryManifest.Country)
    case group(id: String, regions: [OfflineCountryManifest.Country])

    var id: String {
        switch self {
        case let .area(country): country.id
        case let .group(id, _): id
        }
    }

    /// What the line is listed under, in the app's language.
    var name: String {
        switch self {
        case let .area(country): OfflineCountries.name(of: country)
        case let .group(id, _): OfflineCountries.name(ofCountry: id)
        }
    }
}
