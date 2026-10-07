//
//  GPXExportTests+ShareCardFileName.swift
//  OpenHikesTests
//
//  What a walk's share card is called on its way to a share sheet: the hike
//  and the day it was walked, sanitised and bounded the way every other name
//  this app hands out is.
//

import Foundation
@testable import OpenHikes
import Testing

extension GPXExportTests {
    @Test("a share card is named after its hike and the day of the walk")
    func namesAShareCardAfterItsWalk() {
        // 2026-06-12 10:00 UTC, which is the 12th in every zone from UTC-10
        // to UTC+13 — the name is dated in local time.
        let walkedOn = Date(timeIntervalSince1970: 1_781_258_400)

        let name = GPXExport.shareCardFileName(hikeTitle: "Thumsee Loop", walkedOn: walkedOn)

        #expect(name == "Thumsee Loop-2026-06-12.jpeg")
    }

    @Test("a share card's name is sanitised and bounded like the rest")
    func boundsAndSanitizesTheShareCardName() {
        let long = "Up/Down: " + String(repeating: "a", count: Self.maximumFileNameUTF8Bytes * 2)

        let name = GPXExport.shareCardFileName(hikeTitle: long, walkedOn: .now)

        #expect(name.utf8.count <= Self.maximumFileNameUTF8Bytes)
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
        #expect(name.hasSuffix(".jpeg"))
    }
}
