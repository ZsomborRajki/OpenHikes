#!/usr/bin/env swift
//
// Stamps photographs with a time and a place taken from a GPX track, so the
// app's own photo matching can find them.
//
// OpenHikes pins a photograph to the trail by asking when it was taken and
// comparing that against the route's own clock — see `LibraryPhotoMatch`. A
// photograph downloaded from a stock library carries neither the right time
// nor the right place, so on a simulator it is invisible to that scan: the
// feature works and has nothing to work on.
//
// This rewrites both, spacing the photographs evenly along the track, so a
// screenshot run reaches the real matcher with real input. Only the metadata
// is touched; the pixels are copied through untouched.
//
// Times are written in UTC with an explicit `OffsetTimeOriginal`, and the GPS
// timestamp is written too. Photos derives an asset's date from whichever it
// finds, and a bare `DateTimeOriginal` with no offset is read in the reader's
// own zone — which would put every photograph an hour or two off the walk,
// on a machine that is not in the Alps.
//
// Usage:
//   Scripts/stamp-hike-photos.swift <track.gpx> <out-dir> <photo> [photo...]
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

struct TrackPoint {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let time: Date
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

// MARK: - The track

/// The `<trkpt>`s of `url`, in file order, keeping only those that carry both
/// a height and a time — the two things a stamp is made of.
func readTrack(at url: URL) -> [TrackPoint] {
    guard let xml = try? String(contentsOf: url, encoding: .utf8) else {
        fail("could not read \(url.path)")
    }
    let pattern = #"<trkpt lat="([-\d.]+)" lon="([-\d.]+)"><ele>([-\d.]+)</ele><time>([^<]+)</time>"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        fail("the track pattern did not compile")
    }
    let stamps = ISO8601DateFormatter()
    let range = NSRange(xml.startIndex..., in: xml)
    return regex.matches(in: xml, range: range).compactMap { match in
        func group(_ index: Int) -> String {
            guard let r = Range(match.range(at: index), in: xml) else { return "" }
            return String(xml[r])
        }
        guard let lat = Double(group(1)),
              let lon = Double(group(2)),
              let ele = Double(group(3)),
              let time = stamps.date(from: group(4)) else { return nil }
        return TrackPoint(latitude: lat, longitude: lon, altitude: ele, time: time)
    }
}

/// `count` points spread across `track`, kept off both ends.
///
/// Off the ends deliberately: a photograph stamped at the very first or very
/// last fix sits on the trailhead marker in the map view and is the one pin
/// a reader cannot see.
func anchors(count: Int, along track: [TrackPoint]) -> [TrackPoint] {
    guard count > 0, !track.isEmpty else { return [] }
    guard track.count > count else { return Array(track.prefix(count)) }
    return (0..<count).map { step in
        let fraction = (Double(step) + 0.5) / Double(count)
        return track[min(track.count - 1, Int(fraction * Double(track.count)))]
    }
}

// MARK: - The stamp

