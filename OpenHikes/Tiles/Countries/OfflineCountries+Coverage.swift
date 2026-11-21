//
//  OfflineCountries+Coverage.swift
//  OpenHikes
//
//  How much of a saved line the downloaded countries can draw with no
//  signal, for the hike screen's *Offline* tile. A trail that runs on past
//  the countries there are to download is not saved by downloading the ones
//  it crosses: the map goes blank where it leaves them. So the tile says
//  *Saved* only for a line every tested point of which is inside a
//  downloaded country, and *Partly Saved* for one that leaves them.
//

import Algorithms
import CoreLocation
import OpenHikesData

/// What the countries on offer make of a saved line.
struct OfflineRouteCoverage: Equatable {
    /// The countries offered that the line passes through, in the order it
    /// reaches them.
    var crossed: [OfflineCountryManifest.Country] = []
    /// Whether some of the line is in no country offered, which no download
    /// draws.
    var leavesThem = false
}

extension OfflineCountries {
    /// The countries a saved line passes through, and whether it leaves
    /// them, tested every so many points: a country is tens of kilometres
    /// across, so one point every few hundred metres of a long trail still
    /// finds every one it reaches. The last point is always tested.
    func coverage(
        alongRoute route: [RouteCoordinate],
        testing points: Int = 400
    ) -> OfflineRouteCoverage {
        guard !route.isEmpty else { return OfflineRouteCoverage() }
        let step = max(route.count / points, 1)
        var sampled = route.striding(by: step).map(\.clCoordinate)
        if let last = route.last { sampled.append(last.clCoordinate) }
        return coverage(along: sampled)
    }

    /// The countries a line passes through, and whether one of its points is
    /// in none of them.
    func coverage(along coordinates: [CLLocationCoordinate2D]) -> OfflineRouteCoverage {
        let candidates = listed
        let holding = coordinates.map { coordinate in
            candidates.filter { country in
                country.contains(longitude: coordinate.longitude, latitude: coordinate.latitude)
            }
        }
        return OfflineRouteCoverage(
            crossed: holding.joined().uniqued(on: \.id),
            leavesThem: holding.contains(where: \.isEmpty)
        )
    }

    /// Whether the downloaded countries draw all of `coverage`'s line, part
    /// of it, or none: one whose basemap would not open draws none of it.
    func saving(_ coverage: OfflineRouteCoverage) -> OfflineRouteSaving {
        let drawn = coverage.crossed.filter { isDrawn($0.id) }
        if drawn.isEmpty { return .unsaved }
        guard drawn.count == coverage.crossed.count, !coverage.leavesThem else { return .part }
        return .whole
    }
}

/// How much of a hike's line is drawn with no signal.
enum OfflineRouteSaving: Equatable {
    /// Some of it, and not all.
    case part
    /// None of the countries it crosses is down.
    case unsaved
    /// Every tested point is inside a downloaded country.
    case whole
}
