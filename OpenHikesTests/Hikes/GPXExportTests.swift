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

    /// The exporter asserts it isn't on the main thread, so a debug build
    /// traps here the day the `@concurrent` hop stops happening — which is
    /// the whole guarantee, since a multi-day route is megabytes of XML with
    /// a file write behind it.
    @Test("the export runs off the main thread and agrees with the writer")
    func exportsOffTheMainThread() async throws {
        let payload = track()

        let url = try await GPXExport.writeTemporaryFile(for: payload)
        defer { Self.discardStagedExport(at: url) }

        #expect(try Data(contentsOf: url) == GPXExport.data(for: payload))
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

    /// The one that decides whether a GPX app appears in the share sheet at
    /// all: the sheet's "Copy to <App>" row matches a *file* against the
    /// document types installed apps declare, so a payload offered only as
    /// bytes reaches Files and Mail and nothing else. Everything else in this
    /// suite passes either way, which is how that shipped.
    @Test("the shared item reaches a receiver as a file, not loose bytes")
    func sharesAFile() async throws {
        let payload = track()
        let provider = NSItemProvider()
        provider.register(HikeGPXFile(track: payload))
        #expect(provider.registeredTypeIdentifiers.contains(Self.gpxIdentifier))

        let delivered = try await Self.receiveFile(
            ofType: Self.gpxIdentifier,
            from: provider
        )

        #expect(delivered.isFile)
        #expect(delivered.name == GPXExport.fileName(for: payload))
        #expect(delivered.contentType == .gpx)
        #expect(delivered.contents == GPXExport.data(for: payload))
    }

    // MARK: Staging

    /// The receiver reads the name off the file's last path component and the
    /// track out of its bytes, so both have to survive the trip to disk.
    @Test("a staged export is a named GPX file a reader can open")
    func stagesNamedFile() async throws {
        let payload = track()

        let url = try await GPXExport.writeTemporaryFile(for: payload)
        defer { Self.discardStagedExport(at: url) }

        #expect(url.lastPathComponent == GPXExport.fileName(for: payload))
        #expect(try url.resourceValues(forKeys: [.contentTypeKey]).contentType == .gpx)
        #expect(try GPXImport.load(from: url).route.count == payload.route.count)
    }

    /// Staged inside the app's own directory, which is the only place
    /// ``GPXExport/purgeStagedExports(in:before:)`` looks — a file written
    /// anywhere else under `tmp` would outlive every share that could clean
    /// it up.
    @Test("a staged export sits in the directory the purge sweeps")
    func stagesInsideTheSweptDirectory() async throws {
        let url = try await GPXExport.writeTemporaryFile(for: track())
        defer { Self.discardStagedExport(at: url) }

        let parent = url.deletingLastPathComponent().deletingLastPathComponent()

        #expect(parent.standardizedFileURL == GPXExport.stagingDirectory.standardizedFileURL)
    }

    /// Two exports of one hike carry the same file name, so each needs a
    /// directory of its own: sharing one would leave the second either
    /// overwriting the first or renamed to `…-1.gpx` on the way out.
    @Test("exporting the same hike twice stages two files under one name")
    func stagesRepeatedExportsSeparately() async throws {
        let payload = track()

        let first = try await GPXExport.writeTemporaryFile(for: payload)
        let second = try await GPXExport.writeTemporaryFile(for: payload)
        defer {
            Self.discardStagedExport(at: first)
            Self.discardStagedExport(at: second)
        }

        #expect(first != second)
        #expect(first.lastPathComponent == second.lastPathComponent)
        // And the second export's purge must not take the first one's file
        // with it — a share still copying is exactly the file at risk.
        #expect(FileManager.default.fileExists(atPath: first.path))
    }

    @Test("the purge takes exports older than the cutoff and leaves the rest")
    func purgesOnlyStaleStagedExports() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "purge-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cutoff = Date.now.addingTimeInterval(-60)
        let stale = try Self.stageDirectory(
            named: "stale",
            in: directory,
            modified: cutoff.addingTimeInterval(-60)
        )
        let fresh = try Self.stageDirectory(named: "fresh", in: directory)

        GPXExport.purgeStagedExports(in: directory, before: cutoff)

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    /// A missing directory is the state before the first share of the run,
    /// and every share starts by sweeping — so this is the common case, not
    /// an edge one, and it must not throw its way out of an export.
    @Test("purging a directory that was never created does nothing")
    func purgesMissingDirectoryQuietly() {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "absent-\(UUID().uuidString)", directoryHint: .isDirectory)

        GPXExport.purgeStagedExports(in: missing, before: .now)

        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }
}

// MARK: - Delivery

private extension GPXExportTests {
    /// What a receiving app ends up holding.
    struct DeliveredFile: Sendable {
        var name: String
        var contentType: UTType?
        var contents: Data
        /// Whether what arrived was a file at all, rather than bytes the
        /// system spooled to disk to satisfy the request.
        var isFile: Bool
    }

    struct NothingDelivered: Error {}

    /// Takes delivery the way a receiving app does.
    ///
    /// `NSItemProvider` lends the URL only for the duration of the callback
    /// and deletes the file behind it on return, so everything asserted on is
    /// read inside. `loadItem` is asked first because it's the half that can
    /// tell the two representations apart: a file-backed item comes back as a
    /// `URL`, a data-backed one as `Data`, while `loadFileRepresentation`
    /// obligingly spools the latter to a temporary file and hides the
    /// difference.
    static func receiveFile(
        ofType identifier: String,
        from provider: NSItemProvider
    ) async throws -> DeliveredFile {
        let item = try? await provider.loadItem(forTypeIdentifier: identifier)
        let isFile = item is URL
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(
                forTypeIdentifier: identifier
            ) { url, error in
                continuation.resume(with: Result {
                    if let error { throw error }
                    guard let url else { throw NothingDelivered() }
                    return DeliveredFile(
                        name: url.lastPathComponent,
                        contentType: try url.resourceValues(
                            forKeys: [.contentTypeKey]
                        ).contentType,
                        contents: try Data(contentsOf: url),
                        isFile: isFile
                    )
                })
            }
        }
    }

    /// A staged export and the directory it was given to itself.
    static func discardStagedExport(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// A staged export as the purge sees one: a directory holding a file,
    /// dated after it's filled so the write doesn't reset the date.
    static func stageDirectory(
        named name: String,
        in parent: URL,
        modified: Date? = nil
    ) throws -> URL {
        let directory = parent.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("<gpx/>".utf8).write(
            to: directory.appending(path: "Hike.gpx", directoryHint: .notDirectory)
        )
        guard let modified else { return directory }
        try FileManager.default.setAttributes(
            [.modificationDate: modified],
            ofItemAtPath: directory.path
        )
        return directory
    }
}
