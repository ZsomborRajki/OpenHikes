//
//  RecordingIntentCategoryTests.swift
//  OpenHikesTests
//
//  The heading Shortcuts files the recording actions under.
//
//  English says "Recording" for that heading and for the status badge on a
//  hike being recorded, and Spanish does not: the badge says what is
//  happening now, «Grabando», and the heading names the activity,
//  «Grabación». So the heading reads a key of its own, and every recording
//  action has to name the same one, or Shortcuts files them under two.
//

import AppIntents
import Foundation
@testable import OpenHikes
import Testing

@Suite("Recording intent category")
struct RecordingIntentCategoryTests {
    /// Every action Shortcuts lists under the recording heading.
    private static let descriptions = [
        StartHikeRecordingIntent.description,
        PauseHikeRecordingIntent.description,
        ResumeHikeRecordingIntent.description,
        StopHikeRecordingIntent.description,
        CurrentHikeProgressIntent.description,
        RecordAlongTrailIntent.description,
    ]

    @Test("every recording action is filed under the heading's own key")
    func recordingActionsShareOneCategory() {
        let keys = Set(Self.descriptions.map { $0.categoryName?.key })
        #expect(keys == ["intent.category.recording"], "the recording actions are filed under \(keys)")
    }

    @Test("Spanish names the heading for the activity, not with the badge's word")
    func spanishHeadingIsNotTheBadge() throws {
        let spanish = Locale(identifier: "es")
        var heading = try #require(StartHikeRecordingIntent.description.categoryName)
        heading.locale = spanish
        var badge = LocalizedStringResource("Recording")
        badge.locale = spanish
        #expect(String(localized: heading) != String(localized: badge))
    }
}
