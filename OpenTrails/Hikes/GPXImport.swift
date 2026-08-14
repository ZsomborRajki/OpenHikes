//
//  GPXImport.swift
//  OpenTrails
//
//  Reads a .gpx file into an ordered list of points using Foundation XML.
//  Prefers track points, falling back to route points, then waypoints, and
//  pulls whatever metadata a well-formed file provides.
//

import Algorithms
import CoreLocation
import Foundation
import OpenTrailsShared

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
        let coordinates: [CLLocationCoordinate2D]
        let route: [RouteCoordinate]
        /// Total length in meters, computed once while preparing the import.
        let distanceMeters: Double

        init(
            name: String?,
            trackDescription: String?,
            author: String?,
            keywords: String?,
            startTime: Date?,
            points: [Point]
        ) {
            self.name = name
            self.trackDescription = trackDescription
            self.author = author
            self.keywords = keywords
            self.startTime = startTime
            self.points = points
            coordinates = points.map(\.coordinate)
            route = points.map { point in
                RouteCoordinate(
                    latitude: point.coordinate.latitude,
                    longitude: point.coordinate.longitude,
                    elevation: point.elevation,
                    timestamp: point.time
                )
            }

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

    /// Why a file couldn't be turned into a hike.
    ///
    /// Worth distinguishing rather than collapsing to "import failed": the
    /// three mean genuinely different things to whoever picked the file, and
    /// send them somewhere different to fix it. The import used to say nothing
    /// at all — a picked file that produced no hike looked exactly like a
    /// picked file that was ignored.
    enum ImportFailure: LocalizedError, Equatable, Sendable {
        /// Parsed, but nothing in it carried a coordinate this app can project
        /// — no points at all, points missing `lat`/`lon`, or points outside
        /// Web Mercator's range.
        case noUsablePoints
        /// One usable point. Enough to put a pin on a map; not a route — no
        /// length, no elevation profile, nothing to draw. Policy rather than a
        /// parse failure, so ``load(from:)`` still returns such a track and the
        /// import is what refuses it.
        case tooShort
        /// Not there, or not well-formed XML — the parser had nothing to work
        /// with. Note that well-formed XML that simply *isn't* GPX (an HTML
        /// page, say) parses happily into an empty document, so it arrives as
        /// ``noUsablePoints`` instead; the copy for that case allows for it.
        case unreadable

        var errorDescription: String? {
            switch self {
            case .noUsablePoints: "No track points were found in this file."
            case .tooShort: "This GPX file has only one track point."
            case .unreadable: "This file couldn't be read."
            }
        }

        var recoverySuggestion: String? {
            switch self {
            // Deliberately covers "it isn't GPX at all" as well — see the case's
            // own note for why that lands here.
            case .noUsablePoints: "It may not be a GPX file, or its points are missing coordinates or out of range."
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
    static func load(from url: URL) throws(ImportFailure) -> Track {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            throw .unreadable
        }
        let documentParser = DocumentParser()
        let parser = XMLParser(data: data)
        parser.delegate = documentParser
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw .unreadable
        }
        guard let track = track(from: documentParser.document) else {
            throw .noUsablePoints
        }
        return track
    }

    /// Parses and prepares a picked file without occupying the main actor.
    ///
    /// `@concurrent` rather than a detached task: the parse stays part of the
    /// importing task, so abandoning the import cancels it, and the caller's
    /// priority carries through instead of being pinned here.
    @concurrent
    static func loadOffMain(from url: URL) async throws(ImportFailure) -> Track {
        assertOffMainThread(
            "GPX parsing and route preparation must stay off the main thread"
        )
        return try load(from: url)
    }

    private static func track(from document: ParsedDocument) -> Track? {
        let source = if !document.trackPoints.isEmpty {
            document.trackPoints
        } else if !document.routePoints.isEmpty {
            document.routePoints
        } else {
            document.waypoints
        }
        let points = source.compactMap(point)
        guard !points.isEmpty else { return nil }

        return Track(
            name: nonEmpty(document.firstTrackName)
                ?? nonEmpty(document.metadataName),
            trackDescription: nonEmpty(document.firstTrackDescription)
                ?? nonEmpty(document.firstTrackComment)
                ?? nonEmpty(document.metadataDescription),
            author: nonEmpty(document.metadataAuthor),
            keywords: nonEmpty(document.metadataKeywords),
            startTime: document.metadataTime
                ?? points.first { $0.time != nil }?.time,
            points: points
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
            elevation: waypoint.elevation,
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

    private struct ParsedDocument {
        var metadataName: String?
        var metadataDescription: String?
        var metadataAuthor: String?
        var metadataKeywords: String?
        var metadataTime: Date?
        var firstTrackName: String?
        var firstTrackDescription: String?
        var firstTrackComment: String?
        var trackPoints: [ParsedPoint] = []
        var routePoints: [ParsedPoint] = []
        var waypoints: [ParsedPoint] = []
    }

    private final class DocumentParser: NSObject, XMLParserDelegate {
        /// GPX element names, which the schema defines in lower case. XML is
        /// case-sensitive and `XMLParser` reports the local name verbatim, so
        /// these are compared as-is — the same way the previous parser matched
        /// them.
        private enum Element {
            static let track = "trk"
            static let trackPoint = "trkpt"
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
        private var path: [String] = []
        private var text = ""
        private var currentTrackIndex = -1
        private var pendingPoint: PendingPoint?

        var document = ParsedDocument()

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
            // start *and* end tag, which on a 100,000-point export is hundreds
            // of thousands of allocations to normalise names that were already
            // normal.
            path.append(elementName)
            text = ""

            switch elementName {
            case Element.track:
                currentTrackIndex += 1
            case Element.trackPoint:
                pendingPoint = PendingPoint(
                    kind: .track,
                    element: elementName,
                    value: point(from: attributeDict)
                )
            case Element.routePoint:
                pendingPoint = PendingPoint(
                    kind: .route,
                    element: elementName,
                    value: point(from: attributeDict)
                )
            case Element.waypoint:
                pendingPoint = PendingPoint(
                    kind: .waypoint,
                    element: elementName,
                    value: point(from: attributeDict)
                )
            default:
                break
            }
        }

        func parser(
            _ parser: XMLParser,
            foundCharacters string: String
        ) {
            text.append(string)
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard let string = String(bytes: CDATABlock, encoding: .utf8) else {
                return
            }
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
            path.removeLast()
            text = ""
        }

        private func updatePendingPoint(
            element: String,
            value: String
        ) {
            guard var point = pendingPoint,
                  path.dropLast().last == point.element else {
                return
            }
            switch element {
            case Element.elevation:
                point.value.elevation = Double(value)
            case Element.time:
                point.value.time = date(from: value)
            default:
                return
            }
            pendingPoint = point
        }

        private func apply(value: String, for element: String) {
            switch element {
            case Element.name where isDirectChild(of: Element.metadata):
                document.metadataName = value
            case Element.description where isDirectChild(of: Element.metadata):
                document.metadataDescription = value
            case Element.name where isMetadataAuthorChild:
                document.metadataAuthor = value
            case Element.keywords where isDirectChild(of: Element.metadata):
                document.metadataKeywords = value
            case Element.time where isDirectChild(of: Element.metadata):
                document.metadataTime = date(from: value)
            case Element.name where isFirstTrackChild:
                document.firstTrackName = value
            case Element.description where isFirstTrackChild:
                document.firstTrackDescription = value
            case Element.comment where isFirstTrackChild:
                document.firstTrackComment = value
            case Element.trackPoint, Element.routePoint, Element.waypoint:
                finishPoint(element)
            default:
                break
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

        private func finishPoint(_ element: String) {
            guard let point = pendingPoint, point.element == element else {
                return
            }
            switch point.kind {
            case .track:
                document.trackPoints.append(point.value)
            case .route:
                document.routePoints.append(point.value)
            case .waypoint:
                document.waypoints.append(point.value)
            }
            pendingPoint = nil
        }

        private func date(from value: String) -> Date? {
            guard !value.isEmpty else { return nil }
            return (try? fractionalDateStrategy.parse(value))
                ?? (try? dateStrategy.parse(value))
        }
    }
}
