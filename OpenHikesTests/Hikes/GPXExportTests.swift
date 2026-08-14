//
//  GPXExportTests.swift
//  OpenHikesTests
//
//  Export is import's mirror, and the only check that means anything is
//  whether a real GPX reader can read what we wrote — so most of this suite
//  writes a document, hands it to ``GPXImport``, and asks for it back. The
//  rest guards the things a round trip can't see: the schema's fixed element
//  order, markup that must survive as text rather than reopen the document,
//  and a suggested file name a file system will actually accept.
//

import CoreTransferable
import Foundation
@testable import OpenHikes
import Testing
import UniformTypeIdentifiers

@Suite("GPX export")
struct GPXExportTests {
    // MARK: Fixtures

    private static let date = Date(timeIntervalSince1970: 1_780_000_000)
    private static let gpxIdentifier = "com.topografix.gpx"
    private static let maximumFileStemLength = 64

    private func track(
        name: String = "Thumsee Loop",
        trackDescription: String? = "A lakeside loop.",
        author: String? = "Ada Lovelace",
        keywords: String? = "hiking, bavaria",
        route: [RouteCoordinate] = Fixture.ridgeRoute
    ) -> GPXExport.Track {
        GPXExport.Track(
            name: name,
            trackDescription: trackDescription,
            author: author,
            keywords: keywords,
            date: Self.date,
            route: route
        )
    }

    /// Writes the exported document to a file and reads it back the way a
    /// picked document is read. Deliberately goes through ``GPXImport`` rather
    /// than asserting on strings: the importer is a real GPX reader written
    /// against other people's files, not a mirror of this writer, so agreeing
    /// with it is evidence the file travels.
    private func reimported(_ track: GPXExport.Track) throws -> GPXImport.Track {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(UUID().uuidString)")
            .appendingPathExtension("gpx")
        try GPXExport.data(for: track).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        return try GPXImport.load(from: url)
    }

    // MARK: Round trip

    @Test("an exported track re-imports with its metadata intact")
    func roundTripsMetadata() throws {
        let imported = try reimported(track())

        #expect(imported.name == "Thumsee Loop")
        #expect(imported.trackDescription == "A lakeside loop.")
        #expect(imported.author == "Ada Lovelace")
        #expect(imported.keywords == "hiking, bavaria")
        #expect(imported.startTime == Self.date)
    }

    @Test("every point comes back with its coordinate, elevation and time")
    func roundTripsPoints() throws {
        let exported = track()
        let imported = try reimported(exported)

        #expect(imported.route.count == exported.route.count)
        for (written, read) in zip(exported.route, imported.route) {
            #expect(read.latitude == written.latitude)
            #expect(read.longitude == written.longitude)
            #expect(read.elevation == written.elevation)
            #expect(read.timestamp == written.timestamp)
        }
    }

    /// Seven decimals is ~1.1 cm, so nothing a GPS produced is lost — but the
    /// rounding is real, and this is the test that would catch it being
    /// tightened or loosened by accident.
    @Test("coordinates keep their precision to seven decimal places")
    func keepsCoordinatePrecision() throws {
        let precise = [
            RouteCoordinate(latitude: 47.1234567, longitude: 12.7654321),
            RouteCoordinate(latitude: 47.1234568, longitude: 12.7654322),
        ]
        let imported = try reimported(track(route: precise))

        #expect(imported.route.map(\.latitude) == precise.map(\.latitude))
        #expect(imported.route.map(\.longitude) == precise.map(\.longitude))
    }

    /// `Double`'s own description reaches for exponent form this close to the
    /// origin, and `xsd:decimal` has no way to express it — a reader that
    /// validates would reject the file, and one that doesn't would read the
    /// point as nowhere.
    @Test("coordinates are written as fixed-point decimals, never in exponent form")
    func writesFixedPointCoordinates() throws {
        let nearOrigin = [
            RouteCoordinate(latitude: 0.00001, longitude: -0.000002),
            RouteCoordinate(latitude: 0.00002, longitude: -0.000003),
        ]
        let xml = GPXExport.xml(for: track(route: nearOrigin))

        #expect(xml.contains(#"lat="0.0000100" lon="-0.0000020""#))
        let imported = try reimported(track(route: nearOrigin))
        #expect(imported.route.map(\.latitude) == nearOrigin.map(\.latitude))
        #expect(imported.route.map(\.longitude) == nearOrigin.map(\.longitude))
    }

