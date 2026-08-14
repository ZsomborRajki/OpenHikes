//
//  GPXExport.swift
//  OpenHikes
//
//  Writes a hike back out as GPX 1.1 — the other half of ``GPXImport``, so a
//  route recorded here can leave through the share sheet and be opened by
//  whatever else the walker uses.
//

import CoreTransferable
import Foundation
import UniformTypeIdentifiers

nonisolated enum GPXExport {
    /// Everything the serializer needs, lifted off the SwiftData model.
    ///
    /// A `Hike` is a `@Model` — a main-actor reference type tied to its
    /// context, so it can't be handed to the exporter the share sheet calls on
    /// whatever executor it likes. This is the `Sendable` copy that crosses.
    /// `name` is a `var` because the payload is snapshotted with the route
    /// while the title can still be renamed underneath it.
    struct Track: Sendable, Equatable {
        var name: String
        var trackDescription: String?
        var author: String?
        var keywords: String?
        var date: Date
        var route: [RouteCoordinate]
    }

    /// Named in the file so a track that turns up in another app says where it
    /// came from.
    static let creator = "OpenHikes"

    private static let namespace = "http://www.topografix.com/GPX/1/1"
    private static let schemaNamespace = "http://www.w3.org/2001/XMLSchema-instance"
    private static let schemaLocation =
        "http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd"

    /// Seven decimals is ~1.1 cm at the equator — finer than any consumer GPS
    /// resolves — and fixed-point, which matters: `Double`'s own description
    /// reaches for scientific notation near the prime meridian or the equator,
    /// and `xsd:decimal` has no way to express it.
    private static let coordinateFormat = "%.7f"
    /// Centimetres. Barometric elevation carries fractions worth keeping, but
    /// not more than this.
    private static let elevationFormat = "%.2f"

    /// Fractional seconds because a recording samples faster than 1 Hz and its
    /// fixes don't land on whole seconds; ``GPXImport`` parses them back
    /// preferentially, so a route exported and re-imported keeps its timing
    /// rather than being quietly rounded.
    private static let timeStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// Local time, not UTC: the file name should say the day the walker
    /// remembers walking, which is the day the rest of the UI shows.
    private static let fileDateStyle = Date.ISO8601FormatStyle(
        dateSeparator: .dash,
        timeZone: .autoupdatingCurrent
    )
    .year()
    .month()
    .day()

    /// Rough per-point cost of the markup below, so a long route doesn't
    /// re-grow the string dozens of times on its way to a few megabytes.
    private static let bytesPerPoint = 96
    private static let preambleBytes = 512

    /// The GPX 1.1 document for `track`.
    ///
    /// Deliberately free of the off-main assertion that
    /// ``writeTemporaryFile(for:)`` carries, mirroring ``GPXImport/load(from:)``:
    /// this is the pure function tests call directly, and the `@concurrent`
    /// entry point below is what promises the app never runs it on the main
    /// thread.
    static func xml(for track: Track) -> String {
        var xml = ""
        xml.reserveCapacity(preambleBytes + track.route.count * bytesPerPoint)
        xml += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<gpx version=\"1.1\" creator=\"\(escaped(creator))\""
        xml += " xmlns=\"\(namespace)\""
        xml += " xmlns:xsi=\"\(schemaNamespace)\""
        xml += " xsi:schemaLocation=\"\(schemaLocation)\">\n"
        appendMetadata(of: track, to: &xml)
        appendTrack(track, to: &xml)
        xml += "</gpx>\n"
        return xml
    }

    /// The same document as bytes, which is what goes to disk.
    static func data(for track: Track) -> Data {
        Data(xml(for: track).utf8)
    }
}

// MARK: - Document body

