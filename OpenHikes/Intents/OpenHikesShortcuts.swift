//
//  OpenHikesShortcuts.swift
//  OpenHikes
//
//  What Siri and Spotlight offer without the hiker building a shortcut first.
//
//  Every phrase has to carry `\(.applicationName)` — the system will not
//  register one that doesn't, and it fails by simply never matching rather
//  than by complaining. Several spellings per intent because the ones people
//  actually say are not the ones an intent is titled: "start a hike" and
//  "record a hike" are the same request.
//
//  Ten is the system's ceiling on shortcuts per app, and **all ten are now
//  spent**: the whole recording loop, the three questions, and the three that
//  take a parameter — `HikeDurationIntent`, `OpenHikeIntent` and
//  `RecordAlongTrailIntent`, which is what ``HikeEntity`` was built for.
//
//  There is no room left, and that is the thing to know before adding one. The
//  system takes the first ten and drops the rest in silence, so an eleventh
//  would ship as a feature that simply never appears —
//  `OpenHikesShortcutsTests` is what refuses it. A new shortcut from here is a
//  decision about which existing one stops being offered.
//

import AppIntents

nonisolated struct OpenHikesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartHikeRecordingIntent(),
            phrases: [
                "Start a hike in \(.applicationName)",
                "Start recording a hike in \(.applicationName)",
                "Record a hike with \(.applicationName)",
            ],
            shortTitle: "Start Hike",
            systemImageName: "figure.hiking"
        )
        AppShortcut(
            intent: PauseHikeRecordingIntent(),
            phrases: [
                "Pause my hike in \(.applicationName)",
                "Pause my \(.applicationName) recording",
            ],
            shortTitle: "Pause Hike",
            systemImageName: "pause.circle"
        )
        AppShortcut(
            intent: ResumeHikeRecordingIntent(),
            phrases: [
                "Resume my hike in \(.applicationName)",
                "Resume my \(.applicationName) recording",
            ],
            shortTitle: "Resume Hike",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: StopHikeRecordingIntent(),
            phrases: [
                "Stop my hike in \(.applicationName)",
                "Finish my hike in \(.applicationName)",
                "Save my hike in \(.applicationName)",
            ],
            shortTitle: "Stop Hike",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: CurrentHikeProgressIntent(),
            phrases: [
                "How far have I hiked in \(.applicationName)",
                "How is my \(.applicationName) hike going",
            ],
            shortTitle: "Hike Progress",
            systemImageName: "location.north.line"
        )
        AppShortcut(
            intent: HikeDistanceTodayIntent(),
            phrases: [
                "How far did I hike today in \(.applicationName)",
                "My \(.applicationName) distance today",
            ],
            shortTitle: "Distance Today",
            systemImageName: "sum"
        )
        AppShortcut(
            intent: HikeDurationIntent(),
            phrases: [
                "How long was my hike in \(.applicationName)",
                "How far was my hike in \(.applicationName)",
                "Summarise a hike in \(.applicationName)",
            ],
            shortTitle: "Hike Summary",
            systemImageName: "figure.hiking.circle"
        )
        AppShortcut(
            intent: RecordAlongTrailIntent(),
            phrases: [
                "Record along a trail in \(.applicationName)",
                "Start recording along \(\.$hike) in \(.applicationName)",
                "Hike \(\.$hike) with \(.applicationName)",
            ],
            shortTitle: "Record Along Trail",
            systemImageName: "point.topleft.down.curvedto.point.bottomright.up"
        )
        AppShortcut(
            intent: OpenHikeIntent(),
            phrases: [
                // "Open <hike> in OpenHikes" is the one people say, and the
                // parameter is left for the system to fill: a phrase naming
                // `\(\.$hike)` matches only when the hike is said in that exact
                // position, where an unparameterised phrase opens the picker.
                "Open a hike in \(.applicationName)",
                "Show a hike in \(.applicationName)",
                "Open \(\.$hike) in \(.applicationName)",
                "Show me \(\.$hike) in \(.applicationName)",
            ],
            shortTitle: "Open Hike",
            systemImageName: "map"
        )
        AppShortcut(
            intent: LastHikeIntent(),
            phrases: [
                "What was my last hike in \(.applicationName)",
                "Show my last hike in \(.applicationName)",
            ],
            shortTitle: "Last Hike",
            systemImageName: "clock.arrow.circlepath"
        )
    }
}
