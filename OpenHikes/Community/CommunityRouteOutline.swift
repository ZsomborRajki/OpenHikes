//
//  CommunityRouteOutline.swift
//  OpenHikes
//
//  A published route small enough to travel with the list that found it.
//
//  ``CommunityListing`` deliberately carries no geometry: a nearby query comes
//  back with twenty-five of them, and twenty-five recorded routes is tens of
//  megabytes of transfer for a list the hiker may scroll straight past. That
//  is why the browse path never fetched a route at all — and why the map could
//  only ever say *where* a shared hike starts, as a pin, rather than *where it
//  goes*.
//
//  An outline is the middle term the feature was missing. It is the same line
//  thinned until it is a kilobyte: at most ``maximumPoints`` points, chosen by
//  Ramer–Douglas–Peucker so what survives is the shape rather than every
//  hundredth sample, encoded as text. Twenty-five of them are about twenty-five
//  kilobytes, which is a thing a browse can afford on a phone in a valley.
//
//  **It is a drawing and never a hike.** Elevation, timestamps, provenance and
//  pause boundaries are all dropped, and the points that remain have moved by
//  up to the simplification tolerance. Nothing computes a statistic from one,
//  nothing imports one: ``CommunityImport`` still reads the full route off the
//  submission, which is what the preview loads and what a saved hike is made
//  of. The outline exists to be *looked* at on the map and tapped.
//
//  ## Why the encoding is text
//
//  Google's encoded-polyline format, at five decimal places — about a metre,
//  which is finer than the tolerance the points were thinned with, so the
//  encoding is never the thing that loses detail. It is printable ASCII, which
//  matters for one unglamorous reason: everything about this feature that
//  crosses the reviewer's desk crosses it through the CloudKit Console, and a
//  value a person can see, select and paste is one they can check. A blob
//  cannot be proof-read.
//
//  Decoding is correspondingly suspicious of what it is handed — see
//  ``decoded(_:)``. A truncated paste, a stray quotation mark or a value out
//  of range produces no line at all rather than a line through the Atlantic.
//

import CoreLocation
import Foundation