nonisolated private extension GPXExport {
    /// GPX 1.1 fixes the order of `metadata`'s children — name, desc, author,
    /// copyright, link, time, keywords — and a schema-validating reader
    /// rejects the file if they arrive in any other. Same for `trk` below.
    static func appendMetadata(of track: Track, to xml: inout String) {
        xml += "  <metadata>\n"
        xml += "    <name>\(escaped(track.name))</name>\n"
        if let trackDescription = track.trackDescription {
            xml += "    <desc>\(escaped(trackDescription))</desc>\n"
        }
        if let author = track.author {
            xml += "    <author>\n"
            xml += "      <name>\(escaped(author))</name>\n"
            xml += "    </author>\n"
        }
        xml += "    <time>\(timeStyle.format(track.date))</time>\n"
        if let keywords = track.keywords {
            xml += "    <keywords>\(escaped(keywords))</keywords>\n"
        }
        xml += "  </metadata>\n"
    }

    static func appendTrack(_ track: Track, to xml: inout String) {
        xml += "  <trk>\n"
        xml += "    <name>\(escaped(track.name))</name>\n"
        if let trackDescription = track.trackDescription {
            xml += "    <desc>\(escaped(trackDescription))</desc>\n"
        }
        xml += "    <trkseg>\n"
        for point in track.route {
            appendPoint(point, to: &xml)
        }
        xml += "    </trkseg>\n"
        xml += "  </trk>\n"
    }

    /// A point with neither elevation nor a timestamp closes on its own tag —
    /// on a route imported from a planner that is every one of them, and the
    /// pair of tags it saves is most of the file.
    static func appendPoint(_ point: RouteCoordinate, to xml: inout String) {
        let latitude = String(format: coordinateFormat, point.latitude)
        let longitude = String(format: coordinateFormat, point.longitude)
        let attributes = "lat=\"\(latitude)\" lon=\"\(longitude)\""
        guard point.elevation != nil || point.timestamp != nil else {
            xml += "      <trkpt \(attributes)/>\n"
            return
        }
        xml += "      <trkpt \(attributes)>\n"
        if let elevation = point.elevation {
            xml += "        <ele>\(String(format: elevationFormat, elevation))</ele>\n"
        }
        if let timestamp = point.timestamp {
            xml += "        <time>\(timeStyle.format(timestamp))</time>\n"
        }
        xml += "      </trkpt>\n"
    }
}

// MARK: - Escaping

