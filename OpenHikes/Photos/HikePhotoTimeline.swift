//
//  HikePhotoTimeline.swift
//  OpenHikes
//
//  Where the walker was at a given moment.
//
//  Every other way this app pins a photo to the trail asks the *app* where it
//  is: the elevation graph's selection, or the recording's last accepted fix.
//  Neither exists for a picture taken with the system camera while OpenHikes
//  was closed, which is what most people's hike photos actually are. What does
//  exist is the route itself — a list of positions each stamped with the
//  second it was measured — and a photograph carries the second it was taken.
//  Put the two together and the walk becomes a lookup table from time to
//  place.
//
//  Two rules keep that lookup honest, and both are about refusing to answer.
//
//  A photograph taken before the walk started or after it ended is only placed
//  if it falls within ``graceInterval`` of an end, and then only at that end —
//  the trailhead photo taken while the recording was still being started is
//  real, the one from the drive home is not. And a stretch the walk produced
//  no fix across is a stretch we do not know the route of: inside a gap longer
//  than ``graceInterval`` either side, the answer is `nil` rather than a
//  plausible-looking point halfway along a line nobody walked.
//
//  ``secondsFromFix`` carries what is left of the doubt out to the caller, so
//  a picture placed by interpolation can say how far it was interpolated
//  rather than presenting itself as a measurement.
//

import CoreLocation
import Foundation

nonisolated struct HikePhotoTimeline: Sendable {
    /// How far outside a fix a photograph can be taken and still be placed at
    /// it — at either end of the walk, or either side of a gap in the middle.
    ///
    /// Five minutes is roughly a quarter of a kilometre at walking pace, which
    /// is the largest error worth offering at all: past that the pin stops
    /// describing where the picture was taken and starts describing where the
    /// route happens to run.
    static let graceInterval: TimeInterval = 300

    /// One timestamped position from the walk.
    ///
    /// Latitude and longitude rather than a `CLLocationCoordinate2D`, so the
    /// value is `Equatable` and a test can say what it expects — the same
    /// reason ``RecordingPoint`` stores them apart.
    struct Fix: Equatable, Sendable {
        let timestamp: Date
        let latitude: Double
        let longitude: Double

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    /// Where the walker was at a moment, and how much of that is inference.
    struct Position: Equatable, Sendable {
        let latitude: Double
        let longitude: Double
        /// Seconds between the moment asked about and the nearest fix used to
        /// answer. Zero when a fix landed on it exactly.
        let secondsFromFix: TimeInterval

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    /// Ascending by timestamp, one entry per distinct second the walk
    /// measured.
    let fixes: [Fix]

    /// The first and last moment the walk itself accounts for.
    var start: Date { fixes[0].timestamp }
    var end: Date { fixes[fixes.count - 1].timestamp }

    /// Every moment a photograph of this walk could carry, the grace at both
    /// ends included. This is the range the photo library is queried with, so
    /// the fetch itself is already narrowed to the walk rather than filtered
    /// down afterwards.
    var searchWindow: ClosedRange<Date> {
        let earliest = start.addingTimeInterval(-Self.graceInterval)
        let latest = end.addingTimeInterval(Self.graceInterval)
        return earliest...latest
    }

    /// `nil` for a route with no timestamps at all, which is the honest answer
    /// for a GPX exported without them and the reason the button this backs is
    /// hidden rather than disabled on such a hike.
    ///
    /// Sorted rather than assumed sorted: a recorded route is chronological by
    /// construction, but an imported one is whatever the file said, and a
    /// single out-of-order point would break every binary search below.
    init?(route: [RouteCoordinate]) {
        let stamped = route.compactMap { point -> Fix? in
            guard let timestamp = point.timestamp else { return nil }
            return Fix(
                timestamp: timestamp,
                latitude: point.latitude,
                longitude: point.longitude
            )
        }
        guard !stamped.isEmpty else { return nil }
        // Sorted by timestamp, and only the first of any duplicate kept: two
        // fixes sharing a second would make the interpolation below divide by
        // zero, and a GPX writer that rounds to whole seconds produces them
        // routinely.
        var ordered: [Fix] = []
        ordered.reserveCapacity(stamped.count)
        for fix in stamped.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard ordered.last?.timestamp != fix.timestamp else { continue }
            ordered.append(fix)
        }
        fixes = ordered
    }

    /// Where the walker was at `date`, or `nil` when the walk cannot say.
    func position(at date: Date) -> Position? {
        if date <= start {
            return endPosition(fixes[0], offsetTo: date)
        }
        if date >= end {
            return endPosition(fixes[fixes.count - 1], offsetTo: date)
        }
        let index = segmentIndex(containing: date)
        let earlier = fixes[index]
        let later = fixes[index + 1]
        let gap = later.timestamp.timeIntervalSince(earlier.timestamp)
        let sinceEarlier = date.timeIntervalSince(earlier.timestamp)
        let untilLater = later.timestamp.timeIntervalSince(date)
        let secondsFromFix = min(sinceEarlier, untilLater)
        // A gap the walk produced no fix across is a stretch whose route is
        // unknown, however straight the line drawn over it looks. Placing a
        // photo at the nearer end of it is only defensible while that end is
        // close enough to be where the walker still was.
        guard secondsFromFix <= Self.graceInterval else { return nil }
        let coordinate = RouteGeometry.interpolate(
            from: earlier.coordinate,
            to: later.coordinate,
            fraction: sinceEarlier / gap
        )
        return Position(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            secondsFromFix: secondsFromFix
        )
    }

    /// A photograph outside the walk's own span, placed at the end nearest to
    /// it — but only while that end is within the grace.
    private func endPosition(_ fix: Fix, offsetTo date: Date) -> Position? {
        let offset = abs(date.timeIntervalSince(fix.timestamp))
        guard offset <= Self.graceInterval else { return nil }
        return Position(
            latitude: fix.latitude,
            longitude: fix.longitude,
            secondsFromFix: offset
        )
    }

    /// The index `i` with `fixes[i].timestamp < date < fixes[i + 1].timestamp`.
    ///
    /// Only ever called for a `date` strictly inside the span, which is what
    /// makes the result safe to index a pair with. A route is tens of
    /// thousands of points and a library scan asks this once per candidate
    /// photo, so it is a binary search rather than a walk.
    private func segmentIndex(containing date: Date) -> Int {
        var low = 0
        var high = fixes.count - 1
        while high - low > 1 {
            let middle = low + (high - low) / 2
            if fixes[middle].timestamp <= date {
                low = middle
            } else {
                high = middle
            }
        }
        return low
    }
}

extension Hike {
    /// This hike's time-to-place index, or `nil` when its route carries no
    /// timestamps.
    ///
    /// Built on demand rather than stored: it is derived entirely from
    /// ``route``, and the one screen that wants it wants it once, behind a
    /// button tap.
    var photoTimeline: HikePhotoTimeline? { HikePhotoTimeline(route: route) }

    /// Whether it is worth offering to look through the photo library for
    /// pictures of this walk.
    var canMatchLibraryPhotos: Bool {
        route.contains { $0.timestamp != nil }
    }

    /// The library assets already imported into this hike, so a second scan
    /// offers only what a first one didn't take.
    var importedPhotoAssetIdentifiers: Set<String> {
        Set(photos.compactMap(\.assetLocalIdentifier))
    }
}
