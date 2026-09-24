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
import OpenHikesData
import OpenHikesShared

nonisolated enum GPXImport {
    struct Point: Sendable {
        let coordinate: CLLocationCoordinate2D
        let elevation: Double?
        let time: Date?
    }

    /// A `<wpt>` the file marked as a photograph: where one was taken, and
    /// when. See ``GPXExport/appendPhotographs(_:to:)`` for the other end.
    ///
    /// No picture, and no field that could hold one. GPX carries a place and
    /// a time; what this becomes is a ``HikePhoto`` with
    /// ``HikePhoto/isPlaceOnly`` set.
    ///
    /// **`<link>` is ignored, including one this app wrote.** The plain `.gpx`
    /// export writes none, because nothing travels beside that file;
    /// ``HikeArchive`` does, because in a `.zip` the picture really is at the
    /// `href`. This importer is handed a lone `.gpx` by ``GPXInbox`` and has
    /// no archive around it to resolve a relative path against, so a link here
    /// would point at nothing. Reading an archive back in is a separate piece
    /// of work on the inbox rather than on this parser.
    struct Photograph: Sendable {
        let coordinate: CLLocationCoordinate2D
        let elevation: Double?
        /// Required rather than optional, and the one thing that can keep a
        /// waypoint out. ``HikePhoto/capturedAt`` is not optional, so a
        /// photograph with no `<time>` would have to be given one — and every
        /// candidate is a lie that sorts: the hike's start would stack every
        /// such pin at one moment in the gallery, and the import's own clock
        /// would claim the walk happened today. Our own export always writes
        /// one.
        let capturedAt: Date
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
        /// The `<wpt>`s the file marked as photographs. Empty for a file that
        /// carries none, which is every file this app did not write.
        let photographs: [Photograph]
        /// Every other `<wpt>`, as a marked place — see ``TrailPlace``.
        ///
        /// **This is new behaviour for files this app did not write**, and it
        /// is the point of reading them at all: before Phase 4 a `<wpt>` that
        /// was not one of our photographs was dropped on the floor, so a GPX
        /// carrying the huts, the springs and the summits somebody else had
        /// marked arrived as a bare line. They are kept now, which is the
        /// same trade the track's own `<desc>` and `<author>` already make —
        /// what the sender put in the file is what the hiker asked to import.
        let places: [TrailPlace]

        /// Built from `<trkseg>`-shaped runs rather than one flat list, so the
        /// file's own boundaries survive into the route.
        ///
        /// A track paused and resumed is still one hike and still one line —
        /// the app has a single `route` per hike — but the leg joining two
        /// segments crosses ground the file never recorded, and a
        /// ``RouteBoundary`` is how the route says so. `<trkseg>` is what a
        /// recording's pause is written as on the way out (see
        /// ``GPXExport/appendTrack(_:to:)``), so reading it back as a pause is
        /// what makes an exported hike survive the round trip instead of
        /// returning as one uninterrupted walk.
        ///
        /// Read as a pause rather than as ``RouteProvenance/inferred``, which
        /// is what this used to mark. The two are close but not the same, and
        /// the file itself decides which: an inference is the app reasoning
        /// about ground nobody watched, while a segment break is the *writer*
        /// saying the recording was stopped there. A file from another app
        /// that segments for its own reasons is taken at its word, on the
        /// principle that inventing a claim about unrecorded ground is the
        /// worse of the two errors.
        ///
        /// Its length still counts towards ``distanceMeters``, for the same
        /// reason a recording's own pauses do: the hiker covered that ground
        /// somehow, and a total that silently omitted it would be shorter than
        /// the walk.
        init(
            name: String?,
            trackDescription: String?,
            author: String?,
            keywords: String?,
            startTime: Date?,
            segments: [[Point]],
            photographs: [Photograph] = [],
            places: [TrailPlace] = []
        ) {
            self.name = name
            self.trackDescription = trackDescription
            self.author = author
            self.keywords = keywords
            self.startTime = startTime
            self.photographs = photographs
            self.places = places
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
                            // with, because a boundary describes the leg
                            // arriving at a point. The very first point of the
                            // route arrives from nowhere, so it opens nothing.
                            boundary: offset > 0 && index == 0 ? .paused : nil
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

    /// Parses the file at `url`.
    ///
    /// A one-point file parses *successfully* — refusing it is the import's
    /// call, not the parser's, and the distinction is what lets the caller say
    /// which of the two happened. See ``ImportFailure``.
    static func load(from url: URL, limits: Limits = .standard) throws(ImportFailure) -> Track {
        let tracks = try contents(of: try document(at: url, limits: limits), limits: limits).tracks
        guard tracks.count == 1, let track = tracks.first else { throw .multipleTracks }
        return track
    }

    /// The file read and parsed, before any of it is judged as a track.
    private static func document(at url: URL, limits: Limits) throws(ImportFailure) -> ParsedDocument {
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
        return documentParser.document
    }

    /// Parses the file at `url` into one track per `<trk>` (or `<rte>`) that
    /// carries usable points, in the order the file lists them.
    ///
    /// One track is what almost every file holds, and it comes back exactly
    /// as ``load(from:limits:)`` would return it. Several are a multi-day trip
    /// exported a day to a track, or a region's walks in one download: each
    /// becomes its own hike, never one line joined across the gaps. The
    /// file's loose `<wpt>`s go to the track they lie on — see
    /// ``GPXTrackSplit``. Past ``Limits/maximumTrackCount`` the file is
    /// refused as ``ImportFailure/tooLarge``.
    static func loadAll(from url: URL, limits: Limits = .standard) throws(ImportFailure) -> Contents {
        try contents(of: try document(at: url, limits: limits), limits: limits)
    }

    /// What a file becomes: its tracks, and how many of its loose waypoints
    /// lay on none of them and were left out — see ``GPXTrackSplit``.
    struct Contents: Sendable {
        var tracks: [Track]
        var unplacedWaypoints = 0
    }

    private static func contents(of document: ParsedDocument, limits: Limits) throws(ImportFailure) -> Contents {
        // Chosen on what the file *contains*, not on what survives validation,
        // which is what keeps a file full of unprojectable `<trkpt>` reporting
        // that its track is unusable instead of quietly importing a route's
        // handful of turn markers in its place.
        let hasGeometryOfItsOwn = document.trackSegments.contains { !$0.points.isEmpty }
            || document.routeSegments.contains { !$0.points.isEmpty }
        // The words go with the flavour the points came from: a segment's
        // container index counts `<rte>`s when the line is routes, so reading
        // it against the `<trk>` table would name a route after an empty
        // track that happened to share its number.
        let (source, words) = if document.trackSegments.contains(where: { !$0.points.isEmpty }) {
            (document.trackSegments, document.trackWords)
        } else if document.routeSegments.contains(where: { !$0.points.isEmpty }) {
            (document.routeSegments, document.routeWords)
        } else {
            // Waypoints have no container to belong to — they are loose
            // children of `<gpx>` — so the whole file is the one container.
            ([ParsedSegment(containerIndex: 0, points: document.waypoints)], document.trackWords)
        }

        let usable: [(container: Int, points: [Point])] = source.compactMap { segment in
            let points = segment.points.compactMap(point)
            return points.isEmpty ? nil : (segment.containerIndex, points)
        }
        guard !usable.isEmpty else { throw .noUsablePoints }
        // Grouped on the segments that survived, so a `<trk>` holding only
        // unprojectable points — or none at all, which plenty of exporters
        // leave behind — neither becomes a hike nor stops the others.
        let containers = usable.chunked(on: \.container)
        guard containers.count <= limits.maximumTrackCount else { throw .tooLarge }
        guard containers.count > 1 else {
            let segments = usable.map(\.points)
            let track = singleTrack(
                from: document,
                words: words.of(usable[0].container),
                segments: segments,
                hasGeometryOfItsOwn: hasGeometryOfItsOwn
            )
            return Contents(tracks: [track])
        }
        return splitTracks(
            from: document,
            words: words,
            containers: containers.map { container, segments in (container, segments.map(\.points)) }
        )
    }

    /// The one hike a single-track file becomes: the file's own name, notes
    /// and waypoints all belong to it.
    private static func singleTrack(
        from document: ParsedDocument,
        words: ContainerWords.Entry,
        segments: [[Point]],
        hasGeometryOfItsOwn: Bool
    ) -> Track {
        Track(
            name: nonEmpty(words.name)
                ?? nonEmpty(document.metadataName),
            // Bounded here, where the file enters, for the reason
            // ``HikeTitle`` bounds the name two lines up — see
            // ``BoundedText``. All three land on mirrored columns and the
            // description travels on to the public database when a hike is
            // shared, so an unattended file with a `<desc>` spending the whole
            // 32 MB budget would otherwise make a row that CloudKit cannot
            // carry. Whichever source wins is picked first and cut second,
            // because a description that is present is the one the hiker
            // meant even when it is too long.
            trackDescription: BoundedText.bounded(
                nonEmpty(words.description)
                    ?? nonEmpty(words.comment)
                    ?? nonEmpty(document.metadataDescription),
                to: .notes
            ),
            author: BoundedText.bounded(document.metadataAuthor, to: .credit),
            keywords: BoundedText.bounded(document.metadataKeywords, to: .keywords),
            // Read through the segments rather than off a flattened copy:
            // `Track` builds that copy itself, and a second one costs a
            // half-million-point file another array for one timestamp.
            startTime: document.metadataTime
                ?? segments.lazy.joined().first { $0.time != nil }?.time,
            segments: segments,
            // Only when the route came from somewhere else. A file whose
            // waypoints *are* its geometry has just had them read as the line;
            // reading the same elements a second time as photographs would pin
            // a photograph to every vertex of the track it just drew.
            photographs: hasGeometryOfItsOwn
                ? document.waypoints.compactMap(photograph)
                : [],
            // The same guard, for the same reason: a file whose waypoints *are*
            // its geometry has just had them read as the line, and reading them
            // again as places would mark every vertex of the track it drew.
            places: hasGeometryOfItsOwn
                ? Array(document.waypoints.compactMap(place).prefix(maximumPlaces))
                : []
        )
    }

    /// One hike per track of a file that holds several.
    ///
    /// Each keeps its own `<name>` and `<desc>` — the file's `<metadata>`
    /// name is the file's, not any one day's, so it names none of them — and
    /// its own start, the first stamped point it carries, because the file's
    /// `<time>` is when the first of them began. The author and keywords are
    /// the file's and go with every one. The loose `<wpt>`s are shared out by
    /// ``GPXTrackSplit``: a place or a photograph belongs to the track it lies
    /// on, and one that lies on none of them is dropped rather than guessed.
    private static func splitTracks(
        from document: ParsedDocument,
        words: ContainerWords,
        containers: [(container: Int, segments: [[Point]])]
    ) -> Contents {
        let routes = containers.map { container in
            container.segments.joined().map { point in
                RouteCoordinate(latitude: point.coordinate.latitude, longitude: point.coordinate.longitude)
            }
        }
        let places = Array(document.waypoints.compactMap(place).prefix(maximumPlaces))
        let photographs = document.waypoints.compactMap(photograph)
        let placesByTrack = GPXTrackSplit.assign(places, at: \.clCoordinate, to: routes)
        let photographsByTrack = GPXTrackSplit.assign(photographs, at: \.coordinate, to: routes)
        let placed = placesByTrack.joined().count + photographsByTrack.joined().count
        let tracks = containers.enumerated().map { offset, container in
            let own = words.of(container.container)
            return Track(
                name: nonEmpty(own.name),
                trackDescription: BoundedText.bounded(
                    nonEmpty(own.description) ?? nonEmpty(own.comment),
                    to: .notes
                ),
                author: BoundedText.bounded(document.metadataAuthor, to: .credit),
                keywords: BoundedText.bounded(document.metadataKeywords, to: .keywords),
                startTime: container.segments.lazy.joined().first { $0.time != nil }?.time,
                segments: container.segments,
                photographs: photographsByTrack[offset],
                places: placesByTrack[offset]
            )
        }
        return Contents(tracks: tracks, unplacedWaypoints: places.count + photographs.count - placed)
    }

    /// How many `<wpt>`s of a file may become places.
    ///
    /// A cap rather than a refusal, and rather than none. Unlike the
    /// photographs — which are values in one column on the hike — every place
    /// is a ``TrailPoint`` row and therefore a CloudKit record, so an
    /// unattended file with ten thousand waypoints would put ten thousand
    /// records into the hiker's private database for a route they opened once.
    /// Refusing the file instead would be worse: the line is fine, and a hike
    /// nobody can import because somebody else over-marked it is a hike lost
    /// to a detail. Generous enough that no hand-made route reaches it —
    /// a long alpine traverse carries a few dozen.
    static let maximumPlaces = 200

    /// A `<wpt>` read as a marked place, or `nil` for one that is a
    /// photograph or has no usable coordinate.
    ///
    /// Everything that is not a photograph, which is the whole rule: a `<wpt>`
    /// is *a point of interest* in GPX, and this app now has somewhere to put
    /// one. The photographs are subtracted first because they are the one kind
    /// this app already gives a different home — see ``photograph(_:)``.
    ///
    /// `<sym>` is read through ``TrailPlaceSymbol``'s own raw values, so a
    /// file this app wrote round-trips exactly; anything else keeps its name
    /// and its note and gets no symbol, which is the honest answer rather than
    /// guessing at somebody else's table. See ``TrailPlace`` for why an
    /// unstated symbol is a state rather than a missing value.
    ///
    /// The name and note are bounded here, where the file enters, for the
    /// reason ``HikeTitle`` bounds the track's own name two screens up: both
    /// land on mirrored columns, and an unattended file is exactly the input
    /// that argument is about. A `<wpt>` with nothing but a coordinate is
    /// still a place — the map draws it as an unnamed pin, which is what the
    /// file said.
    private static func place(_ waypoint: ParsedPoint) -> TrailPlace? {
        guard !isPhotograph(waypoint), let point = point(waypoint) else { return nil }
        return TrailPlace(
            coordinate: point.coordinate,
            name: BoundedText.boundedOrEmpty(waypoint.name, to: .title),
            symbol: waypoint.symbol.flatMap(symbol(named:)),
            note: BoundedText.boundedOrEmpty(waypoint.note, to: .notes),
            osm: waypoint.osm
        )
    }

    /// A `<sym>` read as one of the eight, case-insensitively.
    ///
    /// Case-insensitive because a symbol name is a lookup key in somebody
    /// else's table rather than text this app wrote — the same reason
    /// ``isPhotographLabel(_:)`` is.
    private static func symbol(named raw: String) -> TrailPlaceSymbol? {
        TrailPlaceSymbol.allCases.first { candidate in
            candidate.rawValue.caseInsensitiveCompare(raw) == .orderedSame
        }
    }

    /// A `<wpt>` read as a photograph, or `nil` for one that is not.
    ///
    /// Recognised by `<sym>` first and `<name>` second, matching what
    /// ``GPXExport`` writes. Both are checked because readers disagree about
    /// which they keep: `<sym>` is the one that means *what kind of waypoint
    /// this is* and is the reading intended, but a reader that drops symbols
    /// it has no glyph for and keeps the label would otherwise lose the round
    /// trip through no fault of the file.
    ///
    /// Case-insensitive, because a symbol name is a lookup key in somebody
    /// else's table rather than text this app wrote.
    private static func photograph(_ waypoint: ParsedPoint) -> Photograph? {
        guard isPhotograph(waypoint) else { return nil }
        // Reuses the track point's own guards, so a photograph cannot be
        // pinned somewhere a track point would have been refused: the same
        // Web Mercator range check, and the same refusal of a non-finite
        // `<ele>`.
        guard let point = point(waypoint), let capturedAt = point.time else { return nil }
        return Photograph(
            coordinate: point.coordinate,
            elevation: point.elevation,
            capturedAt: capturedAt
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

    /// Whether a `<wpt>` is labelled as one of our photographs.
    ///
    /// Its own question since Phase 4, because two readings now depend on it:
    /// a photograph is one thing, and everything that is *not* a photograph is
    /// a marked place. One predicate is what keeps a `<wpt>` from being read
    /// as both.
    private static func isPhotograph(_ waypoint: ParsedPoint) -> Bool {
        [waypoint.symbol, waypoint.name].compacted().contains(where: isPhotographLabel)
    }

    /// Whether one `<sym>` or `<name>` is the label ``GPXExport`` writes.
    ///
    /// Case-insensitive, because a symbol name is a lookup key in somebody
    /// else's table rather than text this app wrote.
    private static func isPhotographLabel(_ label: String) -> Bool {
        label.caseInsensitiveCompare(GPXExport.photographSymbol) == .orderedSame
            || label.caseInsensitiveCompare(GPXExport.photographName) == .orderedSame
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
        /// `<name>`, `<sym>` and `<desc>`, read so a `<wpt>` can be
        /// recognised as a photograph and, failing that, kept as a marked
        /// place. All three stay `nil` for a `<trkpt>` or `<rtept>`: nothing
        /// asks a route point what it is called, and filling them would cost
        /// three string stores per point on a hundred-thousand-point track.
        var name: String?
        var symbol: String?
        var note: String?
        /// The OpenStreetMap element a `<link href>` names — what
        /// ``GPXExport`` writes for a place that came from there. `nil` for
        /// any other link.
        var osm: TrailPlaceOSM?
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

    /// The `<name>`, `<desc>` and `<cmt>` of each `<trk>`, or of each `<rte>`,
    /// by container index.
    private struct ContainerWords {
        struct Entry {
            var name, description, comment: String?
        }

        var entries: [Int: Entry] = [:]

        func of(_ container: Int) -> Entry { entries[container] ?? Entry() }
    }

    private struct ParsedDocument {
        var metadataName: String?
        var metadataDescription: String?
        var metadataAuthor: String?
        var metadataKeywords: String?
        var metadataTime: Date?
        /// Each `<trk>`'s own `<name>`, `<desc>` and `<cmt>`, and each
        /// `<rte>`'s, by its index among its own kind — the same index a
        /// segment's ``ParsedSegment/containerIndex`` carries, so a track's
        /// words and its points meet by number.
        var trackWords = ContainerWords()
        var routeWords = ContainerWords()
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
            static let symbol = "sym"
            static let link = "link"
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
            // A waypoint's own `<link>`, read off its attribute at the start
            // tag because that is where `href` is. The element is already on
            // `path`, so its parent is one further back.
            case Element.link:
                guard var point = pendingPoint, point.kind == .waypoint,
                      path.dropLast().last == point.element,
                      let href = attributeDict["href"], let url = URL(string: href),
                      let osm = TrailPlaceOSM(url: url) else { break }
                point.value.osm = osm
                pendingPoint = point
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
            // Only for a waypoint, which is the only kind anything asks. A
            // `<trkpt>` may legally carry both and a long track carrying them
            // would pay two string stores a point to record what no reader
            // here ever looks at.
            case Element.name where point.kind == .waypoint: point.value.name = value
            case Element.symbol where point.kind == .waypoint: point.value.symbol = value
            case Element.description where point.kind == .waypoint: point.value.note = value
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
            case Element.trackPoint, Element.routePoint, Element.waypoint: finishPoint(element)
            default: applyContainerWord(value, for: element)
            }
        }

        /// A `<trk>`'s or `<rte>`'s own `<name>`, `<desc>` or `<cmt>`, filed
        /// under its container's index.
        private func applyContainerWord(_ value: String, for element: String) {
            let field: WritableKeyPath<ContainerWords.Entry, String?>
            switch element {
            case Element.name: field = \.name
            case Element.description: field = \.description
            case Element.comment: field = \.comment
            default: return
            }
            if isTrackChild {
                document.trackWords.entries[currentTrackIndex, default: .init()][keyPath: field] = value
            } else if isRouteChild {
                document.routeWords.entries[currentRouteIndex, default: .init()][keyPath: field] = value
            }
        }

        /// The element being closed sits directly inside `parent`. Compares the
        /// one enclosing name rather than building an array literal per call —
        /// `</time>` closes once per track point, so this is a hot path.
        private func isDirectChild(of parent: String) -> Bool {
            path.dropLast().last == parent
        }

        private var isTrackChild: Bool {
            currentTrackIndex >= 0 && isDirectChild(of: Element.track)
        }

        private var isRouteChild: Bool {
            currentRouteIndex >= 0 && isDirectChild(of: Element.route)
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
        /// hiker the hour their own file says. Last of the three because the
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
