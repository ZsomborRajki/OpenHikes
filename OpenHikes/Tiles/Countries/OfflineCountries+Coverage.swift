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
//  Nothing of it is worked out on the main actor (#1537). The tile asks as
//  the hike screen opens, while the screen is being laid out, and the list
//  is every area there is: putting it together names and orders hundreds
//  of them, before a leg is tested. So the main actor hands over what the
//  list is read from, two values it copies for nothing, and the list is
//  put together beside the measuring.
//

import OpenHikesData

extension OfflineCountries {
    /// The countries on the list a saved line passes through, and whether
    /// it leaves them, worked out off the main actor from the list as it
    /// stands when asked.
    func coverage(alongRoute route: [RouteCoordinate]) async throws(CancellationError) -> OfflineRouteCoverage {
        try await Self.coverage(alongRoute: route, offered: offered, installed: installed)
    }

    /// The same, of what a caller has already read: the list ``listed``
    /// would give, in its order, and the line measured against it.
    ///
    /// It asserts it is off the main thread, so a debug build traps the day
    /// the `@concurrent` hop stops happening.
    @concurrent
    nonisolated static func coverage(
        alongRoute route: [RouteCoordinate],
        offered: [Country],
        installed: [String: Record]
    ) async throws(CancellationError) -> OfflineRouteCoverage {
        assertOffMainThread("A line's coverage puts the whole list together and tests every walked leg")
        return try OfflineRouteCoverage(walking: route, through: listed(offered: offered, installed: installed))
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