    /// Recorded fixes don't land on whole seconds. Writing them without
    /// fractions would round every one of them, silently, on the way out.
    @Test("sub-second fix times survive the round trip")
    func roundTripsFractionalSeconds() throws {
        let stamped = [
            RouteCoordinate(
                latitude: 47.63,
                longitude: 12.86,
                timestamp: Self.date.addingTimeInterval(0.25)
            ),
            RouteCoordinate(
                latitude: 47.64,
                longitude: 12.86,
                timestamp: Self.date.addingTimeInterval(1.75)
            ),
        ]
        let imported = try reimported(track(route: stamped))

        #expect(imported.route.map(\.timestamp) == stamped.map(\.timestamp))
    }

    // MARK: Document shape

    @Test("the file names OpenHikes as its creator")
    func namesItsCreator() {
        #expect(GPXExport.xml(for: track()).contains(#"creator="OpenHikes""#))
    }

    /// GPX 1.1 fixes the order of `metadata`'s children — name, desc, author,
    /// time, keywords — and a schema-validating reader rejects the file if
    /// they arrive in any other. `keywords` after `time` is the one that reads
    /// wrong and is therefore the one that gets "tidied" back.
    @Test("metadata children are written in the order the schema fixes")
    func writesSchemaOrderedMetadata() throws {
        let xml = GPXExport.xml(for: track())
        let name = try #require(xml.range(of: "<name>"))
        let description = try #require(xml.range(of: "<desc>"))
        let author = try #require(xml.range(of: "<author>"))
        let time = try #require(xml.range(of: "<time>"))
        let keywords = try #require(xml.range(of: "<keywords>"))

        #expect(name.lowerBound < description.lowerBound)
        #expect(description.lowerBound < author.lowerBound)
        #expect(author.lowerBound < time.lowerBound)
        #expect(time.lowerBound < keywords.lowerBound)
    }

    @Test("absent metadata is omitted rather than written as empty elements")
    func omitsAbsentMetadata() throws {
        let bare = track(trackDescription: nil, author: nil, keywords: nil)
        let xml = GPXExport.xml(for: bare)

        #expect(!xml.contains("<desc>"))
        #expect(!xml.contains("<author>"))
        #expect(!xml.contains("<keywords>"))
        #expect(try reimported(bare).name == "Thumsee Loop")
    }

    /// On a route imported from a planner every point is bare, and the pair of
    /// tags this saves is most of the file.
    @Test("a point with no elevation or time closes on its own tag")
    func writesBarePointsCompactly() {
        let bare = [
            RouteCoordinate(latitude: 47.63, longitude: 12.86),
            RouteCoordinate(latitude: 47.64, longitude: 12.86),
        ]
        let xml = GPXExport.xml(for: track(route: bare))

        #expect(xml.contains(#"<trkpt lat="47.6300000" lon="12.8600000"/>"#))
        #expect(!xml.contains("<ele>"))
        #expect(!xml.contains("</trkpt>"))
    }

    /// A recording draft has no points until Stop finalizes it. The Share
    /// button is disabled for one, but the writer must still not emit
    /// something no parser will open.
    @Test("an empty route still produces a well-formed document")
    func writesWellFormedEmptyRoute() {
        let xml = GPXExport.xml(for: track(route: []))

        #expect(xml.contains("<trkseg>"))
        #expect(xml.contains("</trkseg>"))
        #expect(XMLParser(data: Data(xml.utf8)).parse())
    }

    // MARK: Escaping

