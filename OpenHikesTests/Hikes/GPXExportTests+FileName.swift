//
//  GPXExportTests+FileName.swift
//  OpenHikesTests
//
//  The name half of the export. A file name is the one part of a share that
//  the file system gets a veto over: a hike name the app accepts can still be
//  a `NAME_MAX` violation once a date and an extension are on the end of it,
//  and the only check that settles it is a real write. Kept beside the
//  round-trip suite so the bound and the metadata it must not touch are read
//  together.
//

import Foundation
@testable import OpenHikes
import Testing

extension GPXExportTests {

    // MARK: Fixtures

    /// Well inside every file system's limit, and what the exporter cuts a
    /// recognisable name down to.
    static let maximumFileStemLength = 64
    /// `NAME_MAX`: what the file system, not the exporter, will take.
    static let maximumFileNameUTF8Bytes = 255

    /// A title that is short in `Character`s and heavy in bytes — one base
    /// letter carrying `marks` combining accents, repeated. This is what an
    /// imported or pasted name looks like when it breaks the file system, and
    /// ``HikeTitle`` accepts it on purpose, so the exporter has to survive it.
    nonisolated static func combiningTitle(graphemes: Int, marks: Int) -> String {
        String(
            repeating: "e" + String(repeating: "\u{0301}", count: marks),
            count: graphemes
        )
    }

    // MARK: File name

    /// The date has to be the *hike's*, and a pattern that matches any date
    /// cannot tell that from the day the share sheet happened to open — so
    /// the expected day is derived from the fixture's own date through the
    /// calendar, rather than through the exporter's format style.
    @Test("the suggested file name is the hike's name, its date and .gpx")
    func buildsFileName() throws {
        let fileName = GPXExport.fileName(for: track(name: "Thumsee Loop"))

        #expect(fileName == "Thumsee Loop-\(try Self.expectedFileDate()).gpx")
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

    /// The bound that decides whether the write succeeds is bytes, not
    /// characters: 12 graphemes of accented `e` are a name ``HikeTitle``
    /// accepts and 492 UTF-8 bytes the file system will not take.
    @Test("a name short in characters and heavy in bytes is bounded too")
    func boundsFileNameByUTF8Bytes() throws {
        let heavy = Self.combiningTitle(graphemes: 12, marks: 20)
        #expect(heavy.count == 12)
        #expect(heavy.utf8.count > Self.maximumFileNameUTF8Bytes)

        let fileName = GPXExport.fileName(for: track(name: heavy))

        #expect(fileName.utf8.count <= Self.maximumFileNameUTF8Bytes)
        #expect(fileName.hasSuffix("-\(try Self.expectedFileDate()).gpx"))
    }

    /// Cutting to a byte budget by bytes would leave a trailing fragment of
    /// scalars that no longer spells the emoji it came from.
    @Test("the byte bound cuts on grapheme boundaries")
    func truncatesFileNameOnGraphemeBoundaries() throws {
        // Eight UTF-8 bytes each, so 64 of them are far past the budget.
        let flags = String(repeating: "\u{1F1E9}\u{1F1EA}", count: Self.maximumFileStemLength)

        let fileName = GPXExport.fileName(for: track(name: flags))
        let stem = try #require(fileName.split(separator: "-").first)

        #expect(!stem.isEmpty)
        #expect(stem.allSatisfy { $0 == "\u{1F1E9}\u{1F1EA}" })
        #expect(fileName.utf8.count <= Self.maximumFileNameUTF8Bytes)
    }

    /// A single grapheme heavier than the whole budget cannot be cut down to
    /// anything, so the name has to come from somewhere else.
    @Test("a name whose first grapheme alone is too heavy falls back")
    func fallsBackWhenFirstGraphemeIsTooHeavy() {
        let single = Self.combiningTitle(graphemes: 1, marks: 300)

        #expect(GPXExport.fileName(for: track(name: single)).hasPrefix("Hike-"))
    }

    // MARK: Staging

    /// The bound only matters if the file system agrees with it, and only a
    /// real write asks it: a name the exporter is happy with is what failed
    /// with `NSPOSIXErrorDomain 63` before. Each of these is a title
    /// ``HikeTitle`` accepts, so each is a hike a hiker can be holding.
    @Test(
        "a title the app accepts always stages, however it is spelled",
        arguments: [
            ("ASCII", String(repeating: "a", count: HikeTitle.maximumCharacters)),
            ("combining marks", Self.combiningTitle(graphemes: 12, marks: 20)),
            ("emoji", String(repeating: "\u{1F1E9}\u{1F1EA}", count: 64)),
            ("punctuation only", "..."),
        ]
    )
    func stagesEveryAcceptedTitle(spelling: String, title: String) async throws {
        // Guards the fixture, not the exporter: a title this suite invents and
        // the app would reject proves nothing about the app.
        #expect(HikeTitle.bounded(title) == title, "\(spelling) is not a title the app accepts")
        let payload = track(name: title)

        let url = try await GPXExport.writeTemporaryFile(for: payload)
        defer { Self.discardStagedExport(at: url) }

        #expect(url.lastPathComponent.utf8.count <= Self.maximumFileNameUTF8Bytes)
        // The file name is bounded; the hike's own name is not cut with it.
        #expect(try GPXImport.load(from: url).name == title)
    }
}