/// The compact form of a published route: what the map draws before a hike is
/// opened, and what the submission carries so it can.
nonisolated enum CommunityRouteOutline {
    /// The most points an outline may carry.
    ///
    /// Enough that a switchbacked ascent still reads as switchbacks at the
    /// zoom a browse happens at, few enough that a page of results is
    /// kilobytes. It is also the bound the map's tap hit-test is sized
    /// against — see ``CommunityRouteHitTest`` — so a tap costs at most
    /// `resultLimit × maximumPoints` projections however long the original
    /// walks were.
    static let maximumPoints = 128

    /// Where simplification starts, in metres.
    ///
    /// Below the width of the line it will be drawn as at any zoom a whole
    /// route fits on screen at, so the first pass is free detail rather than a
    /// visible change. It is doubled until the point budget is met, which is
    /// what makes the budget a guarantee rather than a hope — see
    /// ``simplified(_:)``.
    static let initialToleranceMeters: Double = 8

    /// Where the doubling stops: one circumference, at which RDP keeps the
    /// two endpoints and nothing else.
    ///
    /// Here so that ``simplified(_:maximumPoints:)`` terminates by
    /// construction rather than by argument — twenty-three doublings, whatever
    /// the route.
    private static let maximumToleranceMeters: Double = 40_075_000

    /// The fixed point the text encoding uses: five decimal places, about a
    /// metre.
    private static let precision: Double = 1e5

    /// The lowest scalar the encoding uses, the highest, and the span above
    /// the lowest that one digit covers. All three are the format's, not
    /// choices.
    private static let asciiOffset: UInt32 = 63
    private static let asciiMaximum: UInt32 = 126
    private static let continuationBit: Int = 0x20
    private static let digitMask: Int = 0x1f
    private static let digitBits: Int = 5
    /// The most digits one coordinate can need: six five-bit digits cover the
    /// thirty bits a whole-world delta takes. A run longer than this is not
    /// something the encoder wrote.
    private static let maximumDigits = 6

    // MARK: - Making one

    /// `route` thinned to the point budget and encoded, or `nil` for a route
    /// with no line in it.
    ///
    /// `nil` rather than an empty string on purpose: a submission with no
    /// outline field is the ordinary state of every hike published before this
    /// existed, and the map already draws nothing for those. Writing an empty
    /// string would make a hike with an unusable route look the same as one
    /// with none while costing a field to say so.
    static func encoded(_ route: [RouteCoordinate]) -> String? {
        let outline = simplified(route)
        guard outline.count >= 2 else { return nil }
        return encode(outline)
    }

    /// `route` with everything that does not change its shape taken out.
    ///
    /// Ramer–Douglas–Peucker at ``initialToleranceMeters``, doubling the
    /// tolerance until the result fits ``maximumPoints``. Doubling rather than
    /// a stride over what RDP returned, because a stride drops points by
    /// position and RDP drops them by how little they matter — a hairpin
    /// survives a coarser tolerance and does not survive every second point
    /// being deleted.
    static func simplified(
        _ route: [RouteCoordinate],
        maximumPoints: Int = Self.maximumPoints
    ) -> [CLLocationCoordinate2D] {
        let points = route.map(\.clCoordinate).filter { CLLocationCoordinate2DIsValid($0) }
        guard points.count > 2 else { return points }
        guard points.count > maximumPoints else { return points }

        var tolerance = initialToleranceMeters
        var outline = simplify(points, toleranceMeters: tolerance)
        while outline.count > maximumPoints, tolerance < maximumToleranceMeters {
            tolerance *= 2
            outline = simplify(points, toleranceMeters: tolerance)
        }
        return outline
    }

    // MARK: - Reading one back

    /// The line `encoded` describes, or an empty array for anything that is
    /// not one.
    ///
    /// Strict, and deliberately silent about why. What reaches here is a field
    /// off a record in a public database, which is to say text that a person
    /// may have pasted by hand and a modified client may have written on
    /// purpose. Neither is an error the hiker can act on, and both have the
    /// same right answer: draw no line, leave the pin standing, let them open
    /// the hike and get the real route.
    ///
    /// The four ways it refuses are the four ways the format can lie — a digit
    /// run that never terminates, a pair that is missing its second half, a
    /// coordinate outside the world, and more points than an outline may have.
    /// The third matters most: a single corrupt delta would otherwise walk
    /// every point after it off the map, and a route drawn across the ocean is
    /// a worse answer than none.
    ///
    /// ``maximumPoints`` is a **maximum** here and not a hint. What is on the
    /// wire is a field this app wrote on upload, but what comes back is a
    /// public record, and the budget it is held to on the way out is the one
    /// the map and the tap hit-test are sized against on the way in — a tap
    /// projects every accepted point of every drawn line, on the main actor.
    /// So an overlong line is refused outright rather than cut down to size:
    /// truncating would draw a trail that stops in the middle of nowhere and
    /// claim it is somebody's walk.
    static func decoded(_ encoded: String) -> [CLLocationCoordinate2D] {
        var scalars = Array(encoded.unicodeScalars)[...]
        var latitude = 0
        var longitude = 0
        var coordinates: [CLLocationCoordinate2D] = []
        coordinates.reserveCapacity(maximumPoints)

        while !scalars.isEmpty {
            // Checked before the pair is read rather than after it is
            // appended, so a string of any length costs the budget and stops.
            guard coordinates.count < maximumPoints else { return [] }
            guard let latitudeDelta = nextValue(&scalars),
                  let longitudeDelta = nextValue(&scalars)
            else { return [] }
            latitude += latitudeDelta
            longitude += longitudeDelta
            let coordinate = CLLocationCoordinate2D(
                latitude: Double(latitude) / precision,
                longitude: Double(longitude) / precision
            )
            guard CLLocationCoordinate2DIsValid(coordinate) else { return [] }
            coordinates.append(coordinate)
        }
        return coordinates
    }

    /// The same, as the route points the rest of the app passes around.
    ///
    /// Elevation and time are absent rather than zeroed: an outline never had
    /// them, and a zero would be a measurement.
    static func decodedRoute(_ encoded: String) -> [RouteCoordinate] {
        decoded(encoded).map(RouteCoordinate.init)
    }
}

// MARK: - Ramer–Douglas–Peucker

