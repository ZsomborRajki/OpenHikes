//
//  HikeTitleBoundTests.swift
//  OpenHikesTests
//
//  The bound on a hike's name, at the entry point that nobody looked at.
//
//  The rename field is covered where renaming is — `HikeRenameTests` drives
//  ``HikeTitle/bounded(_:)`` through the same call the view makes. What is
//  here is the other half, and the half the bound exists for: a GPX `<name>`
//  is written by whoever sent the file, and a file that arrived through
//  `Documents/Inbox` was read without anybody opening it.
//
//  So these go through the real parser rather than handing ``HikeTitle`` a
//  string directly. What is being asserted is that an unbounded name survives
//  parsing exactly as it was written — the parser is not the thing that
//  bounds it, and a test that assumed otherwise would pass while the app
//  stored megabytes — and that the importer's own composition cuts it.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Hike title bound")
struct HikeTitleBoundTests {
    private func gpxFile(_ xml: String, name: String = "title") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
            .appendingPathExtension("gpx")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func track(named name: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="OpenHikesTests" xmlns="http://www.topografix.com/GPX/1/1">
            <trk>
            <name>\(name)</name>
            <trkseg>
                <trkpt lat="47.6300" lon="12.8600"/>
                <trkpt lat="47.6310" lon="12.8600"/>
            </trkseg>
            </trk>
        </gpx>
        """
    }

    /// The importer's title, from a file whose `<name>` is far past the bound.
    ///
    /// Both halves are asserted deliberately: that the parser hands the name
    /// through untouched, because that is what makes the bound necessary, and
    /// that the title the hike is actually built with is bounded, because that
    /// is what makes it sufficient.
    @Test("an unbounded GPX name is bounded before it becomes a title")
    func importedTrackNameIsBounded() throws {
        let sent = String(repeating: "L", count: HikeTitle.maximumCharacters * 40)
        let url = try gpxFile(Self.track(named: sent))

        let parsed = try GPXImport.load(from: url)

        #expect(
            parsed.name == sent,
            "the parser is not what bounds the name, and this test is void if it becomes so"
        )
        let title = HikeTitle.imported(trackName: parsed.name, fileURL: url)
        #expect(title.count == HikeTitle.maximumCharacters)
        #expect(sent.hasPrefix(title))
    }

    /// A file with no `<name>` is titled after itself — and the filename is
    /// the sender's text too, so it takes the same bound.
    @Test("a nameless file falls back to a bounded filename")
    func importedFilenameIsBounded() {
        let stem = String(repeating: "n", count: HikeTitle.maximumCharacters * 3)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(stem)
            .appendingPathExtension("gpx")

        #expect(
            HikeTitle.imported(trackName: nil, fileURL: url).count
                == HikeTitle.maximumCharacters
        )
        // A blank `<name>` is not a name, and falls back the same way.
        #expect(HikeTitle.imported(trackName: "  \n ", fileURL: url).count
            == HikeTitle.maximumCharacters)
    }

    /// An ordinary track keeps its own name, whole. The bound has to be
    /// invisible to every real file or it is a bug rather than a limit.
    @Test("a name that fits arrives unchanged")
    func ordinaryTrackNameSurvives() throws {
        let url = try gpxFile(Self.track(named: "Thumsee Loop"))

        let parsed = try GPXImport.load(from: url)

        #expect(HikeTitle.imported(trackName: parsed.name, fileURL: url) == "Thumsee Loop")
    }

    /// The cut lands between characters, not inside one.
    ///
    /// `prefix` counts `Character`s, so this holds by construction — but the
    /// obvious "fix" if the bound ever needs to be expressed in bytes is a
    /// `utf8` prefix, which does not, and would store a name ending in
    /// unpaired scalars that render as a replacement glyph.
    @Test("the cut does not split a multi-scalar character")
    func boundingKeepsGraphemesWhole() throws {
        // A tag-sequence flag: one `Character`, seven scalars, 28 bytes. So
        // this is also the case where the byte bound bites first — the
        // character bound would allow 128 of these and 3.5 kilobytes with it.
        let flag = "🏴󠁧󠁢󠁳󠁣󠁴󠁿"
        let name = String(repeating: flag, count: HikeTitle.maximumCharacters)

        let bounded = try #require(HikeTitle.bounded(name))

        #expect(bounded.utf8.count <= HikeTitle.maximumUTF8Bytes)
        #expect(!bounded.isEmpty)
        // Whole flags, and only whole flags.
        #expect(bounded == String(repeating: flag, count: bounded.count))
    }

    /// What the bound is worth in bytes, which is the unit the Live Activity
    /// payload is actually rationed in.
    ///
    /// The shared package's `HikeActivityTests` defends a 128-character title
    /// of four-byte emoji — 498 bytes — and it cannot import this target to
    /// check that the app agrees. This is that check from the app's side: the
    /// heaviest name a walker can produce is the one that test measured.
    @Test("the emoji worst case is bounded to what the payload defends")
    func boundedTitleFitsThePayloadWorstCase() throws {
        let name = String(repeating: "🏔", count: HikeTitle.maximumCharacters * 2)

        let bounded = try #require(HikeTitle.bounded(name))

        #expect(bounded.count == HikeTitle.maximumCharacters)
        #expect(bounded.utf8.count == HikeTitle.maximumUTF8Bytes)
    }

    /// The case the character bound alone does not catch, and the reason
    /// ``HikeTitle/maximumUTF8Bytes`` exists.
    ///
    /// One base letter plus ten thousand combining marks is a single
    /// `Character`. A name made of 128 of them passes any character count
    /// while weighing megabytes — and it is not a thing anybody types, which
    /// is the point: it is a thing a file contains.
    @Test("a name of pathologically heavy characters is bounded by bytes")
    func combiningMarksCannotEvadeTheBound() throws {
        // 101 bytes to one character: heavy enough that the byte bound decides
        // the answer, light enough that something survives it.
        let heavy = "a" + String(repeating: "\u{0301}", count: 50)
        try #require(heavy.count == 1, "the fixture is void if this is not one character")
        let name = String(repeating: heavy, count: HikeTitle.maximumCharacters)

        let bounded = try #require(HikeTitle.bounded(name))

        #expect(bounded.utf8.count <= HikeTitle.maximumUTF8Bytes)
        #expect(bounded.count < HikeTitle.maximumCharacters, "the byte bound is what cut this")
        // Cut between characters, not through one.
        #expect(bounded == String(repeating: heavy, count: bounded.count))
    }

    /// A single character too heavy for the budget leaves nothing, and nothing
    /// is `nil` rather than an empty name — so an import falls back to the
    /// filename instead of building a hike with a blank title.
    @Test("a name that is one oversized character is no name")
    func oneOversizedCharacterIsNil() {
        let heavy = "a" + String(repeating: "\u{0301}", count: HikeTitle.maximumUTF8Bytes)

        #expect(HikeTitle.bounded(heavy) == nil)
        #expect(
            HikeTitle.imported(
                trackName: heavy,
                fileURL: URL(fileURLWithPath: "/tmp/Fallback.gpx")
            ) == "Fallback"
        )
    }

    /// Nothing left after trimming is not a name. This is the case the rename
    /// field relies on to clear a custom name — see ``Hike/displayTitle``.
    @Test("a blank name is no name at all")
    func blankNamesAreNil() {
        #expect(HikeTitle.bounded(nil) == nil)
        #expect(HikeTitle.bounded("") == nil)
        #expect(HikeTitle.bounded("  \t\n ") == nil)
    }
}
