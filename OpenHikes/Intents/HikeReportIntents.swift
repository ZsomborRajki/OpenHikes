//
//  HikeReportIntents.swift
//  OpenHikes
//
//  The three questions worth asking a phone you are not looking at: how far in
//  am I, what did I do today, and what was the last one.
//
//  All three answer with a dialog and stay in the background. None of them
//  opens the app: the answer is one sentence, and a walk interrupted to read a
//  screen is a worse answer than the sentence.
//

import AppIntents
import Foundation

struct CurrentHikeProgressIntent: AppIntent, HikeCoordinatingIntent {
    static let title: LocalizedStringResource = "Current Hike Progress"
    // periphery:ignore - an optional `AppIntent` requirement, read through the
    // AppIntents metadata rather than by any call site.
    static let description = IntentDescription(
        "Says how far and how long you are into the hike you are recording.",
        categoryName: "Recording"
    )
    static let supportedModes: IntentModes = .background

    @Dependency var appCoordinator: HikeIntentCoordinator

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let recording = try await coordinator.currentRecording()
        return .result(dialog: IntentDialog("\(recording.spokenSummary)"))
    }
}

struct HikeDistanceTodayIntent: AppIntent, HikeCoordinatingIntent {
    static let title: LocalizedStringResource = "Distance Hiked Today"
    // periphery:ignore - see `CurrentHikeProgressIntent.description`.
    static let description = IntentDescription(
        "Adds up everything you have hiked today.",
        categoryName: "Hikes"
    )
    static let supportedModes: IntentModes = .background

    /// What the totals are read back against — "today", not a date. The
    /// coordinator resolves which day that is against the walker's own
    /// calendar, so this string and that fetch have to keep meaning the same
    /// thing.
    private static let dayLabel = "today"

    @Dependency var appCoordinator: HikeIntentCoordinator

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let totals = try await coordinator.totalsForToday()
        return .result(
            dialog: IntentDialog("\(totals.spokenSummary(for: Self.dayLabel))")
        )
    }
}

struct LastHikeIntent: AppIntent, HikeCoordinatingIntent {
    static let title: LocalizedStringResource = "Last Hike"
    // periphery:ignore - see `CurrentHikeProgressIntent.description`.
    static let description = IntentDescription(
        "Reports the most recent hike you finished.",
        categoryName: "Hikes"
    )
    static let supportedModes: IntentModes = .background

    @Dependency var appCoordinator: HikeIntentCoordinator

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let hike = try await coordinator.lastFinishedHike()
        // The value is returned as well as spoken so a Shortcut can carry the
        // sentence into a message or a note, which is most of what anybody
        // builds a shortcut around this for.
        return .result(
            value: hike.spokenSummary,
            dialog: IntentDialog("\(hike.spokenSummary)")
        )
    }
}