// `nonisolated` on the extension, not decoration: `SWIFT_DEFAULT_ACTOR_ISOLATION
// = MainActor` makes an unannotated extension main-actor isolated, and every
// caller here is either the `@concurrent` upload path or the map's own
// nonisolated decode.
nonisolated private extension CommunityRouteOutline {
    /// The classic algorithm, with an explicit stack rather than recursion.
    ///
    /// A recorded day is tens of thousands of points and the worst case for
    /// this split is one point per level, so recursion here is a stack
    /// overflow waiting for a route that happens to be nearly straight in the
    /// wrong way.
    static func simplify(
        _ points: [CLLocationCoordinate2D],
        toleranceMeters: Double
    ) -> [CLLocationCoordinate2D] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true

        var pending = [(first: 0, last: points.count - 1)]
        while let span = pending.popLast() {
            guard span.last > span.first + 1 else { continue }
            var farthest = span.first
            var farthestDistance = 0.0
            for index in (span.first + 1)..<span.last {
                let distance = perpendicularDistanceMeters(
                    of: points[index],
                    from: points[span.first],
                    to: points[span.last]
                )
                if distance > farthestDistance {
                    farthestDistance = distance
                    farthest = index
                }
            }
            guard farthestDistance > toleranceMeters else { continue }
            keep[farthest] = true
            pending.append((first: span.first, last: farthest))
            pending.append((first: farthest, last: span.last))
        }

        return points.enumerated().compactMap { index, point in keep[index] ? point : nil }
    }

    /// How far `point` lies from the segment between `start` and `end`, in
    /// metres.
    ///
    /// On the local tangent plane through `start`, which is what
    /// ``RouteGeometry/localOffset(from:to:)`` already gives the route matcher:
    /// over the length of one RDP span the curvature of the earth is far
    /// below the tolerance being measured against, and the flat-plane answer
    /// is the one that costs no trigonometry per candidate point.
    static func perpendicularDistanceMeters(
        of point: CLLocationCoordinate2D,
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> Double {
        let segment = RouteGeometry.localOffset(from: start, to: end)
        let candidate = RouteGeometry.localOffset(from: start, to: point)
        let lengthSquared = segment.x * segment.x + segment.y * segment.y
        // A degenerate span — the route stood still — leaves the distance to
        // the point itself, which is the honest answer and keeps the maths
        // out of a division by zero.
        guard lengthSquared > 0 else {
            return (candidate.x * candidate.x + candidate.y * candidate.y).squareRoot()
        }
        let cross = candidate.x * segment.y - candidate.y * segment.x
        return abs(cross) / lengthSquared.squareRoot()
    }
}

// MARK: - The text format

// `nonisolated` for the reason the extension above is.
nonisolated private extension CommunityRouteOutline {
    static func encode(_ points: [CLLocationCoordinate2D]) -> String {
        var digits = ""
        digits.reserveCapacity(points.count * 8)
        var latitude = 0
        var longitude = 0
        for point in points {
            let scaledLatitude = Int((point.latitude * precision).rounded())
            let scaledLongitude = Int((point.longitude * precision).rounded())
            // Deltas, which is the whole of why this is small: consecutive
            // points of a walk differ in the last two or three digits.
            append(value: scaledLatitude - latitude, to: &digits)
            append(value: scaledLongitude - longitude, to: &digits)
            latitude = scaledLatitude
            longitude = scaledLongitude
        }
        return digits
    }

    /// One signed value, zig-zagged and split into five-bit digits.
    ///
    /// Appended rather than returned, so the whole line is one string rather
    /// than one per coordinate. Scalars are built from `UInt8` on purpose:
    /// every digit this writes is printable ASCII by construction, and that
    /// initializer cannot fail, so there is no fallback to invent for a case
    /// that cannot arise.
    static func append(value: Int, to digits: inout String) {
        // Zig-zag: the sign moves into the low bit so a small negative number
        // stays a small number rather than becoming a run of set bits.
        var remaining = value < 0 ? ~(value << 1) : value << 1
        while remaining >= continuationBit {
            let digit = (continuationBit | (remaining & digitMask)) + Int(asciiOffset)
            digits.unicodeScalars.append(UnicodeScalar(UInt8(digit)))
            remaining >>= digitBits
        }
        digits.unicodeScalars.append(UnicodeScalar(UInt8(remaining + Int(asciiOffset))))
    }

    /// The next signed value, consuming the digits it is made of, or `nil` for
    /// a run that ends without a terminating digit or carries a scalar the
    /// format never produces.
    static func nextValue(_ scalars: inout ArraySlice<UnicodeScalar>) -> Int? {
        var shift = 0
        var accumulated = 0
        while let scalar = scalars.first {
            scalars = scalars.dropFirst()
            guard scalar.value >= asciiOffset, scalar.value <= asciiMaximum else { return nil }
            // A run long enough to overflow is not one this format produced —
            // see ``maximumDigits``.
            guard shift < digitBits * maximumDigits else { return nil }
            let digit = Int(scalar.value - asciiOffset)
            accumulated |= (digit & digitMask) << shift
            shift += digitBits
            guard digit & continuationBit != 0 else {
                // Undo the zig-zag.
                return accumulated & 1 != 0 ? ~(accumulated >> 1) : accumulated >> 1
            }
        }
        return nil
    }
}
