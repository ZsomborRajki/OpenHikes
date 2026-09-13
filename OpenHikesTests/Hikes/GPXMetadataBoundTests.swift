//
//  GPXMetadataBoundTests.swift
//  OpenHikesTests
//
//  The bound on the three fields a GPX file carries beside its name.
//
//  `HikeTitleBoundTests` is the sibling of this file and makes the same
//  argument about `<name>`: a file that arrived through `Documents/Inbox` was
//  chosen by its sender and read without anybody opening it, so "nobody would
//  type that" bounds nothing. The description, the author and the keywords had
//  no bound at all, and they reach further than the title does — all three are
//  mirrored SwiftData columns, and ``CommunityPublisher`` copies the
//  description onto a record in the **public** database.
//
//  So these go through the real parser rather than handing ``BoundedText`` a
//  string, for the reason the title's do: what is worth asserting is that an
//  oversized file produces a bounded field, end to end, rather than that one
//  function in the middle behaves.
//
//  Unlike the title, these three are bounded at the point the importer reads
//  them rather than a step later, so there is no unbounded intermediate value
//  for a test to catch the parser handing through — which is the shape the
//  rule asks for and is why `HikeTitleBoundTests` needs an assertion this
//  file does not.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("GPX metadata bounds")
struct GPXMetadataBoundTests {
    private func gpxFile(_ xml: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-\(UUID().uuidString)")
            .appendingPathExtension("gpx")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func track(
        description: String = "",
        author: String = "",
        keywords: String = ""
    ) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="OpenHikesTests" xmlns="http://www.topografix.com/GPX/1/1">
            <metadata>
            <author><name>\(author)</name></author>
            <keywords>\(keywords)</keywords>
            </metadata>
            <trk>
            <name>Thumsee Loop</name>
            <desc>\(description)</desc>
            <trkseg>
                <trkpt lat="47.6300" lon="12.8600"/>
                <trkpt lat="47.6310" lon="12.8600"/>
            </trkseg>
            </trk>
        </gpx>
        """
    }

    /// The field this bound is really for.
    ///
    /// A `<desc>` can spend the whole of the importer's 32 MB file budget on
    /// its own, and what it lands in is a column CloudKit mirrors — where a
    /// `CKRecord`'s non-asset payload is capped at 1 MB, so a row past that
    /// stops mirroring for good with only a sync diagnostic to say so. So the
    /// assertion is on the length *and* on the prefix: a bound that returned
    /// the right number of the wrong characters would be a truncation nobody
    /// could read.
    @Test("an unbounded GPX description is bounded before it is stored")
    func descriptionIsBounded() throws {
        let sent = String(repeating: "d", count: TextBound.notes.characters * 20)
        let url = try gpxFile(Self.track(description: sent))

        let parsed = try GPXImport.load(from: url)

        #expect(
            parsed.trackDescription?.count == TextBound.notes.characters,
            "a description past the bound is cut to it"
        )
        #expect(sent.hasPrefix(try #require(parsed.trackDescription)))
    }

    /// A person's name, which is shown as a credit and has a tighter bound
    /// than prose does.
    @Test("an unbounded GPX author is bounded before it is stored")
    func authorIsBounded() throws {
        let sent = String(repeating: "a", count: TextBound.credit.characters * 20)
        let url = try gpxFile(Self.track(author: sent))

        let parsed = try GPXImport.load(from: url)

        #expect(parsed.author?.count == TextBound.credit.characters)
    }

    /// A comma-separated list rather than a sentence, and bounded as one.
    @Test("unbounded GPX keywords are bounded before they are stored")
    func keywordsAreBounded() throws {
        let sent = String(repeating: "k", count: TextBound.keywords.characters * 20)
        let url = try gpxFile(Self.track(keywords: sent))

        let parsed = try GPXImport.load(from: url)

        #expect(parsed.keywords?.count == TextBound.keywords.characters)
    }

    /// An ordinary file keeps all three whole. A bound that a real GPX can
    /// feel is a bug rather than a limit.
    @Test("metadata that fits arrives unchanged")
    func ordinaryMetadataSurvives() throws {
        let url = try gpxFile(
            Self.track(
                description: "Steep after the saddle; the spring is dry in August.",
                author: "Anna Kovacs",
                keywords: "ridge, alpine, loop"
            )
        )

        let parsed = try GPXImport.load(from: url)

        #expect(parsed.trackDescription == "Steep after the saddle; the spring is dry in August.")
        #expect(parsed.author == "Anna Kovacs")
        #expect(parsed.keywords == "ridge, alpine, loop")
    }

    /// Empty elements are absent rather than blank, which is what the rest of
    /// the app already assumes: ``Hike/trackDescription`` is optional because
    /// a hike without one has nothing to show, not an empty thing to show.
    @Test("blank metadata is no metadata")
    func blankMetadataIsAbsent() throws {
        let url = try gpxFile(Self.track(description: "   ", author: "\n", keywords: ""))

        let parsed = try GPXImport.load(from: url)

        #expect(parsed.trackDescription == nil)
        #expect(parsed.author == nil)
        #expect(parsed.keywords == nil)
    }
}