    @Test("markup in a hike's name survives as text")
    func escapesMarkup() throws {
        let hostile = #"Ben & Jerry's <Ridge> "North""#

        #expect(try reimported(track(name: hostile)).name == hostile)
    }

    /// XML 1.0 can't carry these at all — not even as numeric references — so
    /// a name that picked one up from someone else's file has to lose it
    /// rather than produce a document nothing will read back.
    @Test("control characters XML can't represent are dropped, not written")
    func dropsUnrepresentableControlCharacters() throws {
        let name = "Ridge\u{0}Loop\u{7}"

        #expect(try reimported(track(name: name)).name == "RidgeLoop")
    }

    // MARK: File name

    @Test("the suggested file name is the hike's name, its date and .gpx")
    func buildsFileName() {
        let fileName = GPXExport.fileName(for: track(name: "Thumsee Loop"))

        #expect(fileName.wholeMatch(of: /Thumsee Loop-\d{4}-\d{2}-\d{2}\.gpx/) != nil)
    }

    /// Hyphens rather than deletions, so two hikes whose names differ only in
    /// punctuation still export to different files.
    @Test("characters a file system won't take become hyphens")
    func sanitizesFileName() {
        let fileName = GPXExport.fileName(for: track(name: #"Ridge/Loop: 2\3"#))

        #expect(fileName.hasPrefix("Ridge-Loop- 2-3-"))
    }

    /// A leading dot would hide the exported file on every Unix-derived system
    /// the share sheet can reach.
    @Test("a leading dot is trimmed rather than exported as a hidden file")
    func trimsLeadingDot() {
        #expect(GPXExport.fileName(for: track(name: ".hidden")).hasPrefix("hidden-"))
    }

    @Test("a name with nothing usable left in it falls back")
    func fallsBackWhenNameIsUnusable() {
        #expect(GPXExport.fileName(for: track(name: "")).hasPrefix("Hike-"))
        #expect(GPXExport.fileName(for: track(name: "   ")).hasPrefix("Hike-"))
    }

    @Test("a very long name is truncated to a length every file system takes")
    func truncatesLongFileName() {
        let long = String(repeating: "a", count: Self.maximumFileStemLength * 3)
        let fileName = GPXExport.fileName(for: track(name: long))

        #expect(fileName.prefix { $0 == "a" }.count == Self.maximumFileStemLength)
    }

    // MARK: Sharing

    /// The Share button reads the name the walker sees, so renaming a hike
    /// renames the file it shares.
    @MainActor
    @Test("the payload takes the hike's display title, not its imported one")
    func payloadUsesDisplayTitle() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, title: "Imported Track")
        hike.customName = "Sunrise Walk"

        let payload = GPXExport.Track(hike: hike)

        #expect(payload.name == "Sunrise Walk")
        #expect(payload.route == hike.route)
        #expect(payload.date == hike.date)
        #expect(GPXExport.fileName(for: payload).hasPrefix("Sunrise Walk-"))
    }

    /// The serializer asserts it isn't on the main thread, so a debug build
    /// traps here the day the `@concurrent` hop stops happening — which is
    /// the whole guarantee, since a multi-day route is megabytes of XML.
    @Test("serialization runs off the main thread and agrees with the writer")
    func serializesOffTheMainThread() async {
        let payload = track()

        let data = await GPXExport.dataOffMain(for: payload)

        #expect(data == GPXExport.data(for: payload))
    }

    /// Without the declared type the share sheet hands over an untyped blob,
    /// and the receiving app has nothing to match against — see
    /// ``GPXDocumentTypeTests`` for the Info.plist half of this.
    @Test("the shared item is offered as the declared GPX type")
    func sharesAsDeclaredGPXType() async throws {
        let payload = track()
        let file = HikeGPXFile(track: payload)

        #expect(UTType.gpx.identifier == Self.gpxIdentifier)
        #expect(!UTType.gpx.isDynamic)
        #expect(file.exportedContentTypes().contains(.gpx))
        #expect(try await file.exported(as: .gpx) == GPXExport.data(for: payload))
    }
}
