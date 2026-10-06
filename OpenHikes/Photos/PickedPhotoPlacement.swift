//
//  PickedPhotoPlacement.swift
//  OpenHikes
//
//  Where on the trail a photograph handed over by the system picker belongs.
//
//  The picker used to pin everything it was given to the elevation graph's
//  selection, on the argument that importing is a "these belong to this walk"
//  gesture with no per-photo position to be had. There is one, and it is the
//  one "Find Photos of This Hike" already uses: the picture carries the second
//  it was taken and, usually, the place, and the walk carries a position for
//  nearly every second it lasted. So a picked photo is put through the same
//  ``HikePhotoSearchPlan`` a library scan is, and lands where a scan would
//  have put it.
//
//  Where the clock cannot speak — a picture with no capture time in it, one
//  taken on another day, a trail that has never been walked with this app —
//  the camera's own position still can. A photograph the hiker picked by hand
//  whose GPS is on this route is a photograph of this trail, whenever it was
//  taken, and it is snapped onto the route where the camera was. This is the
//  one place the picker is deliberately looser than the scan: the scan's time
//  window is what stops it offering every picture ever taken near the trail,
//  and a hand-picked photo needs no such protection.
//
//  The graph selection is the fallback for what is left: a picture with no
//  usable position — location off for the camera, a screenshot, the picker's
//  *Location* option turned off — or one the camera put somewhere the trail
//  never goes. Those are the cases where the hiker's own pointing is the best
//  evidence there is.
//
//  What the photo says about itself is read out of its bytes rather than its
//  library record. The picker runs out of process and costs no photo-library
//  permission, and asking `PHAsset` for a creation date and a location would
//  bring the prompt back for a gesture that has never needed one. The EXIF
//  block is the same two facts, and it travels with the data the picker
//  already handed over.
//

import CoreLocation
import Foundation
import ImageIO
import OpenHikesData
import SwiftData

/// The two facts a picked photograph carries about itself.
nonisolated struct PickedPhotoMetadata: Equatable, Sendable {
    /// When the shutter fired, or `nil` when the file says nothing readable.
    let capturedAt: Date?
    /// Where the camera was, or `nil` — location off for the camera, a
    /// screenshot, or the picker's own *Location* option turned off.
    let latitude: Double?
    let longitude: Double?

    static let empty = Self(capturedAt: nil, coordinate: nil)

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        let candidate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2DIsValid(candidate) ? candidate : nil
    }

    init(capturedAt: Date?, coordinate: CLLocationCoordinate2D?) {
        self.capturedAt = capturedAt
        latitude = coordinate?.latitude
        longitude = coordinate?.longitude
    }

    /// Reads the capture time and the GPS block out of image bytes.
    ///
    /// Only the properties are parsed — no pixel is decoded — but it is still
    /// a walk through a file that can be tens of megabytes, so it stays off
    /// the main thread like every other ImageIO read in this app.
    ///
    /// - Parameter timeZone: The zone a capture time is read in when the file
    ///   does not say. EXIF's `DateTimeOriginal` is wall-clock with no zone;
    ///   every iPhone since iOS 13 writes `OffsetTimeOriginal` beside it, and
    ///   that wins whenever it is there.
    static func read(_ data: Data, timeZone: TimeZone = .current) -> Self {
        assertOffMainThread("Reading a picked photo's metadata must stay off the main thread")
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else { return .empty }
        return Self(properties: properties, timeZone: timeZone)
    }

    init(properties: [String: Any], timeZone: TimeZone = .current) {
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let zone = (exif?[kCGImagePropertyExifOffsetTimeOriginal as String] as? String)
            .flatMap(Self.timeZone(fromOffset:)) ?? timeZone
        self.init(
            capturedAt: CameraCaptureMetadata.capturedAt(in: properties, timeZone: zone),
            coordinate: Self.coordinate(
                in: properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
            )
        )
    }

    /// The widest UTC offsets in use, and the shape of the minutes beside them.
    private static let offsetHours = 0...14
    private static let offsetMinutes = 0...59
    private static let secondsPerHour = 3600
    private static let secondsPerMinute = 60

    /// EXIF's `±HH:MM`, as a zone.
    private static func timeZone(fromOffset text: String) -> TimeZone? {
        let sign: Int
        switch text.first {
        case "+": sign = 1
        case "-": sign = -1
        default: return nil
        }
        let parts = text.dropFirst().split(separator: ":").compactMap { Int($0) }
        guard let hours = parts.first, let minutes = parts.last, parts.count == 2,
              offsetHours.contains(hours), offsetMinutes.contains(minutes)
        else { return nil }
        return TimeZone(secondsFromGMT: sign * (hours * secondsPerHour + minutes * secondsPerMinute))
    }

    /// Unsigned magnitudes and a hemisphere beside each — the only form EXIF
    /// has for a coordinate, and the one ``PhotoMetadataStamp`` writes.
    private static func coordinate(in gps: [String: Any]) -> CLLocationCoordinate2D? {
        guard let northing = gps[kCGImagePropertyGPSLatitude as String] as? Double,
              let easting = gps[kCGImagePropertyGPSLongitude as String] as? Double
        else { return nil }
        let south = (gps[kCGImagePropertyGPSLatitudeRef as String] as? String) == "S"
        let west = (gps[kCGImagePropertyGPSLongitudeRef as String] as? String) == "W"
        let read = CLLocationCoordinate2D(
            latitude: south ? -abs(northing) : abs(northing),
            longitude: west ? -abs(easting) : abs(easting)
        )
        return CLLocationCoordinate2DIsValid(read) ? read : nil
    }
}

