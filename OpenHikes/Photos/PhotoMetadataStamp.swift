//
//  PhotoMetadataStamp.swift
//  OpenHikes
//
//  Writing what the app knows about a photograph into the photograph.
//
//  Only one path needs this, and it is the opt-in copy that leaves the app —
//  see ``PhotoLibraryWriter``. A photo taken in OpenHikes is encoded from a
//  `UIImage`, which is pixels and nothing else: no EXIF, no `DateTimeOriginal`,
//  no GPS. Filed into the photo library as-is it lands in Recents under the
//  moment it was *saved* and appears nowhere in Places, even though the app
//  knew both the moment the shutter fired and the point on the trail the
//  walker was standing on.
//
//  Both halves of the fix are applied, and they are not redundant.
//  ``PHAssetChangeRequest/creationDate`` and `.location` are what the Photos
//  app indexes, so they are what makes the picture appear in the right day and
//  the right place — but they describe the *asset*, and an asset is a record
//  in somebody's library. Export that photo, AirDrop it, sync it to a
//  computer, and what travels is the file; a file whose bytes carry no
//  metadata arrives stripped all over again. So the bytes get it too.
//
//  What this deliberately does not do is re-encode. The obvious way to write
//  metadata — hand `CGImageDestinationAddImageFromSource` a merged properties
//  dictionary — reads as a copy and is not one: measured on a 24-pixel JPEG it
//  rewrote the scan from 252 bytes to 211 and moved decoded pixels by up to 6
//  levels, which is a second generation of lossy compression applied to every
//  photograph a walker chose to keep. `CGImageDestinationCopyImageSource` is
//  the API that genuinely copies, and it takes its metadata as a
//  `CGImageMetadata` rather than as image properties. That is the whole reason
//  this file is built out of `CGImageMetadataSetValueMatchingImageProperty`
//  instead of dictionaries: the dictionary form is easier to read and cannot
//  be used losslessly.
//

import CoreGraphics
import CoreLocation
import Foundation
import ImageIO
import os