nonisolated extension GPXExport {
    /// Tab, newline and carriage return are the only control characters XML 1.0
    /// can carry — not even as numeric references. A name imported from
    /// someone else's file can contain the others, so they're dropped rather
    /// than written into a document no parser will read back.
    private static let literalControlScalars: Set<UInt32> = [0x9, 0xA, 0xD]
    private static let firstTextScalar: UInt32 = 0x20
    /// U+FFFE and U+FFFF, the two permanent non-characters at the end of the
    /// BMP, which XML's `Char` production also excludes. Nothing else needs
    /// testing: a Swift `Unicode.Scalar` can't hold a surrogate or a value
    /// past U+10FFFF, which is the rest of what that production rules out.
    private static let bmpNonCharacter: UInt32 = 0xFFFE
    private static let bmpSentinel: UInt32 = 0xFFFF

    /// Escapes text for either element content or an attribute value.
    ///
    /// One function for both because the metadata below is user-supplied — a
    /// hike renamed "Ben & Jerry's <Ridge>" has to survive as text instead of
    /// reopening the document's markup.
    static func escaped(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&apos;"
            default:
                guard isRepresentable(scalar) else { continue }
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    private static func isRepresentable(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value < firstTextScalar {
            return literalControlScalars.contains(scalar.value)
        }
        return scalar.value != bmpNonCharacter && scalar.value != bmpSentinel
    }
}

// MARK: - File naming

nonisolated extension GPXExport {
    /// Used when a hike's name is empty, or is nothing but punctuation a file
    /// system won't take.
    private static let fallbackFileStem = "Hike"
    /// Well inside every file system's limit, and long enough that a trimmed
    /// name is still recognisable in a Files folder.
    private static let maximumFileStemLength = 64
    /// Path separators and the characters Windows and iCloud Drive reject,
    /// plus anything unprintable.
    private static let reservedFileNameCharacters = CharacterSet(charactersIn: #"/\:?%*|"<>"#)
        .union(.controlCharacters)
        .union(.illegalCharacters)

    /// The name the share sheet offers, e.g. `Thumsee Loop-2026-06-12.gpx`.
    ///
    /// The date is part of it because two walks of the same trail otherwise
    /// export to the same file, and whichever app receives them silently
    /// overwrites or suffixes.
    static func fileName(for track: Track) -> String {
        "\(fileStem(for: track.name))-\(fileDateStyle.format(track.date)).gpx"
    }

    /// Reserved characters become hyphens rather than disappearing, so two
    /// hikes whose names differ only in punctuation still export to different
    /// files. A leading dot is dropped along with the trimming: it would hide
    /// the file on every Unix-derived system the share reaches.
    private static func fileStem(for name: String) -> String {
        let replaced = name.unicodeScalars.map { scalar in
            reservedFileNameCharacters.contains(scalar) ? "-" : Character(scalar)
        }
        let trimmed = String(replaced)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        guard !trimmed.isEmpty else { return fallbackFileStem }
        return String(trimmed.prefix(maximumFileStemLength))
    }
}

// MARK: - Staging

nonisolated extension GPXExport {
    /// Where a share writes the file it hands over.
    ///
    /// A directory of the app's own inside `tmp`, so
    /// ``purgeStagedExports(in:before:)`` can sweep it without having to tell
    /// exports apart from whatever else the system leaves there.
    static var stagingDirectory: URL {
        FileManager.default.temporaryDirectory
            .appending(path: "GPXExports", directoryHint: .isDirectory)
    }

    /// How long a staged file is left alone before a later share removes it.
    ///
    /// The share sheet copies the file during the transfer and is done with it
    /// seconds later, so this is only slack for a destination that takes its
    /// time; the purge exists so `tmp` doesn't end up holding a copy of every
    /// hike ever exported.
    private static let stagedExportLifetime: TimeInterval = 3600

    /// Writes the document to a file and returns its URL.
    ///
    /// The file is the point. A share sheet builds its "Copy to <App>" row by
    /// matching a *file* against the document types each installed app
    /// declares it opens, so a hike offered only as bytes reaches Files, Mail
    /// and AirDrop but never appears to the GPX apps this export exists for.
    /// The file also carries the name for certain: a suggested one is a hint
    /// the receiver may ignore, a last path component is not.
    ///
    /// Each export gets a directory of its own, so the name can be exactly
    /// ``fileName(for:)`` rather than the `-1` suffix a shared directory would
    /// force onto the second export of the same hike.
    ///
    /// `@concurrent` rather than a detached task, as in ``GPXImport``: the
    /// work stays part of the sharing task, so abandoning the share sheet
    /// cancels it, and a multi-day route's few megabytes of XML are never
    /// built — or written — on the thread drawing the sheet.
    @concurrent
    static func writeTemporaryFile(for track: Track) async throws -> URL {
        assertOffMainThread("GPX serialization must stay off the main thread")
        // Spanning the write as well as the markup, since what a share costs
        // the walker is both of them together.
        return try RenderSignpost.interval("GPXExported") {
            let directory = stagingDirectory
            purgeStagedExports(in: directory, before: .now - stagedExportLifetime)
            let staged = directory.appending(
                path: UUID().uuidString,
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: staged,
                withIntermediateDirectories: true
            )
            let url = staged.appending(
                path: fileName(for: track),
                directoryHint: .notDirectory
            )
            try data(for: track).write(to: url, options: .atomic)
            return url
        }
    }

    /// Removes exports staged before `cutoff`.
    ///
    /// Dated rather than emptied wholesale: a file still being copied out
    /// belongs to a share that is still happening. Silent about failure for
    /// the same reason ``GPXInbox/discardCopy(at:)`` is — a staged file that
    /// outlives its share is housekeeping, not something to fail a share over.
    static func purgeStagedExports(in directory: URL, before cutoff: Date) {
        let manager = FileManager.default
        let staged = (try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for url in staged {
            let modified = try? url
                .resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? manager.removeItem(at: url)
        }
    }
}

// MARK: - Sharing

/// The share sheet's view of a hike: a GPX file, written on demand.
///
/// The payload is a ``GPXExport/Track`` rather than the `Hike` itself — see
/// that type for why — and nothing is serialized until the walker actually
/// picks a destination, so opening the share sheet costs nothing.
nonisolated struct HikeGPXFile: Transferable, Sendable {
    let track: GPXExport.Track

    /// The file and nothing beside it.
    ///
    /// A second `DataRepresentation` of the same type looks like a harmless
    /// convenience for the destinations that only want bytes, and isn't:
    /// `NSItemProvider` takes both, and `loadItem` — the path a share sheet
    /// takes to fill its "Copy to <App>" row — answers with whichever was
    /// registered last, whatever the preference order here says. Offering the
    /// bytes at all is enough to put the loose-bytes behaviour back. Nothing
    /// is lost by leaving them out: a receiver that wants bytes reads them out
    /// of the file.
    ///
    /// `SentTransferredFile` defaults to copying rather than lending the
    /// original, which is what lets the staged file be swept on a timer
    /// instead of tracked until the receiver is finished with it.
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .gpx) { file in
            SentTransferredFile(try await GPXExport.writeTemporaryFile(for: file.track))
        }
        .suggestedFileName { GPXExport.fileName(for: $0.track) }
    }
}

nonisolated extension UTType {
    /// GPX has no system-declared type; this resolves because the app imports
    /// topografix's in its Info.plist — see ``GPXDocumentTypeTests``.
    ///
    /// Computed rather than stored, as `importedTypeWithIdentifier:`
    /// documents: another process installed later can declare the same
    /// extension and supersede this one, which a value cached for the lifetime
    /// of the process would never notice.
    static var gpx: UTType {
        UTType(importedAs: "com.topografix.gpx", conformingTo: .xml)
    }
}

@MainActor
extension GPXExport.Track {
    /// Reads `hike` where its SwiftData context lives, and hands on the
    /// `Sendable` copy everything downstream uses.
    init(hike: Hike) {
        self.init(
            name: hike.displayTitle,
            trackDescription: hike.trackDescription,
            author: hike.author,
            keywords: hike.keywords,
            date: hike.date,
            route: hike.route
        )
    }
}
