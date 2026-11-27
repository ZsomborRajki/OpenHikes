//
//  OfflineCountries+Listing.swift
//  OpenHikes
//
//  What *Offline Maps* and the hike screen read off ``OfflineCountries``: the
//  areas to list, each named in the app's language, which of them the list
//  puts first and how far one is from a hiker. Worked out here rather than in
//  the views, so that a suite can hold each of them. The order the list is in
//  is ``OfflineCountryDirectory``'s, and the areas a line crosses are
//  `OfflineCountries+Coverage.swift`'s.
//

import CoreLocation
import Foundation

extension OfflineCountries {
    /// Every area to list: those offered, and those downloaded that no
    /// longer are, by name in the app's language.
    var listed: [Country] { Self.listed(offered: offered, installed: installed) }

    /// Whether ``listed`` is empty, without putting it together and naming
    /// every area to find out.
    var listsNothing: Bool { offered.isEmpty && installed.isEmpty }

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

    /// Whether the area `id` is on the device: the index names it, whether
    /// or not its files open.
    func isInstalled(_ id: String) -> Bool { installed[id] != nil }

    /// The area listed now under `id`, as ``listed`` has it: the build the
    /// server offers, or the one downloaded where it offers none. What a
    /// screen kept from an earlier list is looked up again by its code
    /// before it is shown or downloaded, because the server deletes a build
    /// it has moved past.
    func listedCountry(_ id: String) -> Country? {
        offered.first { $0.id == id } ?? installed[id]?.country
    }

    /// The areas `coverage` found a line crossing that the map does not
    /// draw, as the list has them now, in the order the line reaches them.
    /// One on the device whose basemap would not open is among them, for
    /// what would not open. None where the device's own lists cannot be
    /// read: nothing downloads then, and what it holds is not known.
    func missing(from coverage: OfflineRouteCoverage) -> [Country] {
        guard isAvailable else { return [] }
        return coverage.crossed.compactMap { listedCountry($0.id) }.filter { !isDrawn($0.id) }
    }

    /// Whether the map draws the area `id` with no signal: it is on the
    /// device and its basemap opened. What a hike counts as saved.
    func isDrawn(_ id: String) -> Bool {
        installed[id] != nil && unopenable[id]?.contains(.basemap) != true
    }

    /// Whether a file of the area `id` on the device would not open, which
    /// ``repair(_:)`` brings down again.
    func needsRepair(_ id: String) -> Bool {
        installed[id] != nil && unopenable[id]?.isEmpty == false
    }

    /// Downloads again the files of the area `id` that would not open, and
    /// nothing else of it: the rest is on the device, and was checked.
    func repair(_ id: String) {
        guard needsRepair(id), let record = installed[id] else { return }
        download(record.country)
    }

    /// Whether the server has a newer build of an area downloaded.
    func update(for id: String) -> Country? {
        guard let record = installed[id],
              let newer = offered.first(where: { $0.id == id }),
              newer.build > record.country.build
        else { return nil }
        return newer
    }

    /// What downloading `country` costs, as *Extra Detail* and *Elevation
    /// Data* stand: of an area on the device, only the files it would bring.
    func byteCount(of country: Country) -> Int64 {
        filesToFetch(for: country).reduce(0) { $0 + $1.byteCount }
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

    /// *Offline Maps*' list in `sort`'s order: the downloads not yet in, what
    /// is downloaded, then every other area as the order heads it. Only
    /// whether an area has a download is read here, never its phase, so a
    /// download that fails or waits moves no row.
    func sections(of directory: OfflineCountryDirectory, by sort: OfflineCountrySort) -> OfflineCountrySections {
        directory.sections(
            by: sort,
            holding: { country in
                if isInstalled(country.id) { return .downloaded }
                return downloads[country.id] == nil ? nil : .unfinished
            },
            byteCount: { listedByteCount(of: $0) }
        )
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
