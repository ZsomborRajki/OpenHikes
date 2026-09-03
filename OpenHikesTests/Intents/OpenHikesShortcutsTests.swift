//
//  OpenHikesShortcutsTests.swift
//  OpenHikesTests
//
//  The one thing about the shortcuts list that can be checked from here.
//
//  `AppShortcutPhrase` exposes no way to read its text back, so the phrases
//  themselves — including the `\(.applicationName)` every one of them has to
//  carry — are not assertable and are enforced by the AppIntents metadata
//  build step instead. The count is not: the system takes the first ten and
//  drops the rest in silence, so an eleventh shortcut would ship as a feature
//  that simply never appears.
//

import AppIntents
@testable import OpenHikes
import Testing

@Suite("OpenHikes shortcuts")
struct OpenHikesShortcutsTests {
    /// The system's ceiling on shortcuts offered per app.
    private static let systemCeiling = 10

    @Test("the offered shortcuts stay inside the system's ceiling")
    func shortcutsFitTheSystemCeiling() {
        #expect(OpenHikesShortcuts.appShortcuts.count <= Self.systemCeiling)
    }

    @Test("every intent in the folder is reachable by voice")
    func everyIntentIsOffered() {
        // Seven intents, seven shortcuts. An intent added without a phrase is
        // reachable only by a walker who goes and builds a shortcut for it by
        // hand, which is the opposite of the point.
        #expect(OpenHikesShortcuts.appShortcuts.count == 7)
    }
}
