//
//  PhotoMetadataStamp.swift
//  OpenHikes
//
//  Writing what the app knows about a photograph into the photograph.
//
//  Two paths need this. The first is the opt-in copy that leaves the app —
//  see ``PhotoLibraryWriter``. A photo taken in OpenHikes is encoded from a
//  `UIImage`, which is pixels and nothing else: no EXIF, no `DateTimeOriginal`,
//  no GPS. Filed into the photo library as-is it lands in Recents under the
//  moment it was *saved* and appears nowhere in Places, even though the app
//  knew both the moment the shutter fired and the point on the trail the
//  hiker was standing on.
//
//  Both halves of the fix are applied, and they are not redundant.
//  ``PHAssetChangeRequest/creationDate`` and `.location` are what the Photos
//  app indexes, so they are what makes the picture appear in the right day and
//  the right place — but they describe the *asset*, and an asset is a record
//  in somebody's library. Export that photo, AirDrop it, sync it to a
//  computer, and what travels is the file; a file whose bytes carry no
//  metadata arrives stripped all over again. So the bytes get it too.
//
//  The second is a copy of somebody else's photograph leaving the app: a
//  Wikimedia Commons picture saved with a trail, shared on its own or packed
//  into an archive. Its credit — author, licence, source page — was kept on
//  the photo's row rather than in its bytes, and a file that goes somewhere
//  without it is a file whose licence has not been honoured. So the copy that
//  leaves is rewritten with it; see ``credited(_:with:)``.
//
//  What this deliberately does not do is re-encode. The obvious way to write
//  metadata — hand `CGImageDestinationAddImageFromSource` a merged properties
//  dictionary — reads as a copy and is not one: measured on a 24-pixel JPEG it
//  rewrote the scan from 252 bytes to 211 and moved decoded pixels by up to 6
//  levels, which is a second generation of lossy compression applied to every
//  photograph a hiker chose to keep. `CGImageDestinationCopyImageSource` is
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
import OpenHikesData
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
        copy(data) { source in
            metadata(mergedInto: source, capturedAt: capturedAt, coordinate: coordinate)
        }
    }

    /// `data` carrying the credit a Commons copy is owed, or `nil` when the
    /// bytes are not an image ImageIO can rewrite or the credit could not be
    /// written into them — a copy that would leave without it.
    ///
    /// Written as the copyright notice — TIFF `Copyright`, which is
    /// `dc:rights` in XMP — because that is the one field every container the
    /// store holds keeps and every viewer shows: measured, JPEG, PNG and HEIC
    /// all read it back, where a PNG drops IPTC entirely. The notice carries
    /// all three things the licence asks for, so that field alone is enough.
    /// The author goes into `dc:creator` as well, the place a reader looks
    /// for who took a picture, and the source page and licence into their own
    /// IPTC and XMP Rights fields for software that reads those.
    ///
    /// Overwrites whatever the photograph already said in those fields. The
    /// Commons file page is the authority on its licence, and a camera's
    /// *all rights reserved* left in the copyright notice would contradict it.
    static func credited(_ data: Data, with credit: CommonsPhotoCredit) -> Data? {
        let notice = credit.notice
        var complete = true
        // HEIC's merge can keep the old EXIF copyright ahead of the new XMP
        // rights. Start with all the source's tags, then replace that metadata.
        let rewritten = copy(data, mergingMetadata: false) { source in
            let metadata = mutableMetadata(of: source)
            complete = credit.author.map { setCreator($0, in: metadata) } ?? true
            // An existing dc:rights is an alternate-text array. Assigning a
            // string to the whole property corrupts that array and can crash
            // ImageIO's HEIC writer; update its default-language entry instead.
            complete = complete && CGImageMetadataSetValueWithPath(
                metadata,
                nil,
                "\(kCGImageMetadataPrefixDublinCore):rights[x-default]" as CFString,
                notice as CFString
            )
            complete = complete && setting(
                kCGImagePropertyIPTCDictionary,
                kCGImagePropertyIPTCSource,
                credit.licence.sourceURL.absoluteString as CFString,
                in: metadata
            )
            if let url = credit.licence.url {
                complete = complete && CGImageMetadataSetValueWithPath(
                    metadata,
                    nil,
                    "\(kCGImageMetadataPrefixXMPRights):WebStatement" as CFString,
                    url.absoluteString as CFString
                )
            }
            return metadata
        }
        // A successful metadata setter and copy do not prove the container
        // kept the notice: PNG can silently retain its old copyright instead.
        guard complete, let rewritten, copyright(of: rewritten) == notice else {
            logger.error("Could not write a Commons credit into an image.")
            return nil
        }
        return rewritten
    }

    private static func copyright(of data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        else { return nil }
        return tiff[kCGImagePropertyTIFFCopyright] as? String
    }

    /// `data` copied with `metadata(source)` merged into it, without touching
    /// the pixels — see this file's header for why it is this API.
    private static func copy(
        _ data: Data,
        mergingMetadata: Bool = true,
        adding metadata: (CGImageSource) -> CGMutableImageMetadata
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
                kCGImageDestinationMetadata: metadata(source),
                // Capture stamps merge; credits replace a full copy of the
                // metadata so an old copyright cannot win the merge.
                kCGImageDestinationMergeMetadata: mergingMetadata,
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
        let metadata = mutableMetadata(of: source)

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
        _ = setting(dictionary, property, value, in: metadata)
    }

    /// ``set(_:_:_:in:)`` for a caller that has to know: a credit missing one
    /// of its fields is not a credit, where a date missing is only a date.
    private static func setting(
        _ dictionary: CFString,
        _ property: CFString,
        _ value: CFTypeRef,
        in metadata: CGMutableImageMetadata
    ) -> Bool {
        guard CGImageMetadataSetValueMatchingImageProperty(
            metadata,
            dictionary,
            property,
            value
        ) else {
            logger.error(
                "Could not set \(property as String, privacy: .public) on an image."
            )
            return false
        }
        return true
    }

    /// The source's own metadata, as a copy this can write into.
    private static func mutableMetadata(of source: CGImageSource) -> CGMutableImageMetadata {
        CGImageSourceCopyMetadataAtIndex(source, 0, nil)
            .flatMap { CGImageMetadataCreateMutableCopy($0) }
            ?? CGImageMetadataCreateMutable()
    }

    /// `dc:creator`, which XMP keeps as an ordered list of names.
    ///
    /// Set as a tag rather than through TIFF `Artist`: measured, the image
    /// property form writes a plain string where XMP wants the list, and no
    /// container reads it back. The list form is what ImageIO reconciles into
    /// the IPTC byline on read.
    private static func setCreator(_ author: String, in metadata: CGMutableImageMetadata) -> Bool {
        guard let name = CGImageMetadataTagCreate(
            kCGImageMetadataNamespaceDublinCore,
            kCGImageMetadataPrefixDublinCore,
            "creator" as CFString,
            .string,
            author as CFString
        ), let list = CGImageMetadataTagCreate(
            kCGImageMetadataNamespaceDublinCore,
            kCGImageMetadataPrefixDublinCore,
            "creator" as CFString,
            .arrayOrdered,
            [name] as CFArray
        ) else { return false }
        return CGImageMetadataSetTagWithPath(
            metadata,
            nil,
            "\(kCGImageMetadataPrefixDublinCore):creator" as CFString,
            list
        )
    }

    /// `yyyy:MM:dd` and `HH:mm:ss`, the two halves EXIF keeps a timestamp in.
    ///
    /// A comment here used to say this was built from components because
    /// `DateFormatter` is not `Sendable` and so could not be a `static let`.
    /// The SDK says otherwise — `NSDateFormatter.h` declares
    /// `NS_SWIFT_SENDABLE` — so the reason was stale, and the replacement is
    /// not a formatter anyway: `Date.VerbatimFormatStyle` is the value-type
    /// form Foundation offers for exactly this, a fixed non-localized format.
    ///
    /// Verbatim rather than `Date.FormatStyle`, and POSIX rather than the
    /// hiker's locale, because this string is read by other software: a
    /// localized rendering would write Arabic-Indic digits into
    /// `DateTimeOriginal` on an Arabic device, which no reader of EXIF
    /// expects.
    private static func timestamp(
        of date: Date,
        in timeZone: TimeZone
    ) -> (date: String, time: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        func rendered(_ format: Date.FormatString) -> String {
            date.formatted(
                Date.VerbatimFormatStyle(
                    format: format,
                    locale: Locale(identifier: "en_US_POSIX"),
                    timeZone: timeZone,
                    calendar: calendar
                )
            )
        }
        return (
            rendered("\(year: .padded(4)):\(month: .twoDigits):\(day: .twoDigits)"),
            rendered("""
            \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\
            \(minute: .twoDigits):\(second: .twoDigits)
            """)
        )
    }
}
