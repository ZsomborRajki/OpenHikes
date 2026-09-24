//
//  GPXExport.swift
//  OpenHikes
//
//  Writes a hike back out as GPX 1.1 — the other half of ``GPXImport``, so a
//  route recorded here can leave through the share sheet and be opened by
//  whatever else the hiker uses.
//

import CoreLocation
import CoreTransferable
import Foundation
import OpenHikesData
import UniformTypeIdentifiers

nonisolated enum GPXExport {
    /// Everything the serializer needs, lifted off the SwiftData model.
    ///
    /// A `Hike` is a `@Model` — a main-actor reference type tied to its
    /// context, so it can't be handed to the exporter the share sheet calls on
    /// whatever executor it likes. This is the `Sendable` copy that crosses.
    struct Track: Sendable, Equatable {
        var name: String
        var trackDescription: String?
        var author: String?
        var keywords: String?
        var date: Date
        var route: [RouteCoordinate]
        /// Where the hiker photographed something, in the order the hike
        /// carries them. Empty for a hike with no pictures, and for one whose
        /// pictures are all unanchored — see ``Photograph``.
        var photographs: [Photograph] = []
        /// The places marked along the trail, in along-route order. Empty for
        /// a hike with none, which is every hike this app made before the
        /// trail maker existed. See ``TrailPlace``.
        var places: [TrailPlace] = []
    }

    /// One photograph's place and moment, which is all of it that GPX can
    /// carry.
    ///
    /// A value of its own rather than a `HikePhoto`, for the reason ``Track``
    /// is not a `Hike`: this crosses to whatever executor the share sheet
    /// serializes on, and `HikePhoto` belongs to a main-actor model graph.
    ///
    /// **The file name is present only when the file is.** GPX 1.1 allows
    /// `<link href="…">` on a waypoint, and a relative `href` is a promise
    /// about something beside the `.gpx` — so it is written by the archive
    /// export, which puts the pixels there, and left out of the plain `.gpx`
    /// export, which does not. ``linkHref`` carrying `nil` is that second
    /// case, and it is the default because the bare file is still what most
    /// shares hand over: the waypoint says *a photo was taken here* and
    /// nothing further. See ``HikeArchive`` for the other end.
    struct Photograph: Sendable, Equatable {
        var coordinate: RouteCoordinate
        var capturedAt: Date
        /// Where the photograph is, relative to the `.gpx` — e.g.
        /// `Photos/photo-1.jpeg`. `nil` when it is nowhere the reader can
        /// reach.
        var linkHref: String?

        init(coordinate: RouteCoordinate, capturedAt: Date, linkHref: String? = nil) {
            self.coordinate = coordinate
            self.capturedAt = capturedAt
            self.linkHref = linkHref
        }
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
    ///
    /// A `FormatStyle` rather than `String(format: "%.7f", …)`: this runs
    /// three times per track point, and the C-variadic path builds an
    /// `NSString` and re-parses the format string on each one. The style is a
    /// `Sendable` value resolved once here.
    ///
    /// `.grouping(.never)` and the POSIX locale are load-bearing, not
    /// decoration — GPX is `xsd:decimal`, so a thousands separator or a comma
    /// decimal mark from the user's locale would make the file invalid. This
    /// is the one behaviour `String(format:)` gave for free, by never
    /// consulting a locale at all.
    private static let coordinateStyle = FloatingPointFormatStyle<Double>()
        .precision(.fractionLength(7))
        .grouping(.never)
        .locale(Locale(identifier: "en_US_POSIX"))
    /// Centimetres. Barometric elevation carries fractions worth keeping, but
    /// not more than this.
    private static let elevationStyle = FloatingPointFormatStyle<Double>()
        .precision(.fractionLength(2))
        .grouping(.never)
        .locale(Locale(identifier: "en_US_POSIX"))

    /// Fractional seconds because a recording samples faster than 1 Hz and its
    /// fixes don't land on whole seconds; ``GPXImport`` parses them back
    /// preferentially, so a route exported and re-imported keeps its timing
    /// rather than being quietly rounded.
    private static let timeStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// Local time, not UTC: the file name should say the day the hiker
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
    /// Rough cost of one `<wpt>`, budgeted with the points above so a hike
    /// with a full gallery does not re-grow the string on its way past them.
    private static let bytesPerPhotograph = 160

    /// What a photo waypoint is called in a reader that lists it.
    ///
    /// Not the hike's name and not the file's: the hike's is already on the
    /// track and repeating it would give every waypoint the same label, while
    /// the file's names something the export does not carry.
    static let photographName = "Photo"
    /// `<sym>` is a hint to the reader's own symbol table rather than a
    /// drawing, and this is the name readers conventionally map to a camera.
    static let photographSymbol = "Photo"

    /// Rough cost of one place's `<wpt>`, which carries a note the
    /// photographs' do not.
    private static let bytesPerPlace = 220

    /// The GPX 1.1 document for `track`.
    ///
    /// Deliberately free of the off-main assertion that
    /// ``writeTemporaryFile(for:)`` carries, mirroring ``GPXImport/load(from:)``:
    /// this is the pure function tests call directly, and the `@concurrent`
    /// entry point below is what promises the app never runs it on the main
    /// thread.
    static func xml(for track: Track) -> String {
        var xml = ""
        xml.reserveCapacity(
            preambleBytes
                + track.route.count * bytesPerPoint
                + track.photographs.count * bytesPerPhotograph
                + track.places.count * bytesPerPlace
        )
        xml += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<gpx version=\"1.1\" creator=\"\(escaped(creator))\""
        xml += " xmlns=\"\(namespace)\""
        xml += " xmlns:xsi=\"\(schemaNamespace)\""
        xml += " xsi:schemaLocation=\"\(schemaLocation)\">\n"
        appendMetadata(of: track, to: &xml)
        appendPhotographs(track, to: &xml)
        appendPlaces(track, to: &xml)
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

    /// A `<wpt>` for every photograph that has a place on the trail.
    ///
    /// **Between `<metadata>` and `<trk>`, and that is the schema rather than
    /// a preference.** GPX 1.1 fixes the order of `<gpx>`'s children —
    /// metadata, then `wpt*`, then `rte*`, then `trk*` — exactly as it fixes
    /// the order of `<metadata>`'s own, and a schema-validating reader refuses
    /// a file that puts waypoints after the track.
    ///
    /// **An unanchored photograph is deliberately not written.** `lat` and
    /// `lon` are required attributes, and ``HikePhoto``'s coordinate is
    /// optional on purpose — see that type, whose own note says an unanchored
    /// photo "is still a photo of the walk; it simply has no place to point at
    /// on the map". There is no honest `<wpt>` for one. Filtered in
    /// ``Track/init(hike:)`` rather than here, so what this receives is
    /// already the set that can be written.
    ///
    /// `<name>` rather than the photograph's own file name, because the name
    /// labels the waypoint in a reader's list and every photograph should read
    /// the same there. Where the file *is* alongside — an archive export —
    /// ``Photograph/linkHref`` names it, and `<link>` is the element for
    /// exactly that. `<sym>` is the conventional way to say what kind of
    /// waypoint this is, and *Photo* is the name every reader that has a
    /// symbol table for it already uses.
    ///
    /// `<link>` sits between `<name>` and `<sym>` because GPX 1.1 fixes
    /// `<wpt>`'s children too — name, cmt, desc, src, link, sym, type — and a
    /// schema-validating reader refuses the file over the wrong order just as
    /// readily as it refuses waypoints after the track.
    static func appendPhotographs(_ track: Track, to xml: inout String) {
        for photograph in track.photographs {
            let latitude = photograph.coordinate.latitude.formatted(coordinateStyle)
            let longitude = photograph.coordinate.longitude.formatted(coordinateStyle)
            xml += "  <wpt lat=\"\(latitude)\" lon=\"\(longitude)\">\n"
            // The same guard ``appendPoint(_:to:)`` applies and for the same
            // reason: `inf` and `nan` are not `xsd:decimal`, and a strict
            // reader refuses the whole file over one of them.
            if let elevation = photograph.coordinate.elevation, elevation.isFinite {
                xml += "    <ele>\(elevation.formatted(elevationStyle))</ele>\n"
            }
            // GPX 1.1 fixes `<wpt>`'s children too, and `<time>` comes before
            // `<ele>`'s successors but after `<ele>` itself.
            xml += "    <time>\(timeStyle.format(photograph.capturedAt))</time>\n"
            xml += "    <name>\(escaped(photographName))</name>\n"
            if let href = photograph.linkHref {
                xml += "    <link href=\"\(escaped(href))\"/>\n"
            }
            xml += "    <sym>\(escaped(photographSymbol))</sym>\n"
            xml += "  </wpt>\n"
        }
    }

    /// A `<wpt>` for every marked place.
    ///
    /// Beside the photographs and before the track, because GPX 1.1 fixes the
    /// order of `<gpx>`'s children — metadata, then `wpt*`, then `rte*`, then
    /// `trk*` — and a schema-validating reader refuses a file that puts
    /// waypoints after the track. The two kinds of waypoint are told apart by
    /// `<sym>`, which is exactly what `<sym>` is for: *Photo* for a picture,
    /// and the symbol's own word for a place. See
    /// ``GPXImport/place(_:)`` for the other end.
    ///
    /// **A place always has a `<name>`, even one the hiker never named.**
    /// ``TrailPlace/displayName`` is what is written, so a `<wpt>` that turns
    /// up in somebody else's reader is labelled *Spring* rather than being a
    /// nameless dot — unnamed is the normal case for the places this feature
    /// is about, and a file full of blanks would lose the only thing they had.
    ///
    /// No `<time>`, unlike a photograph's. A photo waypoint carries the moment
    /// the shutter fired, which is a fact about the walk; when a place was
    /// *marked* is a fact about the planning, and stamping it would tell a
    /// reader that a hiker stood at that spring on the evening they drew the
    /// route from their sofa.
    static func appendPlaces(_ track: Track, to xml: inout String) {
        for place in track.places {
            let latitude = place.latitude.formatted(coordinateStyle)
            let longitude = place.longitude.formatted(coordinateStyle)
            xml += "  <wpt lat=\"\(latitude)\" lon=\"\(longitude)\">\n"
            xml += "    <name>\(escaped(place.displayName))</name>\n"
            // `<desc>` rather than `<cmt>`: a comment is about the waypoint
            // and a description is about the place, and a note here is the
            // hiker saying what is there. Both are allowed and readers show
            // the description.
            if !place.note.isEmpty {
                xml += "    <desc>\(escaped(place.note))</desc>\n"
            }
            // The OpenStreetMap element a place came from, as its page — the
            // one field GPX has for *more about this is over there*, and what
            // lets a round trip through a file keep the place OpenStreetMap's
            // rather than turning it into the hiker's own. After `<desc>` and
            // before `<sym>`, which is the schema's order for `wpt`.
            if let url = place.osm?.url {
                xml += "    <link href=\"\(escaped(url.absoluteString))\"/>\n"
            }
            // Only a place that claims to be something. An unstated symbol is
            // a real answer — see ``TrailPlace`` — and `<sym></sym>` would be
            // a claim that it is a symbol nobody has.
            if let symbol = place.symbol {
                xml += "    <sym>\(escaped(symbol.rawValue))</sym>\n"
            }
            xml += "  </wpt>\n"
        }
    }

    static func appendTrack(_ track: Track, to xml: inout String) {
        xml += "  <trk>\n"
        xml += "    <name>\(escaped(track.name))</name>\n"
        if let trackDescription = track.trackDescription {
            xml += "    <desc>\(escaped(trackDescription))</desc>\n"
        }
        xml += "    <trkseg>\n"
        for (index, point) in track.route.enumerated() {
            // GPX 1.1's own way of saying the recording stopped and started
            // again, and the reason a pause is worth persisting at all: it is
            // the one thing about a walk this format can carry that a single
            // flat list of points cannot. ``GPXImport`` reads it straight back
            // as a pause, so a hike exported and re-imported keeps its breaks
            // rather than flattening into one uninterrupted line.
            //
            // Never before the first point: a boundary describes the leg
            // arriving at a point, so opening a segment there would write an
            // empty one. A route with no pauses writes exactly the single
            // segment this always wrote.
            if index > 0, point.isPauseBoundary {
                xml += "    </trkseg>\n"
                xml += "    <trkseg>\n"
            }
            appendPoint(point, to: &xml)
        }
        xml += "    </trkseg>\n"
        xml += "  </trk>\n"
    }

    /// A point with neither elevation nor a timestamp closes on its own tag —
    /// on a route imported from a planner that is every one of them, and the
    /// pair of tags it saves is most of the file.
    static func appendPoint(_ point: RouteCoordinate, to xml: inout String) {
        let latitude = point.latitude.formatted(coordinateStyle)
        let longitude = point.longitude.formatted(coordinateStyle)
        let attributes = "lat=\"\(latitude)\" lon=\"\(longitude)\""
        // A non-finite height is not a height, and writing one is worse than
        // dropping it: `inf` and `nan` are not `xsd:decimal`, so a strict
        // reader refuses the whole file, and this app's own importer drops the
        // value silently on the way back in — `GPXImport` and
        // `CommunityRoutePayload` both guard `isFinite` at the door. This is
        // the same guard, one step earlier, on the way out. Hikes stored
        // before those guards existed, and any synced from a device that had
        // not got them, are the population it is for.
        let elevation = point.elevation.flatMap { $0.isFinite ? $0 : nil }
        guard elevation != nil || point.timestamp != nil else {
            xml += "      <trkpt \(attributes)/>\n"
            return
        }
        xml += "      <trkpt \(attributes)>\n"
        if let elevation {
            xml += "        <ele>\(elevation.formatted(elevationStyle))</ele>\n"
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
        if scalar.value < firstTextScalar { return literalControlScalars.contains(scalar.value) }
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
    /// What the file system rations the last path component in, and so the
    /// bound that actually decides whether the write succeeds.
    ///
    /// A `Character` count bounds nothing here: a grapheme cluster is a base
    /// scalar plus however many combining marks follow it, so 64 of them can
    /// weigh hundreds of bytes. ``HikeTitle`` accepts such a name on purpose —
    /// see ``HikeTitle/maximumUTF8Bytes`` — which leaves this the place the
    /// weight has to be answered for. 255 is `NAME_MAX` on APFS, HFS+ and
    /// every Unix file system the share sheet can reach.
    private static let maximumFileNameUTF8Bytes = 255
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
        // The suffix is budgeted with the stem rather than after it: the date
        // and extension are what make the name useful, so they are the part
        // that gets its bytes first.
        let suffix = "-\(fileDateStyle.format(track.date)).gpx"
        let stem = fileStem(
            for: track.name,
            availableUTF8Bytes: maximumFileNameUTF8Bytes - suffix.utf8.count
        )
        return stem + suffix
    }

    /// The stem both halves of an archive are named after — the folder inside
    /// the `.zip`, and the `.zip` itself — e.g. `Thumsee Loop-2026-06-12`.
    ///
    /// Shares ``fileName(for:)``'s budget deliberately: the archive's own name
    /// is this plus four bytes and the folder inside it is this exactly, so
    /// budgeting against the longer of the two suffixes keeps every path in
    /// the archive inside the same bound the bare `.gpx` already respects.
    static func archiveStem(for track: Track) -> String {
        let suffix = "-\(fileDateStyle.format(track.date))"
        return fileStem(
            for: track.name,
            availableUTF8Bytes: maximumFileNameUTF8Bytes - suffix.utf8.count - archiveSuffixBytes
        ) + suffix
    }

    /// What one photograph is called on its way to a share sheet, e.g.
    /// `Thumsee Loop-3.jpeg`.
    ///
    /// Its own entry point rather than ``archiveStem(for:)`` because a share of
    /// a single picture has no `Track` to hand and does not need one: what
    /// names it is the hike and its place in the gallery, which is what the
    /// viewer's own title already says. The sanitising and the byte bound are
    /// shared, so a hike whose name would make a bad `.gpx` makes a bad
    /// photograph name in exactly the same way and is cut at the same
    /// grapheme.
    ///
    /// Numbered rather than dated: a walk's photographs share its date, so a
    /// date would send a dozen files to the same name.
    static func photoFileName(
        hikeTitle: String,
        position: Int,
        pathExtension: String
    ) -> String {
        let suffix = "-\(position)"
        // The dot as well as the extension — both are part of what the name
        // has to leave room for.
        let extensionBytes = pathExtension.utf8.count + 1
        let stem = fileStem(
            for: hikeTitle,
            availableUTF8Bytes: maximumFileNameUTF8Bytes - suffix.utf8.count - extensionBytes
        )
        return "\(stem)\(suffix).\(pathExtension)"
    }

    /// The `.gpx` and the `.zip` extensions weigh the same; this is the bound
    /// either of them has to leave room for.
    private static let archiveSuffixBytes = 4

    /// Reserved characters become hyphens rather than disappearing, so two
    /// hikes whose names differ only in punctuation still export to different
    /// files. A leading dot is dropped along with the trimming: it would hide
    /// the file on every Unix-derived system the share reaches.
    ///
    /// Cut on grapheme boundaries in both units, which is why the byte bound
    /// is a loop and not a `utf8` prefix: the prefix is the version of this
    /// that names the file with half an emoji in it.
    private static func fileStem(for name: String, availableUTF8Bytes: Int) -> String {
        let replaced = name.unicodeScalars.map { scalar in
            reservedFileNameCharacters.contains(scalar) ? "-" : Character(scalar)
        }
        let trimmed = String(replaced)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        var stem = String(trimmed.prefix(maximumFileStemLength))
        // At most `maximumFileStemLength` iterations, each dropping a whole
        // grapheme cluster, whatever it weighs.
        while stem.utf8.count > availableUTF8Bytes {
            stem.removeLast()
        }
        // Trimmed again because a cut can expose trailing whitespace that was
        // interior a moment ago. A name whose first grapheme alone outweighs
        // the budget ends up empty here, and takes the fallback with the rest.
        let bounded = stem
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        // The fallback is ASCII and four bytes, so it fits any budget a date
        // and an extension leave behind.
        return bounded.isEmpty ? fallbackFileStem : bounded
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
    /// ``fileName(for:)`` rather than having to be made unique against an
    /// earlier export of the same hike still staged in a shared directory.
    ///
    /// `@concurrent` rather than a detached task, as in ``GPXImport``: the
    /// work stays inside the sharing task's tree and carries its priority, and
    /// a multi-day route's few megabytes of XML are never built — or written —
    /// on the thread drawing the sheet.
    ///
    /// Not cancellable, for the same reason the import is not: building the
    /// markup and writing it are both synchronous and check nothing, so
    /// dismissing the share sheet abandons the staged file rather than the
    /// work. ``purgeStagedExports(in:before:)`` is what clears up after a
    /// share nobody completed.
    @concurrent
    static func writeTemporaryFile(for track: Track) async throws -> URL {
        assertOffMainThread("GPX serialization must stay off the main thread")
        // Spanning the write as well as the markup, since what a share costs
        // the hiker is both of them together.
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

    /// Removes exports staged before `cutoff`.
    ///
    /// The name an export's callers know the sweep by, and the export's own
    /// rule about *when* — see ``stagedExportLifetime``. The pass itself is
    /// ``StagedFiles/purge(in:before:)``, which Community's staging shares.
    static func purgeStagedExports(in directory: URL, before cutoff: Date) {
        StagedFiles.purge(in: directory, before: cutoff)
    }
}

// MARK: - Sharing

/// The share sheet's view of a hike: a GPX file, written on demand.
///
/// The payload is a ``GPXExport/Track`` rather than the `Hike` itself — see
/// that type for why — and nothing is serialized until the hiker actually
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
    /// original, which is what lets the staged file be swept by a later
    /// export instead of tracked until the receiver is finished with it.
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
    ///
    /// The community credit stands in for `<author>` when a hike has no GPX
    /// author of its own, which for a hike saved from the community is always
    /// — ``CommunityImport`` writes ``Hike/importedAuthorName`` and never
    /// ``Hike/author``. Without this, a file exported from somebody else's
    /// published route carried no trace of who published it, while a GPX that
    /// *arrived* with an author round-trips its one back out
    /// (see ``HikeImport``). This is the half of the credit that leaves the
    /// app, and so the half where losing it matters most.
    ///
    /// A file's own author wins where both exist. It is the more specific
    /// claim about the document being written, and nothing in the app sets
    /// both.
    ///
    /// The photographs are filtered to the anchored ones here rather than at
    /// the point of writing, so what the serializer receives is already the
    /// set GPX can express — see ``GPXExport/Photograph``. They keep the
    /// hike's own order, which is the order the gallery draws them in.
    init(hike: Hike) {
        self.init(
            name: hike.displayTitle,
            trackDescription: hike.trackDescription,
            author: hike.author ?? hike.importedAuthorName,
            keywords: hike.keywords,
            date: hike.date,
            route: hike.route,
            photographs: hike.photos.compactMap { photo in
                guard let coordinate = photo.coordinate else { return nil }
                return GPXExport.Photograph(
                    coordinate: RouteCoordinate(
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude
                    ),
                    capturedAt: photo.capturedAt
                )
            },
            // In along-route order, which is the order the maker's list and
            // the detail screen both draw them in — so a file opened in
            // another reader lists them the way the hiker will walk past them.
            places: hike.orderedPlaces.map(\.place)
        )
    }
}