/// Where a picked photo is pinned, when it is said to have been taken, and on
/// what evidence.
nonisolated struct PickedPhotoPlacement: Equatable, Sendable {
    let latitude: Double?
    let longitude: Double?
    let capturedAt: Date
    /// `nil` for the graph-selection fallback, which is the app's own answer
    /// and needs no explaining — see ``PhotoMatchEvidence``.
    let evidence: PhotoMatchEvidence?

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(coordinate: CLLocationCoordinate2D?, capturedAt: Date, evidence: PhotoMatchEvidence?) {
        latitude = coordinate?.latitude
        longitude = coordinate?.longitude
        self.capturedAt = capturedAt
        self.evidence = evidence
    }

    /// The rules in this file's header, applied to one photograph.
    ///
    /// - Parameters:
    ///   - plan: The hike's search plan, or `nil` when the photo is being
    ///     filed under a place — a place's own screen is a statement of where
    ///     the picture belongs, and the place is where it is pinned.
    ///   - fallback: The graph selection at the moment the picker closed.
    ///   - now: The capture time of a photograph that carries none, which is
    ///     what the picker path has always dated it by.
    static func resolve(
        _ metadata: PickedPhotoMetadata,
        plan: HikePhotoSearchPlan?,
        fallback: CLLocationCoordinate2D?,
        now: Date = .now
    ) -> Self {
        let dated = metadata.capturedAt ?? now
        if let plan, let takenAt = metadata.capturedAt,
           let match = plan.matches(
               assets: [
                   PhotoLibraryAsset(
                       // Identity plays no part in a single-asset match; the
                       // picker's own identifier travels separately.
                       localIdentifier: "picked",
                       createdAt: takenAt,
                       coordinate: metadata.coordinate
                   ),
               ]
           ).first {
            return Self(coordinate: match.coordinate, capturedAt: dated, evidence: match.evidence)
        }
        // No clock to place it by, but a position on this trail: snapped
        // where the camera was, on the same terms as the scan's own `.place`.
        if let plan, let camera = metadata.coordinate,
           let nearest = LibraryPhotoMatcher.nearestRoutePoint(to: camera, in: plan.route),
           nearest.meters <= LibraryPhotoMatcher.maximumOffRouteMeters {
            return Self(coordinate: nearest.coordinate, capturedAt: dated, evidence: .place)
        }
        return Self(coordinate: fallback, capturedAt: dated, evidence: nil)
    }
}

extension HikePhotoImport {
    /// Stores one photograph from the picker, pinned where
    /// ``PickedPhotoPlacement`` says it belongs.
    ///
    /// - Parameters:
    ///   - plan: Built once for the whole selection by the caller — it is
    ///     route-sized work — and `nil` for a photo filed under a place.
    ///   - fallback: The anchor in force when the picker closed.
    @MainActor
    static func addPicked(
        _ data: Data,
        to hike: Hike,
        plan: HikePhotoSearchPlan?,
        fallback: CLLocationCoordinate2D?,
        assetLocalIdentifier: String?,
        placeID: UUID? = nil,
        store: HikePhotoStore = .shared,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) async -> HikePhoto? {
        let metadata = await pickedMetadata(of: data)
        let placement = PickedPhotoPlacement.resolve(metadata, plan: plan, fallback: fallback)
        return await add(
            data,
            to: hike,
            coordinate: placement.coordinate,
            // Never mirrored: the picture is already in the library.
            savesToPhotoLibrary: false,
            capturedAt: placement.capturedAt,
            assetLocalIdentifier: assetLocalIdentifier,
            matchEvidence: placement.evidence,
            placeID: placeID,
            store: store,
            save: save
        )
    }

    @concurrent
    private static func pickedMetadata(of data: Data) async -> PickedPhotoMetadata {
        PickedPhotoMetadata.read(data)
    }
}
