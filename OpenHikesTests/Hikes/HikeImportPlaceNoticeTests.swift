//
//  HikeImportPlaceNoticeTests.swift
//  OpenHikesTests
//
//  What the map screen says of a hike kept without every place its file
//  marked (#1076): the multi-track confirmation's words for the same cut,
//  said of a track already imported, with the count as a plural variation.
//

@testable import OpenHikes
import Testing

@Suite("Hike import place notice")
struct HikeImportPlaceNoticeTests {
    @Test("a lone file's notice is the sentence alone, one place of it singular")
    func loneFileSaysTheSentence() {
        let one = HikeImportPlaceNotice(files: [.init(fileName: "ridge.gpx", placesPastLimit: 1)])
        #expect(
            one.message
                == "1 more place lies on this track but wasn’t imported, because one file can bring only so many."
        )
        let many = HikeImportPlaceNotice(files: [.init(fileName: "ridge.gpx", placesPastLimit: 37)])
        #expect(
            many.message
                == "37 more places lie on this track but weren’t imported, because one file can bring only so many."
        )
    }

    /// Several picked files say it once for the lot, a line per file, as the
    /// failure alert names its files.
    @Test("several files' notice names each file on a line of its own")
    func severalFilesAreNamed() {
        let notice = HikeImportPlaceNotice(files: [
            .init(fileName: "a.gpx", placesPastLimit: 1),
            .init(fileName: "b.gpx", placesPastLimit: 4),
        ])
        let reason = "because one file can bring only so many."
        #expect(
            notice.message.split(separator: "\n").map(String.init)
                == [
                    "a.gpx: 1 more place lies on this track but wasn’t imported, \(reason)",
                    "b.gpx: 4 more places lie on this track but weren’t imported, \(reason)",
                ]
        )
    }
}