/// Adds capture time and place to encoded image bytes, without touching the
/// pixels.
nonisolated enum PhotoMetadataStamp {
    private static let logger = Logger(
        subsystem: "OpenHikes",
        category: "PhotoMetadata"
    )

    /// `data` with EXIF capture times, and a GPS block when there is a place
    /// to record, or `nil` when the bytes are not an image ImageIO can rewrite.
    ///
    /// - Parameter coordinate: `nil` for a photograph the app has no position
    ///   for — location refused, or a hike with no route point to stand on.
    ///   The date is still written; an invented coordinate would be worse than
    ///   an absent one, since a wrong pin on a map reads as a fact.
    static func stamped(
        _ data: Data,
        capturedAt: Date,
        coordinate: CLLocationCoordinate2D?
    ) -> Data? {
        assertOffMainThread("Image metadata rewriting must stay off the main thread")
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source),
              CGImageSourceGetCount(source) > 0
        else {
            logger.error("Refused to stamp bytes that are not a readable image.")
            return nil
        }

        // swiftlint:disable:next legacy_objc_type
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            type,
            1,
            nil
        ) else { return nil }

        var failure: Unmanaged<CFError>?
        let copied = CGImageDestinationCopyImageSource(
            destination,
            source,
            [
                kCGImageDestinationMetadata: metadata(
                    mergedInto: source,
                    capturedAt: capturedAt,
                    coordinate: coordinate
                ),
                // Merge rather than replace: a photograph that arrived from
                // the library already carries metadata of its own, and this is
                // adding two facts to it rather than deciding what it says.
                kCGImageDestinationMergeMetadata: true,
            ] as CFDictionary,
            &failure
        )
        guard copied else {
            let error = failure?.takeRetainedValue()
            logger.error(
                "Could not stamp an image: \(error?.localizedDescription ?? "unknown", privacy: .public)"
            )
            return nil
        }
        return output as Data
    }

    // MARK: - The metadata

    /// The source's own metadata with the app's two facts written into it.
    ///
    /// Every value goes through `CGImageMetadataSetValueMatchingImageProperty`,
    /// which takes the familiar `kCGImageProperty…` constants and puts them in
    /// the XMP namespace ImageIO reconciles back into EXIF and GPS on read.
    /// Setting the XMP paths by hand would mean hard-coding that mapping here
    /// and getting to maintain it.
    private static func metadata(
        mergedInto source: CGImageSource,
        capturedAt: Date,
        coordinate: CLLocationCoordinate2D?
    ) -> CGMutableImageMetadata {
        let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
            .flatMap { CGImageMetadataCreateMutableCopy($0) }
            ?? CGImageMetadataCreateMutable()

        // EXIF timestamps are local wall-clock with no zone, which is what
        // every camera writes and what every reader expects.
        let local = timestamp(of: capturedAt, in: .current)
        set(kCGImagePropertyExifDateTimeOriginal, to: local, in: metadata)
        set(kCGImagePropertyExifDateTimeDigitized, to: local, in: metadata)

        guard let coordinate, CLLocationCoordinate2DIsValid(coordinate) else {
            return metadata
        }
        // Unsigned magnitudes with a hemisphere reference beside them, which
        // is the only form EXIF has for a coordinate.
        set(
            kCGImagePropertyGPSDictionary,
            kCGImagePropertyGPSLatitude,
            abs(coordinate.latitude) as CFNumber,
            in: metadata
        )
        set(
            kCGImagePropertyGPSDictionary,
            kCGImagePropertyGPSLatitudeRef,
            (coordinate.latitude < 0 ? "S" : "N") as CFString,
            in: metadata
        )
        set(
            kCGImagePropertyGPSDictionary,
            kCGImagePropertyGPSLongitude,
            abs(coordinate.longitude) as CFNumber,
            in: metadata
        )
        set(
            kCGImagePropertyGPSDictionary,
            kCGImagePropertyGPSLongitudeRef,
            (coordinate.longitude < 0 ? "W" : "E") as CFString,
            in: metadata
        )
        // The GPS block's own clock is UTC by specification, unlike the EXIF
        // one directly above it.
        let utc = timestamp(
            of: capturedAt,
            in: TimeZone(secondsFromGMT: 0) ?? .current
        )
        set(
            kCGImagePropertyGPSDictionary,
            kCGImagePropertyGPSDateStamp,
            utc.date as CFString,
            in: metadata
        )
        set(
            kCGImagePropertyGPSDictionary,
            kCGImagePropertyGPSTimeStamp,
            utc.time as CFString,
            in: metadata
        )
        return metadata
    }

    private static func set(
        _ property: CFString,
        to timestamp: (date: String, time: String),
        in metadata: CGMutableImageMetadata
    ) {
        set(
            kCGImagePropertyExifDictionary,
            property,
            "\(timestamp.date) \(timestamp.time)" as CFString,
            in: metadata
        )
    }

    /// A failure here is worth a line rather than an abandoned save: the
    /// picture is what the user asked for, and a photograph that reaches their
    /// library with one field missing is better than one that never arrives.
    private static func set(
        _ dictionary: CFString,
        _ property: CFString,
        _ value: CFTypeRef,
        in metadata: CGMutableImageMetadata
    ) {
        guard CGImageMetadataSetValueMatchingImageProperty(
            metadata,
            dictionary,
            property,
            value
        ) else {
            logger.error(
                "Could not set \(property as String, privacy: .public) on an image."
            )
            return
        }
    }

    /// `yyyy:MM:dd` and `HH:mm:ss`, built from components rather than through
    /// a `DateFormatter`.
    ///
    /// Not a style choice: a `DateFormatter` is not `Sendable`, so it could
    /// not be a `static let` here, and building one per photograph to produce
    /// a fixed-width numeric string is more machinery than the string is
    /// worth.
    private static func timestamp(
        of date: Date,
        in timeZone: TimeZone
    ) -> (date: String, time: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        return (
            String(
                format: "%04d:%02d:%02d",
                parts.year ?? 0,
                parts.month ?? 0,
                parts.day ?? 0
            ),
            String(
                format: "%02d:%02d:%02d",
                parts.hour ?? 0,
                parts.minute ?? 0,
                parts.second ?? 0
            )
        )
    }
}
