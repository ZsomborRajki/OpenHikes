//
//  GPXExportTests+PhotoFileName.swift
//  OpenHikesTests
//
//  What one photograph is called on its way out of the gallery.
//
//  It shares the sanitising and the byte bound with the `.gpx` and the archive,
//  and that sharing is the thing worth pinning: a title that makes a bad file
//  name has to make a bad *photograph* name in exactly the same way, or a hike
//  a hiker can actually create is a share that fails at the file system with
//  `NSPOSIXErrorDomain 63` — the failure `GPXExportTests+FileName` exists
//  because of.
//
//  Numbered rather than dated, and that is asserted here too: a walk's
//  photographs all carry its date, so dating them would send a dozen files to
//  one name.
//

import Foundation
@testable import OpenHikes
import Testing

extension GPXExportTests {
    @Test("a photograph is named after its hike and its place in the gallery")
    func namesAPhotographAfterItsHike() {
        let name = GPXExport.photoFileName(
            hikeTitle: "Thumsee Loop",
            position: 3,
            pathExtension: "jpeg"
        )

        #expect(name == "Thumsee Loop-3.jpeg")
    }

    /// The extension is the stored file's, not a constant: a capture is JPEG
    /// and an import is whatever the library held.
    @Test("the stored extension is the one that travels")
    func keepsTheStoredExtension() {
        let name = GPXExport.photoFileName(
            hikeTitle: "Thumsee Loop",
            position: 1,
            pathExtension: "heic"
        )

        #expect(name.hasSuffix(".heic"))
    }

    /// Two pictures of one walk must not arrive under one name, which is the
    /// whole reason the position is in it.
    @Test("two photographs of one hike are named apart")
    func numbersPhotographsApart() {
        let first = GPXExport.photoFileName(hikeTitle: "Ridge", position: 1, pathExtension: "jpeg")
        let second = GPXExport.photoFileName(hikeTitle: "Ridge", position: 2, pathExtension: "jpeg")

        #expect(first != second)
    }

    @Test("characters a file system won't take become hyphens here too")
    func sanitizesThePhotographName() {
        let name = GPXExport.photoFileName(
            hikeTitle: "Up/Down: the \"best\" bit",
            position: 1,
            pathExtension: "jpeg"
        )

        #expect(!name.dropLast(".jpeg".count).contains("/"))
        #expect(!name.contains(":"))
    }

    /// The bound is the whole name, extension and number included — the thing
    /// a separate entry point is most likely to get wrong by budgeting only
    /// for the stem.
    @Test("a very long title is bounded with its extension counted")
    func boundsThePhotographNameIncludingItsExtension() {
        let long = String(repeating: "a", count: Self.maximumFileNameUTF8Bytes * 2)

        let name = GPXExport.photoFileName(
            hikeTitle: long,
            position: 12,
            pathExtension: "jpeg"
        )

        #expect(name.utf8.count <= Self.maximumFileNameUTF8Bytes)
        #expect(name.hasSuffix("-12.jpeg"))
    }

    /// Every title the app accepts, for the reason the `.gpx` suite runs the
    /// same list: a spelling that cannot be named is a share a hiker cannot make.
    @Test(
        "a title the app accepts always names a photograph",
        arguments: [
            ("ASCII", String(repeating: "a", count: HikeTitle.maximumCharacters)),
            ("combining marks", Self.combiningTitle(graphemes: 12, marks: 20)),
            ("emoji", String(repeating: "\u{1F1E9}\u{1F1EA}", count: 64)),
            ("punctuation only", "..."),
        ]
    )
    func namesAPhotographForEveryAcceptedTitle(spelling: String, title: String) {
        #expect(HikeTitle.bounded(title) == title, "\(spelling) is not a title the app accepts")

        let name = GPXExport.photoFileName(hikeTitle: title, position: 1, pathExtension: "jpeg")

        #expect(name.utf8.count <= Self.maximumFileNameUTF8Bytes)
        #expect(!name.hasPrefix("."), "\(spelling) named a hidden file")
        #expect(name.hasSuffix(".jpeg"))
    }
}
