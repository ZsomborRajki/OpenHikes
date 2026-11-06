//
//  OfflineDownloadPercentTests.swift
//  OpenHikesTests
//
//  The figure the hike screen's download tile draws and VoiceOver reads,
//  ``OfflineTileDownloader/percent(saved:of:locale:)``. The tile itself is
//  body code the unit suites never evaluate, so this is where its rounding
//  and its formatting are held.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Offline download percentage")
struct OfflineDownloadPercentTests {
    private static let english = Locale(identifier: "en_US")
    private static let german = Locale(identifier: "de_DE")

    /// Drawn "99%" and spoken "100%" before, because the text truncated and
    /// the accessibility value rounded.
    @Test("a download says 100% only once its last tile is saved")
    func roundsDown() {
        #expect(OfflineTileDownloader.percent(saved: 249, of: 250, locale: Self.english) == "99%")
        #expect(OfflineTileDownloader.percent(saved: 199, of: 200, locale: Self.english) == "99%")
        #expect(OfflineTileDownloader.percent(saved: 250, of: 250, locale: Self.english) == "100%")
    }

    /// 0.29 × 100 is 28.999999999999996, which the tile truncated to "28%".
    @Test("an exact share of the tiles is the percentage it is")
    func countsWholeTiles() {
        for total in [100, 200, 300, 1000] {
            for percent in 0...100 {
                let saved = total * percent / 100
                #expect(
                    OfflineTileDownloader.percent(saved: saved, of: total, locale: Self.english) == "\(percent)%",
                    "\(saved) of \(total)"
                )
            }
        }
    }

    /// The tile wrote "62%" in German, where the walk's and the widget's
    /// percentages beside it say "62 %".
    @Test("a German percentage is spaced the way German writes one")
    func germanPercentage() {
        #expect(OfflineTileDownloader.percent(saved: 62, of: 100, locale: Self.german) == "62\u{00A0}%")
    }

    /// Planning has not counted the tiles yet, and a count past the plan
    /// still says no more than all of it.
    @Test("nothing to count is none, and more than the plan is all of it")
    func edges() {
        #expect(OfflineTileDownloader.percent(saved: 0, of: 0, locale: Self.english) == "0%")
        #expect(OfflineTileDownloader.percent(saved: 3, of: 2, locale: Self.english) == "100%")
    }
}