func exifDates(_ date: Date) -> (stamp: String, day: String, clock: String) {
    var calendar = Calendar(identifier: .gregorian)
    guard let utc = TimeZone(identifier: "UTC") else { fail("no UTC zone") }
    calendar.timeZone = utc
    let parts = calendar.dateComponents(
        [.year, .month, .day, .hour, .minute, .second], from: date
    )
    let stamp = String(
        format: "%04d:%02d:%02d %02d:%02d:%02d",
        parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
        parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
    )
    let day = String(format: "%04d:%02d:%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    // A string rather than the three rationals the tag is specified as:
    // ImageIO accepts "HH:mm:ss" here and silently drops an array of numbers,
    // which is how this shipped once without a GPS timestamp on any photo.
    let clock = String(
        format: "%02d:%02d:%02d",
        parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
    )
    return (stamp, day, clock)
}

func stamp(photo source: URL, to destination: URL, with point: TrackPoint) -> Bool {
    guard let image = CGImageSourceCreateWithURL(source as CFURL, nil),
          let type = CGImageSourceGetType(image) else {
        FileHandle.standardError.write(Data("  skipped \(source.lastPathComponent): not an image\n".utf8))
        return false
    }
    var properties = (CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any]) ?? [:]
    let dates = exifDates(point.time)

    var exif = (properties[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
    exif[kCGImagePropertyExifDateTimeOriginal] = dates.stamp
    exif[kCGImagePropertyExifDateTimeDigitized] = dates.stamp
    exif[kCGImagePropertyExifOffsetTimeOriginal] = "+00:00"
    exif[kCGImagePropertyExifOffsetTimeDigitized] = "+00:00"
    properties[kCGImagePropertyExifDictionary] = exif

    var tiff = (properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
    tiff[kCGImagePropertyTIFFDateTime] = dates.stamp
    properties[kCGImagePropertyTIFFDictionary] = tiff

    properties[kCGImagePropertyGPSDictionary] = [
        kCGImagePropertyGPSLatitude: abs(point.latitude),
        kCGImagePropertyGPSLatitudeRef: point.latitude < 0 ? "S" : "N",
        kCGImagePropertyGPSLongitude: abs(point.longitude),
        kCGImagePropertyGPSLongitudeRef: point.longitude < 0 ? "W" : "E",
        kCGImagePropertyGPSAltitude: abs(point.altitude),
        kCGImagePropertyGPSAltitudeRef: point.altitude < 0 ? 1 : 0,
        kCGImagePropertyGPSDateStamp: dates.day,
        kCGImagePropertyGPSTimeStamp: dates.clock,
    ] as [CFString: Any]

    guard let out = CGImageDestinationCreateWithURL(destination as CFURL, type, 1, nil) else {
        fail("could not write \(destination.path)")
    }
    CGImageDestinationAddImageFromSource(out, image, 0, properties as CFDictionary)
    guard CGImageDestinationFinalize(out) else {
        fail("could not finalize \(destination.path)")
    }
    return true
}

// MARK: - Run

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 3 else {
    print("""
    Usage: Scripts/stamp-hike-photos.swift <track.gpx> <out-dir> <photo> [photo...]

    Rewrites each photo's EXIF time and GPS position to a point spread along
    the track, and writes the result into <out-dir>. Originals are untouched.
    """)
    exit(2)
}

let trackURL = URL(fileURLWithPath: arguments[0])
let outputDirectory = URL(fileURLWithPath: arguments[1])
let photos = arguments.dropFirst(2).map { URL(fileURLWithPath: $0) }

let track = readTrack(at: trackURL)
guard !track.isEmpty else { fail("no usable <trkpt> in \(trackURL.lastPathComponent)") }

try? FileManager.default.createDirectory(
    at: outputDirectory, withIntermediateDirectories: true
)

let points = anchors(count: photos.count, along: track)
let clock = DateFormatter()
clock.dateFormat = "HH:mm:ss"
clock.timeZone = TimeZone(identifier: "UTC")

print("\(track.count) track points, stamping \(photos.count) photo(s)")
var written = 0
for (index, photo) in photos.enumerated() {
    // `anchors` can only offer as many points as the track has, so a track
    // shorter than the photo list runs out — a trap rather than a message,
    // which is not what a script should do to somebody who pointed it at the
    // wrong `.gpx`.
    guard index < points.count else {
        fail("\(trackURL.lastPathComponent) has only \(track.count) usable point(s) "
            + "for \(photos.count) photo(s)")
    }
    let point = points[index]
    // Numbered so the photo library's own ordering matches the walk's.
    let name = String(format: "%02d-%@", index + 1, photo.lastPathComponent)
    let destination = outputDirectory.appendingPathComponent(name)
    guard stamp(photo: photo, to: destination, with: point) else { continue }
    written += 1
    print(String(
        format: "  %@  %.5f, %.5f  %.0f m  %@Z",
        name, point.latitude, point.longitude, point.altitude,
        clock.string(from: point.time)
    ))
}
print("\(written) photo(s) written to \(outputDirectory.path)")
