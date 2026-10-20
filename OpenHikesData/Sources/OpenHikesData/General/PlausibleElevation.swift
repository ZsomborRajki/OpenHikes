//
//  PlausibleElevation.swift
//  OpenHikes
//
//  Whether a height read out of somebody else's file can be ground a person
//  stood on.
//
//  The non-finite heights were refused long ago; this is the finite sibling.
//  `-9999` and `-32768` are the void markers of SRTM-derived elevation models
//  and of 16-bit altitude fields, and `0` is what plenty of loggers write when
//  they have no altitude fix. ``ElevationAccumulator`` cannot tell a one-sample
//  spike from a step — by design, see its header — so one such height between
//  two at 1 000 m is two 1 000 m runs, and a 119 m climb reported 11 177 m of
//  gain with a single `-9999` in it. A recording is not exposed: its heights
//  pass a vertical-accuracy check first. ``GPXImport`` and
//  ``CommunityRoutePayload`` have no such check, and both apply this one.
//
//  A height that fails is treated as absent, as a non-finite one already is:
//  the position is what the line is made of, the height is a field the route
//  can do without, and the accumulator skips a missing height without
//  breaking its run.
//

import CoreLocation

nonisolated public enum PlausibleElevation {
    /// Every height a walk can be at, with margin: the Dead Sea shore is at
    /// about −430 m and Everest's summit at 8 849 m. Both void markers above
    /// are well outside it.
    public static let range: ClosedRange<Double> = -500...9000

    /// How far a lone height must be from both neighbours to count as a
    /// placeholder, and how close those two neighbours must be to each other.
    public static let spikeMeters = 100.0

    /// `elevation` if it can be a height on the ground, `nil` if it cannot.
    /// A NaN or an infinity is outside ``range`` as well, so this is also the
    /// non-finite check.
    public static func validated(_ elevation: Double?) -> Double? {
        guard let elevation, range.contains(elevation) else { return nil }
        return elevation
    }

    /// The offsets in `samples` whose height is a placeholder sitting inside
    /// ``range`` — the stray `0` on a walk at 1 000 m.
    ///
    /// A median-of-three over the samples that have a height: one is a spike
    /// when it is more than ``spikeMeters`` from *both* neighbours, those two
    /// are within ``spikeMeters`` of each other, and reaching it from either
    /// side would be steeper than one in one. The last condition is what keeps
    /// a real summit on a sparse planned route — 500 m above two stops a
    /// kilometre either side of it is a steep path, not a placeholder.
    ///
    /// Judged against the heights as written, as ``GPXImport``'s teleport rule
    /// is, so two placeholders in a row vouch for each other and are kept, and
    /// the first and last heights have one neighbour each and are left alone.
    /// Apply ``validated(_:)`` first, so a void run's neighbours are the real
    /// heights around it rather than the markers.
    public static func spikes(
        in samples: [(coordinate: CLLocationCoordinate2D, elevation: Double?)]
    ) -> Set<Int> {
        let measured = samples.indices.filter { samples[$0].elevation != nil }
        guard measured.count > 2 else { return [] }
        var spikes = Set<Int>()
        for position in 1..<(measured.count - 1) {
            let (before, here, after) = (measured[position - 1], measured[position], measured[position + 1])
            guard let previous = samples[before].elevation,
                  let height = samples[here].elevation,
                  let next = samples[after].elevation
            else { continue }
            let rise = abs(height - previous)
            let fall = abs(height - next)
            guard rise > spikeMeters, fall > spikeMeters, abs(next - previous) <= spikeMeters else { continue }
            let toBefore = RouteGeometry.distanceMeters(
                from: samples[before].coordinate, to: samples[here].coordinate
            )
            let toAfter = RouteGeometry.distanceMeters(
                from: samples[here].coordinate, to: samples[after].coordinate
            )
            if rise > toBefore, fall > toAfter { spikes.insert(here) }
        }
        return spikes
    }

    /// `route` with the height of every one of its ``spikes(in:)`` emptied.
    /// Positions, times and boundaries are untouched.
    public static func despiked(_ route: [RouteCoordinate]) -> [RouteCoordinate] {
        let spikes = spikes(in: route.map { ($0.clCoordinate, $0.elevation) })
        guard !spikes.isEmpty else { return route }
        var despiked = route
        for index in spikes { despiked[index].elevation = nil }
        return despiked
    }
}
