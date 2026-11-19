//
//  OfflineCountryDirectory.swift
//  OpenHikes
//
//  What *Offline Maps* orders and finds its areas by, worked out once for a
//  list rather than at every pass of the view that draws it: each area's
//  name in the app's language, the letter that name is filed under, and how
//  far the area is from the hiker. A name is a `Locale` lookup, a letter a
//  collation's and a distance a walk round an outline; the list is hundreds
//  of areas, and its body runs again at every keystroke in its search field.
//
//  ## The three orders
//
//  Whatever the order (``OfflineCountrySort``), what is downloaded or coming
//  down is listed first.
//
//  - **By name** the rest is a directory: every country under the letter its
//    name is filed under, which the list's index jumps to, and a country
//    split by region as one line that holds all its regions.
//  - **Nearest first** and **largest first** are flat. A region is a line of
//    its own there, named with its country, because under its country it
//    could not stand where its distance or its size puts it. Nearest first
//    keeps *Nearby* as a heading over the areas a day out reaches. Further
//    off the distance is only good enough to order by: it is measured on a
//    flat map round the hiker (``OfflineCountryManifest/Country/kilometers(from:)``).
//
//  ## A search
//
//  A search is none of the three: the areas whose names answer it, best
//  first by ``HikeNameMatch``'s rule, whatever order the list is in. A region
//  answers to its country's name too, so *United States* finds its states.
//

import CoreLocation
import Foundation
#if canImport(UIKit)
import UIKit
#endif

struct OfflineCountryDirectory {
    typealias Country = OfflineCountryManifest.Country

    /// An area, with what the list reads of it.
    struct Entry {
        let country: Country
        /// Its name, with its country's after a region's: what a flat list
        /// and a search call it.
        let fullName: String
        /// How far it is from the hiker, where their position is known.
        let kilometers: Double?
    }

    /// A line of the list by name, with the letter it is filed under.
    private struct Line {
        let letter: OfflineCountryLetter
        let listing: OfflineCountryListing
    }

    /// How far *Nearby* reaches.
    static let nearbyKilometers = 250.0

    /// Every area, by name.
    let entries: [Entry]
    /// Whether the hiker's position is known, and with it each area's
    /// distance.
    let hasPosition: Bool
    /// The list by name, in its order.
    private let lines: [Line]
    /// ``entries``' indices, nearest first.
    private let nearestFirst: [Int]

    var isEmpty: Bool { entries.isEmpty }

    /// - Parameters:
    ///   - listed: Every area to list, by name: ``OfflineCountries/listed``.
    ///   - near: Where the hiker is.
    ///   - letter: The letter a name is filed under.
    init(listed: [Country], near: CLLocationCoordinate2D?, letter: (String) -> OfflineCountryLetter) {
        let measured = listed.map { country in
            Entry(
                country: country,
                fullName: OfflineCountries.fullName(of: country),
                kilometers: near.map { country.kilometers(from: $0) }
            )
        }
        entries = measured
        hasPosition = near != nil
        lines = Self.byLetter(listed, letter: letter)
        nearestFirst = measured.indices.sorted { first, second in
            let (one, other) = (measured[first].kilometers ?? .infinity, measured[second].kilometers ?? .infinity)
            return one == other ? first < second : one < other
        }
    }

    /// Every country, and every country split by region with its regions
    /// under it, by letter and then by name.
    private static func byLetter(_ listed: [Country], letter: (String) -> OfflineCountryLetter) -> [Line] {
        var named: [(name: String, listing: OfflineCountryListing)] = []
        var regions: [String: [Country]] = [:]
        for country in listed {
            if let group = country.group {
                regions[group, default: []].append(country)
            } else {
                named.append((OfflineCountries.name(of: country), .area(country)))
            }
        }
        named += regions.map { (OfflineCountries.name(ofCountry: $0.key), .group(id: $0.key, regions: $0.value)) }
        return named.map { (letter: letter($0.name), name: $0.name, listing: $0.listing) }
            .sorted { first, second in
                if first.letter.order != second.letter.order { return first.letter.order < second.letter.order }
                return first.name.localizedStandardCompare(second.name) == .orderedAscending
            }
            .map { Line(letter: $0.letter, listing: $0.listing) }
    }

