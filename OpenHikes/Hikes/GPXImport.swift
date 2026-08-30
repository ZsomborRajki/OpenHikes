//
//  GPXImport.swift
//  OpenHikes
//
//  Reads a .gpx file into an ordered list of points using Foundation XML.
//  Prefers track points, falling back to route points, then waypoints, and
//  pulls whatever metadata a well-formed file provides.
//

import Algorithms
import CoreLocation
import Foundation
import OpenHikesShared

nonisolated enum GPXImport {
    struct Point: Sendable {
        let coordinate: CLLocationCoordinate2D
        let elevation: Double?
        let time: Date?
    }

    struct Track: Sendable {
        let name: String?
        let trackDescription: String?
        let author: String?
        let keywords: String?
        /// Activity start time, from the metadata or the first timestamped point.
        let startTime: Date?
        let points: [Point]
        let route: [RouteCoordinate]
        /// Total length in meters, computed once while preparing the import.
        let distanceMeters: Double

        /// Built from `<trkseg>`-shaped runs rather than one flat list, so the
        /// file's own boundaries survive into the route.
        ///
        /// A track paused and resumed is still one hike and still one line —
        /// the app has a single `route` per hike and nothing to draw a hole in
        /// it with — but the leg joining two segments crosses ground the file
        /// never recorded, and saying so is exactly what ``RouteProvenance``
        /// exists for. Marking it `.inferred` is what makes the map draw that
        /// leg as a guess and the statistics count it as unobserved, instead
        /// of presenting a stretch nobody walked with the same authority as
        /// the fixes on either side of it.
        ///
        /// Its length still counts towards ``distanceMeters``, for the same
        /// reason a recording's own gaps do: the walker covered that ground
        /// somehow, and a total that silently omitted it would be shorter than
        /// the walk. What the hike then says about it is how much of the
        /// length was inferred.
        init(
            name: String?,
            trackDescription: String?,
            author: String?,
            keywords: String?,
            startTime: Date?,
            segments: [[Point]]
        ) {
            self.name = name
            self.trackDescription = trackDescription
            self.author = author
            self.keywords = keywords
            self.startTime = startTime
            points = Array(segments.joined())

            var coordinates: [RouteCoordinate] = []
            coordinates.reserveCapacity(points.count)
            for (offset, segment) in segments.enumerated() {
                for (index, point) in segment.enumerated() {
                    coordinates.append(
                        RouteCoordinate(
                            latitude: point.coordinate.latitude,
                            longitude: point.coordinate.longitude,
                            elevation: point.elevation,
                            timestamp: point.time,
                            // The mark belongs to the point a segment *opens*
                            // with, because provenance describes the leg
                            // arriving at a point. The very first point of the
                            // route arrives from nowhere, so it stays measured.
                            provenance: offset > 0 && index == 0 ? .inferred : nil
                        )
                    )
                }
            }
            route = coordinates

            var cumulativeDistance = 0.0
            for (start, end) in points.adjacentPairs() {
                cumulativeDistance += RouteGeometry.distanceMeters(
                    from: start.coordinate,
                    to: end.coordinate
                )
            }
            distanceMeters = cumulativeDistance
        }
    }

    /// What one picked file is allowed to cost.
    ///
    /// The app has no say in what arrives here. A file the user chose from
    /// Files at least passed under their eyes first; one delivered through
    /// `Documents/Inbox` — AirDrop, a mail attachment, a share extension —
    /// was chosen by somebody else and is read unattended, so these two
    /// numbers are the only thing standing between the import and however
    /// much memory the sender felt like spending.
    ///
    /// Two bounds because neither implies the other: the byte cap bounds the
    /// single allocation `Data(contentsOf:)` makes, while the point cap bounds
    /// the arrays the parse grows out of those bytes, which a file written
    /// without whitespace or elevations can fill from far fewer of them.
    ///
    /// Taken as a parameter rather than read as a constant only so the suite
    /// can drive both bounds directly instead of having to serialize a file
    /// large enough to reach the shipping ones; every caller in the app takes
    /// ``standard``.
    struct Limits: Sendable, Equatable {
        var maximumFileSizeBytes: Int
        var maximumPointCount: Int

        /// Sized against the largest file a walker could plausibly own, not
        /// against the smallest one that would still work.
        ///
        /// A day out recorded at 1 Hz is roughly 20,000 track points and a
        /// little over 2 MB; the same points carrying Garmin's or Strava's
        /// `<extensions>` (heart rate, cadence, temperature) are nearer 6 MB.
        /// 32 MB is well over an order of magnitude above a day's walk, so
        /// nothing anybody would recognise as one of their own hikes comes
        /// near it, and reading plus parsing a file at the cap still peaks
        /// inside what iOS lets a foreground app hold. Half a million points
        /// is around 140 hours of 1 Hz fixes — more than any single track is —
        /// and is what a file that spends all its bytes on points runs into
        /// first.
        ///
        /// Both are deliberately loose. A cap that refuses a real hike is a
        /// worse failure than one that lets an absurd file through, because
        /// the walker with the real hike has no way to get it in.
        static let standard = Self(
            maximumFileSizeBytes: standardFileSizeBytes,
            maximumPointCount: standardPointCount
        )

        private static let standardFileSizeBytes = 32 * 1024 * 1024
        private static let standardPointCount = 500_000
    }

    /// Why a file couldn't be turned into a hike.
    ///
    /// Worth distinguishing rather than collapsing to "import failed": each
    /// means something genuinely different to whoever picked the file, and
    /// sends them somewhere different to fix it. The import used to say nothing
    /// at all — a picked file that produced no hike looked exactly like a
    /// picked file that was ignored.
    ///
    /// `CaseIterable` so the suite can walk every case and insist it carries
    /// copy: a case added here without a sentence to show is an empty alert,
    /// and a hand-written list of cases in a test cannot notice the omission.
    enum ImportFailure: LocalizedError, CaseIterable, Equatable, Sendable {
        /// More than one `<trk>` (or more than one `<rte>`) carrying usable
        /// points. Each is a separate activity, and a hike here holds exactly
        /// one route, so the file has no single answer to "which walk is
        /// this?". Refused rather than answered by guessing: joining them
        /// invents a leg between two places nobody travelled between, and
        /// picking one silently throws the others away.
        case multipleTracks
        /// Parsed, but nothing in it carried a coordinate this app can project
        /// — no points at all, points missing `lat`/`lon`, or points outside
        /// Web Mercator's range.
        case noUsablePoints
        /// Past one of ``Limits``. Refused before the bytes are read where the
        /// file system will say how big the file is, and mid-parse where it
        /// won't.
        case tooLarge
        /// One usable point. Enough to put a pin on a map; not a route — no
        /// length, no elevation profile, nothing to draw. Policy rather than a
        /// parse failure, so ``load(from:limits:)`` still returns such a track
        /// and the import is what refuses it.
        case tooShort
        /// Not there, or not well-formed XML — the parser had nothing to work
        /// with. Note that well-formed XML that simply *isn't* GPX (an HTML
        /// page, say) parses happily into an empty document, so it arrives as
        /// ``noUsablePoints`` instead; the copy for that case allows for it.
        case unreadable

        var errorDescription: String? {
            switch self {
            case .multipleTracks: "This GPX file holds more than one track."
            case .noUsablePoints: "No track points were found in this file."
            case .tooLarge: "This GPX file is too large to import."
            case .tooShort: "This GPX file has only one track point."
            case .unreadable: "This file couldn't be read."
            }
        }

        var recoverySuggestion: String? {
            switch self {
            // Says what the app would otherwise have had to invent, because
            // that is the part the walker can't see for themselves: the file
            // opens fine everywhere else, and the damage would only show up
            // later as a straight line across the map and a length nobody
            // walked.
            case .multipleTracks: "Each track is a separate walk, and joining them would draw a line between "
                + "places you never travelled. Split the file so each track imports as its own hike."
            // Deliberately covers "it isn't GPX at all" as well — see the case's
            // own note for why that lands here.
            case .noUsablePoints: "It may not be a GPX file, or its points are missing coordinates or out of range."
            // No number in the copy: the message has to be true of both bounds,
            // and the walker can act on it without knowing which one was hit.
            case .tooLarge: "A single walk is a few megabytes at most. A file this size usually holds many tracks, "
                + "and splitting it lets them import one at a time."
            case .tooShort: "A hike needs at least two points to have a route."
            case .unreadable: "Check that it's a .gpx file and isn't damaged."
            }
        }
    }

    /// Parses the file at `url`.
    ///
    /// A one-point file parses *successfully* — refusing it is the import's
    /// call, not the parser's, and the distinction is what lets the caller say
    /// which of the two happened. See ``ImportFailure``.
    static func load(from url: URL, limits: Limits = .standard) throws(ImportFailure) -> Track {
        // Asked of the file system before the read rather than measured after
        // it. `Data(contentsOf:)` brings the whole file in as one allocation,
        // so a size learned from `data.count` has already been paid for, and
        // the file this bound exists for is precisely the one that shouldn't
        // be read at all.
        if let reportedSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           reportedSize > limits.maximumFileSizeBytes { throw .tooLarge }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { throw .unreadable }
        // Not every URL answers `.fileSizeKey` — a file vended by a document
        // provider may report nothing — so the length that was actually read
        // is checked as well, before it is handed to the parser.
        guard data.count <= limits.maximumFileSizeBytes else { throw .tooLarge }

        let documentParser = DocumentParser(maximumPointCount: limits.maximumPointCount)
        let parser = XMLParser(data: data)
        parser.delegate = documentParser
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        // An aborted parse and a malformed one both come back `false`, and the
        // two have to reach the user as different sentences.
        guard parser.parse() else {
            throw documentParser.hasExceededPointLimit ? .tooLarge : .unreadable
        }
        return try track(from: documentParser.document)
    }

    /// Parses and prepares a picked file without occupying the main actor.
    ///
    /// `@concurrent` rather than a detached task: the parse stays part of the
    /// importing task, so abandoning the import cancels it, and the caller's
    /// priority carries through instead of being pinned here.
    @concurrent
    static func loadOffMain(
        from url: URL,
        limits: Limits = .standard
    ) async throws(ImportFailure) -> Track {
        assertOffMainThread(
            "GPX parsing and route preparation must stay off the main thread"
        )
        // Timed rather than counted: an import happens once, and what matters
        // is whether the main thread stayed answerable for the whole of it.
        // Pair this interval with any `MainThread` stall at the same instant.
        return try RenderSignpost.interval("GPXParsed") { () throws(ImportFailure) in
            try load(from: url, limits: limits)
        }
    }

    private static func track(from document: ParsedDocument) throws(ImportFailure) -> Track {
        // Chosen on what the file *contains*, not on what survives validation,
        // which is what keeps a file full of unprojectable `<trkpt>` reporting
        // that its track is unusable instead of quietly importing a route's
        // handful of turn markers in its place.
        let source = if document.trackSegments.contains(where: { !$0.points.isEmpty }) {
            document.trackSegments
        } else if document.routeSegments.contains(where: { !$0.points.isEmpty }) {
            document.routeSegments
        } else {
            // Waypoints have no container to belong to — they are loose
            // children of `<gpx>` — so the whole file is the one container.
            [ParsedSegment(containerIndex: 0, points: document.waypoints)]
        }

        let usable: [(container: Int, points: [Point])] = source.compactMap { segment in
            let points = segment.points.compactMap(point)
            return points.isEmpty ? nil : (segment.containerIndex, points)
        }
        guard let first = usable.first else { throw .noUsablePoints }
        // Judged on the segments that survived, so a `<trk>` holding only
        // unprojectable points — or none at all, which plenty of exporters
        // leave behind — doesn't make a perfectly ordinary file unimportable.
        guard usable.allSatisfy({ $0.container == first.container }) else {
            throw .multipleTracks
        }

        let segments = usable.map(\.points)
        return Track(
            name: nonEmpty(document.firstTrackName)
                ?? nonEmpty(document.metadataName),
            trackDescription: nonEmpty(document.firstTrackDescription)
                ?? nonEmpty(document.firstTrackComment)
                ?? nonEmpty(document.metadataDescription),
            author: nonEmpty(document.metadataAuthor),
            keywords: nonEmpty(document.metadataKeywords),
            // Read through the segments rather than off a flattened copy:
            // `Track` builds that copy itself, and a second one costs a
            // half-million-point file another array for one timestamp.
            startTime: document.metadataTime
                ?? segments.lazy.joined().first { $0.time != nil }?.time,
            segments: segments
        )
    }

    private static func point(_ waypoint: ParsedPoint) -> Point? {
        // Points outside Web Mercator's representable range are rejected at
        // the door rather than clamped: `Mercator` clamps to keep drawing
        // code safe, but a track claiming to pass within 5° of a pole is bad
        // data, not something to silently move onto the map's edge.
        guard
            let lat = waypoint.latitude, let lon = waypoint.longitude,
            Mercator.isRepresentable(latitude: lat, longitude: lon)
        else { return nil }
        return Point(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            // `<ele>nan</ele>` and `<ele>1e400</ele>` are both ordinary GPX
            // text that `Double.init` accepts, and either one poisons every
            // figure derived from the route afterwards: a NaN loses every
            // comparison, so `min` and `max` return it rather than the real
            // extremes, and the elevation chart's y-domain becomes `nan...nan`
            // — bounds `ClosedRange` traps on rather than draws badly.
            //
            // The point keeps its coordinate instead of being dropped whole,
            // unlike an unprojectable one above: a height is a field the route
            // does not need, so tearing a hole in the line to punish a bad
            // `<ele>` would cost geometry that was never in question.
            elevation: waypoint.elevation.flatMap { $0.isFinite ? $0 : nil },
            time: waypoint.time
        )
    }

    private static func nonEmpty(_ string: String?) -> String? {
        guard let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

nonisolated private extension GPXImport {
    private struct ParsedPoint {
        var latitude: Double?
        var longitude: Double?
        var elevation: Double?
        var time: Date?
    }

    /// One run of points that the file itself kept together: a `<trkseg>`, or
    /// a `<rte>`.
    ///
    /// The parse used to hand back one flat array per flavour, which threw
    /// away the only thing that says whether two consecutive points are a step
    /// apart or a country apart. Both boundaries matter, and they matter
    /// differently — segments of one track are a paused recording, separate
    /// tracks are separate walks — so the container each run came from is
    /// carried alongside the run rather than inferred from it afterwards.
    private struct ParsedSegment {
        /// Which `<trk>`/`<rte>` this run came from. Segments of the same
        /// track share it; the number itself means nothing beyond that.
        let containerIndex: Int
        var points: [ParsedPoint] = []
    }

    private struct ParsedDocument {
        var metadataName: String?
        var metadataDescription: String?
        var metadataAuthor: String?
        var metadataKeywords: String?
        var metadataTime: Date?
        var firstTrackName: String?
        var firstTrackDescription: String?
        var firstTrackComment: String?
        var trackSegments: [ParsedSegment] = []
        var routeSegments: [ParsedSegment] = []
        var waypoints: [ParsedPoint] = []
    }

    private final class DocumentParser: NSObject, XMLParserDelegate {
        /// GPX element names, which the schema defines in lower case. XML is
        /// case-sensitive and `XMLParser` reports the local name verbatim, so
        /// these are compared as-is.
        private enum Element {
            static let track = "trk"
            static let trackSegment = "trkseg"
            static let trackPoint = "trkpt"
            static let route = "rte"
            static let routePoint = "rtept"
            static let waypoint = "wpt"
            static let metadata = "metadata"
            static let author = "author"
            static let name = "name"
            static let description = "desc"
            static let comment = "cmt"
            static let keywords = "keywords"
            static let elevation = "ele"
            static let time = "time"
        }

        private enum PointKind {
            case track
            case route
            case waypoint
        }

        private struct PendingPoint {
            let kind: PointKind
            let element: String
            var value: ParsedPoint
        }

        private let fractionalDateStrategy = Date.ISO8601FormatStyle(
            includingFractionalSeconds: true
        )
        private let dateStrategy = Date.ISO8601FormatStyle()
        /// The same grammar with the zone designator taken out of it, so what
        /// the string omits is supplied by the device instead. See
        /// ``date(from:)`` for why that is the reading chosen.
        private let localDateStrategy = Date.ISO8601FormatStyle(
            timeZone: .autoupdatingCurrent
        )
        .year()
        .month()
        .day()
        .dateSeparator(.dash)
        .dateTimeSeparator(.standard)
        .time(includingFractionalSeconds: true)
        private let maximumPointCount: Int
        private var path: [String] = []
        private var text = ""
        private var currentTrackIndex = -1
        private var currentRouteIndex = -1
        /// Whether a run is open to append to, per flavour. A `<trkseg>` or
        /// `<rte>` start opens one and its end tag closes it; a point that
        /// arrives with none open opens one implicitly, which is what keeps
        /// `<trk><trkpt/></trk>` — legal GPX, and what a stray `</trkseg>`
        /// leaves behind — from being dropped for want of a container.
        private var hasOpenTrackSegment = false
        private var hasOpenRouteSegment = false
        private var pendingPoint: PendingPoint?
        private var parsedPointCount = 0

        var document = ParsedDocument()
        /// Set the moment the file goes past ``maximumPointCount``, which is
        /// also when the parse is abandoned. Read by ``GPXImport/load(from:limits:)``
        /// to tell a deliberate stop from a malformed document, since
        /// `XMLParser.parse()` reports both as `false`.
        private(set) var hasExceededPointLimit = false

        init(maximumPointCount: Int) {
            self.maximumPointCount = maximumPointCount
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String]
        ) {
            // GPX defines its element names in lower case and `XMLParser` is
            // handing back the local name already, so this is a straight
            // append: `lowercased()` here allocated a fresh `String` for every
            // start *and* end tag, which on a 100,000-point track is hundreds
            // of thousands of allocations to normalise names that were already
            // normal.
            path.append(elementName)
            text = ""

            switch elementName {
            case Element.track:
                currentTrackIndex += 1
                // A `<trk>` opening mid-track means the previous one never
                // closed. Its run ends here either way; what must not happen
                // is the next track's points landing in it.
                hasOpenTrackSegment = false
            case Element.trackSegment: openTrackSegment()
            case Element.route:
                currentRouteIndex += 1
                hasOpenRouteSegment = false
                openRouteSegment()
            case Element.trackPoint: pendingPoint = PendingPoint(
                kind: .track,
                element: elementName,
                value: point(from: attributeDict)
            )
            case Element.routePoint: pendingPoint = PendingPoint(
                kind: .route,
                element: elementName,
                value: point(from: attributeDict)
            )
            case Element.waypoint: pendingPoint = PendingPoint(
                kind: .waypoint,
                element: elementName,
                value: point(from: attributeDict)
            )
            default: break
            }
        }

        func parser(
            _ parser: XMLParser,
            foundCharacters string: String
        ) {
            text.append(string)
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard let string = String(bytes: CDATABlock, encoding: .utf8) else { return }
            text.append(string)
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            updatePendingPoint(element: elementName, value: value)
            apply(value: value, for: elementName)
            switch elementName {
            case Element.trackSegment, Element.track: hasOpenTrackSegment = false
            case Element.route: hasOpenRouteSegment = false
            default: break
            }
            path.removeLast()
            text = ""
            // Stopping here rather than inside `finishPoint` because this is
            // where the parser itself is in scope, and one more end tag's worth
            // of work is nothing next to the rest of the file it saves.
            if hasExceededPointLimit { parser.abortParsing() }
        }

        private func updatePendingPoint(
            element: String,
            value: String
        ) {
            guard var point = pendingPoint,
                  path.dropLast().last == point.element else { return }
            switch element {
            case Element.elevation: point.value.elevation = Double(value)
            case Element.time: point.value.time = date(from: value)
            default: return
            }
            pendingPoint = point
        }

        private func apply(value: String, for element: String) {
            switch element {
            case Element.name where isDirectChild(of: Element.metadata): document.metadataName = value
            case Element.description where isDirectChild(of: Element.metadata): document.metadataDescription = value
            case Element.name where isMetadataAuthorChild: document.metadataAuthor = value
            case Element.keywords where isDirectChild(of: Element.metadata): document.metadataKeywords = value
            case Element.time where isDirectChild(of: Element.metadata): document.metadataTime = date(from: value)
            case Element.name where isFirstTrackChild: document.firstTrackName = value
            case Element.description where isFirstTrackChild: document.firstTrackDescription = value
            case Element.comment where isFirstTrackChild: document.firstTrackComment = value
            case Element.trackPoint, Element.routePoint, Element.waypoint: finishPoint(element)
            default: break
            }
        }

        /// The element being closed sits directly inside `parent`. Compares the
        /// one enclosing name rather than building an array literal per call —
        /// `</time>` closes once per track point, so this is a hot path.
        private func isDirectChild(of parent: String) -> Bool {
            path.dropLast().last == parent
        }

        private var isFirstTrackChild: Bool {
            currentTrackIndex == 0 && isDirectChild(of: Element.track)
        }

        private var isMetadataAuthorChild: Bool {
            isDirectChild(of: Element.author)
                && path.dropLast(2).last == Element.metadata
        }

        private func point(
            from attributes: [String: String]
        ) -> ParsedPoint {
            ParsedPoint(
                latitude: attributes["lat"].flatMap(Double.init),
                longitude: attributes["lon"].flatMap(Double.init)
            )
        }

        /// Starts a fresh run for the track being read, keeping the empty ones
        /// an exporter leaves behind: `track(from:)` drops those, and dropping
        /// them here instead would lose the `<trk>` they belong to along the
        /// way.
        private func openTrackSegment() {
            document.trackSegments.append(
                ParsedSegment(containerIndex: max(currentTrackIndex, 0))
            )
            hasOpenTrackSegment = true
        }

        private func openRouteSegment() {
            document.routeSegments.append(
                ParsedSegment(containerIndex: max(currentRouteIndex, 0))
            )
            hasOpenRouteSegment = true
        }

        private func finishPoint(_ element: String) {
            guard let point = pendingPoint, point.element == element else { return }
            switch point.kind {
            case .track:
                if !hasOpenTrackSegment { openTrackSegment() }
                document.trackSegments[document.trackSegments.count - 1].points.append(point.value)
            case .route:
                if !hasOpenRouteSegment { openRouteSegment() }
                document.routeSegments[document.routeSegments.count - 1].points.append(point.value)
            case .waypoint: document.waypoints.append(point.value)
            }
            pendingPoint = nil
            // Counted across all three flavours, not per flavour: memory does
            // not care which array a point landed in, and only one of them will
            // become the track.
            parsedPointCount += 1
            if parsedPointCount > maximumPointCount { hasExceededPointLimit = true }
        }

        /// GPX 1.1 says a `<time>` is UTC and carries a designator, and the two
        /// strict strategies are that file. The third is for the files people
        /// actually have: exporters that write `2020-01-01T10:00:00` with no
        /// `Z` and no offset are common enough that refusing them costs the
        /// hike its duration, both its speeds and its date — a whole track's
        /// worth of timestamps discarded over a missing letter.
        ///
        /// Read as the device's own time rather than as UTC. Both are guesses
        /// and both are wrong by the same offset when the guess is wrong; what
        /// decides it is that an exporter omitting the designator is writing
        /// wall-clock time, so reading it locally is the one that shows the
        /// walker the hour their own file says. Last of the three because the
        /// lenient grammar also accepts a string that *does* carry a
        /// designator and would quietly ignore it.
        private func date(from value: String) -> Date? {
            guard !value.isEmpty else { return nil }
            return (try? fractionalDateStrategy.parse(value))
                ?? (try? dateStrategy.parse(value))
                ?? (try? localDateStrategy.parse(value))
        }
    }
}
