//
//  OfflineCountries+Coverage.swift
//  OpenHikes
//
//  How much of a saved line the downloaded countries can draw with no
//  signal, for the hike screen's *Offline* tile. A trail that runs on past
//  the countries there are to download is not saved by downloading the ones
//  it crosses: the map goes blank where it leaves them. So the tile says
//  *Saved* only for a line every walked leg of which is inside downloaded
//  countries, from end to end (``OfflineRouteCoverage``), and *Partly Saved*
//  for one that leaves them.
//

import OpenHikesData

extension OfflineCountries {
    /// The countries on the list a saved line passes through, and whether
    /// it leaves them, measured off the main actor.
    func coverage(alongRoute route: [RouteCoordinate]) async throws(CancellationError) -> OfflineRouteCoverage {
        try await OfflineRouteCoverage.measuring(route, through: listed)
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
    /// Every walked leg, and every lone fix, is inside a downloaded country.
    case whole
}
