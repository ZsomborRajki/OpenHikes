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
//  Ten is the system's ceiling on shortcuts per app. The eight below are the
//  whole recording loop, the three questions, and the one that takes a
//  parameter — `HikeDurationIntent`, which is what ``HikeEntity`` was built
//  for. Two slots are deliberately unspent, and what is queued for them is
//  #480 and #481 — an unbuilt intent belongs on the issue tracker rather than
//  in a comment here, and the argument for each is there rather than repeated
//  below.
//
//  Neither is blocked on plumbing. #480 is blocked on navigation:
//  `OpenHikesView` is at its `type_body_length` limit and an intent runs in
//  the app process but outside the view tree, so the honest version routes a
//  ``HikeEntity`` through the deep link the widget already uses rather than
//  opening a second way in. #481 is blocked on a product decision: starting a
//  recording *and* naming a trail to follow is the one gesture that asks for
//  both at once, and *a live recording outranks the selected trail* means the
//  trail the hiker just said out loud is the thing that leaves the widget.
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
