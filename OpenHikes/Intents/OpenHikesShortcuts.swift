//
//  OpenHikesShortcuts.swift
//  OpenHikes
//
//  What Siri and Spotlight offer without the walker building a shortcut first.
//
//  Every phrase has to carry `\(.applicationName)` — the system will not
//  register one that doesn't, and it fails by simply never matching rather
//  than by complaining. Several spellings per intent because the ones people
//  actually say are not the ones an intent is titled: "start a hike" and
//  "record a hike" are the same request.
//
//  Ten is the system's ceiling on shortcuts per app, and the sixth through
//  tenth slots are worth spending on intents that do not exist yet, so the
//  seven below are deliberately the whole recording loop plus the two
//  questions. See the issue tracker for what is queued behind them.
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
