//
//  Areas.swift
//  offline-countries
//
//  What is cut: every country Natural Earth outlines, whole, except the few
//  too big for one download (`split` in Scripts/lib/offline-countries.json),
//  which are cut by their states and provinces instead and listed under the
//  country. Measured against the planet build of 2026-11-17, only the United
//  States, Canada and Russia passed 5 GB at zoom 14.
//
//  A country is keyed by its ISO 3166-1 code and a region by its ISO 3166-2
//  one, and the codes decide where an area belongs where Natural Earth's
//  outlines say otherwise: Natural Earth draws borders as they are held, so
//  it files Crimea and Sevastopol under Russia, while their codes, UA-43 and
//  UA-40, are Ukraine's. Such a region goes into the country its code names.
//  Natural Earth's few areas with no ISO code join the country ISO 3166 has
//  them in (`attach`), or are left out.
//

import Foundation

/// One area to cut: a country, or a region of one split by size.
struct AreaChoice {
    let id: String
    /// The country a region is listed under; `nil` for a whole country.
    let group: String?
    /// A region's name in each of the app's languages; none for a country.
    let names: [String: String]
    let rings: [Ring]
}

/// `Scripts/lib/offline-countries.json`.
struct AreaPlan: Decodable {
    /// The countries cut by region rather than whole, by ISO 3166-1 code.
    let split: [String]
    /// Natural Earth countries with no ISO code, by `NAME`, and the country
    /// each is part of in ISO 3166.
    let attach: [String: String]
}

enum Areas {
    /// The app's languages, whose names a region carries.
    static let languages = ["en", "de", "fr", "es", "it", "ru", "pl", "uk"]
    /// Web Mercator's edge: Antarctica's outline reaches the pole, which no
    /// tile row does.
    static let mercatorLatitude = 85.0511

    enum Failure: Error, CustomStringConvertible {
        case noRegions(String)

        var description: String {
            switch self {
            case let .noRegions(code): "Natural Earth has no states or provinces for \(code)"
            }
        }
    }

    /// Every area to cut, by id: the countries of `countries` (Natural
    /// Earth's admin-0) whole, and those `plan` splits as their regions in
    /// `regions` (its admin-1).
    static func all(plan: AreaPlan, countries: [[String: Any]], regions: [[String: Any]]) throws -> [AreaChoice] {
        let split = Set(plan.split)
        var whole: [String: [Ring]] = [:]
        for feature in countries {
            guard let properties = feature["properties"] as? [String: Any] else { continue }
            let iso = properties["ISO_A2_EH"] as? String ?? ""
            let code = OfflineCountryManifest.isAreaCode(iso) ? iso : plan.attach[properties["NAME"] as? String ?? ""]
            guard let code, !split.contains(code) else { continue }
            whole[code, default: []] += outerRings(of: feature)
        }
        var areas: [AreaChoice] = []
        var regionCount: [String: Int] = [:]
        for feature in regions {
            guard let properties = feature["properties"] as? [String: Any],
                  let filedUnder = properties["iso_a2"] as? String, split.contains(filedUnder),
                  let code = properties["iso_3166_2"] as? String,
                  OfflineCountryManifest.isAreaCode(code), code.contains("-")
            else { continue }
            let country = String(code.prefix(2))
            guard split.contains(country) else {
                // Filed under a split country, and its code says another's.
                whole[country, default: []] += outerRings(of: feature)
                continue
            }
            regionCount[country, default: 0] += 1
            areas.append(AreaChoice(id: code, group: country, names: names(of: properties), rings: outerRings(of: feature)))
        }
        for code in split where regionCount[code] == nil { throw Failure.noRegions(code) }
        areas += whole.map { AreaChoice(id: $0.key, group: nil, names: [:], rings: $0.value) }
        return areas.sorted { $0.id < $1.id }
    }

    /// The outer ring of every polygon of `feature`, its latitudes kept to
    /// the map's.
    static func outerRings(of feature: [String: Any]) -> [Ring] {
        guard let geometry = feature["geometry"] as? [String: Any], let type = geometry["type"] as? String else {
            return []
        }
        let polygons: [Any]
        switch type {
        case "Polygon": polygons = [geometry["coordinates"] as Any]
        case "MultiPolygon": polygons = geometry["coordinates"] as? [Any] ?? []
        default: return []
        }
        return polygons.compactMap { polygon -> Ring? in
            guard let outer = (polygon as? [Any])?.first as? [[Double]] else { return nil }
            let ring = outer.compactMap { pair -> (lon: Double, lat: Double)? in
                guard pair.count >= 2 else { return nil }
                return (lon: pair[0], lat: min(max(pair[1], -mercatorLatitude), mercatorLatitude))
            }
            return ring.count >= 3 ? ring : nil
        }
    }

    /// A region's name in each of the app's languages that Natural Earth has
    /// one in, English always.
    static func names(of properties: [String: Any]) -> [String: String] {
        var names: [String: String] = [:]
        for language in languages {
            if let name = properties["name_\(language)"] as? String, !name.isEmpty { names[language] = name }
        }
        if names["en"] == nil, let name = properties["name"] as? String { names["en"] = name }
        return names
    }
}