    // MARK: - The orders

    /// The list in `sort`'s order: what `isHeld` says is downloaded or coming
    /// down first, then the rest under the order's headings. By name where
    /// the order is nearest first and no position is known.
    ///
    /// - Parameter byteCount: What an area takes or costs, for largest first.
    func sections(
        by sort: OfflineCountrySort,
        isHeld: (Country) -> Bool,
        byteCount: (Country) -> Int64
    ) -> OfflineCountrySections {
        switch sort {
        case .nearest where hasPosition:
            return nearest(isHeld: isHeld)
        case .name, .nearest:
            return named(isHeld: isHeld)
        case .largest:
            return largest(isHeld: isHeld, byteCount: byteCount)
        }
    }

    private func largest(isHeld: (Country) -> Bool, byteCount: (Country) -> Int64) -> OfflineCountrySections {
        // Each measured once, and the name's order kept among equals.
        let sized: [(bytes: Int64, index: Int)] = entries.indices.map { (byteCount(entries[$0].country), $0) }
        let largestFirst = sized
            .sorted { first, second in
                first.bytes == second.bytes ? first.index < second.index : first.bytes > second.bytes
            }
            .map { entries[$0.index].country }
        return OfflineCountrySections(
            held: largestFirst.filter(isHeld),
            parts: Self.parts([(.all, largestFirst.filter { !isHeld($0) })])
        )
    }

    private func named(isHeld: (Country) -> Bool) -> OfflineCountrySections {
        var parts: [OfflineCountrySections.Part] = []
        for line in lines {
            // A country downloaded is listed above. A split country is never
            // one, and keeps every region under it, the downloaded ones too.
            if case let .area(country) = line.listing, isHeld(country) { continue }
            let heading = OfflineCountrySections.Part.Heading.letter(line.letter.title)
            if parts.last?.heading == heading {
                parts[parts.count - 1].lines.append(line.listing)
            } else {
                parts.append(OfflineCountrySections.Part(heading: heading, lines: [line.listing]))
            }
        }
        return OfflineCountrySections(held: entries.map(\.country).filter(isHeld), parts: parts)
    }

    private func nearest(isHeld: (Country) -> Bool) -> OfflineCountrySections {
        var held: [Country] = []
        var nearby: [Country] = []
        var rest: [Country] = []
        for entry in nearestFirst.map({ entries[$0] }) {
            if isHeld(entry.country) {
                held.append(entry.country)
            } else if let kilometers = entry.kilometers, kilometers <= Self.nearbyKilometers {
                nearby.append(entry.country)
            } else {
                rest.append(entry.country)
            }
        }
        return OfflineCountrySections(held: held, parts: Self.parts([(.nearby, nearby), (.all, rest)]))
    }

    /// Flat parts, each area a line of its own, without the empty ones.
    private static func parts(
        _ headed: [(heading: OfflineCountrySections.Part.Heading, areas: [Country])]
    ) -> [OfflineCountrySections.Part] {
        headed.filter { !$0.areas.isEmpty }
            .map { OfflineCountrySections.Part(heading: $0.heading, lines: $0.areas.map { .area($0) }) }
    }

    // MARK: - A search

    /// The areas whose names answer `query`, best first: a name that starts
    /// with it before one that only contains it.
    func areas(matching query: String) -> [Country] {
        HikeNameMatch.rankedIndices(of: entries.map(\.fullName), matching: query).map { entries[$0].country }
    }
}

/// The letter a name is filed under in a list by name, and where that letter
/// stands among the others.
struct OfflineCountryLetter {
    let order: Int
    /// What the section it heads, and the list's index, call it.
    let title: String

    /// The letters of the app's language, as the system files a name under
    /// them: `É` under `E` in French, `Ł` after `L` in Polish, and a name
    /// that starts with no letter of the alphabet under `#`, last.
    static func ofTheAppLanguage() -> (String) -> Self {
        #if canImport(UIKit)
        let collation = UILocalizedIndexedCollation.current()
        let titles = collation.sectionTitles
        return { name in
            let section = collation.section(for: name, collationStringSelector: #selector(NSObject.description))
            return Self(order: section, title: titles.indices.contains(section) ? titles[section] : "#")
        }
        #else
        return { name in
            let initial = name.prefix(1).uppercased()
            return Self(order: Int(initial.unicodeScalars.first?.value ?? 0), title: initial)
        }
        #endif
    }
}

/// What *Offline Maps* lists, in the order it lists it.
struct OfflineCountrySections: Equatable {
    /// One heading of the list, and the lines under it.
    struct Part: Equatable, Identifiable {
        enum Heading: Hashable {
            /// Every area not listed above it.
            case all
            /// The countries filed under a letter.
            case letter(String)
            /// The areas within reach of the hiker.
            case nearby
        }

        var heading: Heading
        var lines: [OfflineCountryListing]

        var id: Heading { heading }
    }

    /// What is downloaded or coming down.
    var held: [OfflineCountryManifest.Country]
    /// Everything else, under the order's headings.
    var parts: [Part]

    /// Where the list goes to show `id`: its row in *Downloaded* if it has
    /// one there, else its line further down, opening the country a region
    /// is under.
    func scrollTarget(for id: String) -> (rowID: String, opening: String?) {
        if held.contains(where: { $0.id == id }) { return (id, nil) }
        for line in parts.flatMap(\.lines) {
            if case let .group(group, regions) = line, regions.contains(where: { $0.id == id }) {
                return (Self.groupRowID(id), group)
            }
        }
        return (id, nil)
    }

    /// A region's row under its country, apart from the same region's row in
    /// *Downloaded*.
    static func groupRowID(_ id: String) -> String { "group-\(id)" }

    /// The list's next step towards showing an area.
    enum Reveal: Equatable {
        /// Open the country the area is under. Its regions join the list on
        /// the pass after, and a scroll asked for before then finds no row to
        /// go to, so the scroll waits for them.
        case open(String)
        /// Go to the row.
        case scroll(to: String)
    }

    /// What the list does next to show `id`, with `expanded` the split
    /// countries already open in it.
    func reveal(_ id: String, expanded: Set<String>) -> Reveal {
        let target = scrollTarget(for: id)
        if let group = target.opening, !expanded.contains(group) { return .open(group) }
        return .scroll(to: target.rowID)
    }
}

/// A line of the list: an area, or a country split by region, which holds
/// all its regions.
enum OfflineCountryListing: Equatable, Identifiable {
    case area(OfflineCountryManifest.Country)
    case group(id: String, regions: [OfflineCountryManifest.Country])

    var id: String {
        switch self {
        case let .area(country): country.id
        case let .group(id, _): id
        }
    }
}

/// Keeps the directory across the list's body passes, which far outnumber
/// the changes to what it is made from: a new list off the server, an area
/// downloaded or deleted, and the hiker's position as the list comes up.
final class OfflineCountryDirectoryCache {
    /// What a directory is made from, reduced to what a change of it moves:
    /// each area's id and build, and the position.
    private struct Key: Equatable {
        let offered: [String]
        let installed: [String]
        let latitude: Double?
        let longitude: Double?
    }

    private var key: Key?
    private var directory: OfflineCountryDirectory?
    /// Directories built. A pass that kept one and a pass that built one
    /// hand back the same list, so this is what a suite holds the keeping to.
    private(set) var builds = 0

    func directory(
        offered: [OfflineCountryManifest.Country],
        installed: [String: OfflineCountryStore.Record],
        near: CLLocationCoordinate2D?
    ) -> OfflineCountryDirectory {
        let asked = Key(
            offered: offered.map(Self.stamp),
            installed: installed.values.map { Self.stamp($0.country) }.sorted(),
            latitude: near?.latitude,
            longitude: near?.longitude
        )
        if asked == key, let directory { return directory }
        let built = OfflineCountryDirectory(
            listed: OfflineCountries.listed(offered: offered, installed: installed),
            near: near,
            letter: OfflineCountryLetter.ofTheAppLanguage()
        )
        builds += 1
        key = asked
        directory = built
        return built
    }

    private static func stamp(_ country: OfflineCountryManifest.Country) -> String {
        "\(country.id)@\(country.build)"
    }
}
