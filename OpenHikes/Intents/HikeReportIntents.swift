//
//  HikeReportIntents.swift
//  OpenHikes
//
//  The questions worth asking a phone you are not looking at: how far in am I,
//  what did I do today, what was the last one — and, since ``HikeEntity``
//  exists, how long was *that* one.
//
//  They all answer with a dialog and stay in the background. None of them
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
    /// coordinator resolves which day that is against the hiker's own
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

/// The parameterised sibling of ``LastHikeIntent``: how long a *named* hike
/// was, rather than the most recent one.
///
/// This is the first intent in the app to take a parameter at all, and the
/// reason ``HikeEntity`` exists — "How long was my Thumsee hike?" was
/// unanswerable while every intent here was parameterless.
///
/// It reads its clock the way ``LastHikeIntent`` does, off the route's own end
/// stamps through ``HikeIntentCoordinator``, rather than through
/// `Hike.routeStatistics` — which walks every point on the calling thread,
/// inside an intent with a system execution budget.
struct HikeDurationIntent: AppIntent, HikeCoordinatingIntent {
    static let title: LocalizedStringResource = "Hike Summary"
    // periphery:ignore - see `CurrentHikeProgressIntent.description`.
    static let description = IntentDescription(
        "Reports how far and how long a hike you have saved was.",
        categoryName: "Hikes"
    )
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Hike")
    var hike: HikeEntity

    @Dependency var appCoordinator: HikeIntentCoordinator

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        // Resolved again rather than read off the parameter, because an entity
        // can outlive the hike it names — a shortcut built last month, a
        // Spotlight result for a walk since deleted — and the stale copy would
        // otherwise be reported as fact.
        let report = try await coordinator.finishedHike(withID: hike.id)
        // Returned as well as spoken for the reason ``LastHikeIntent`` gives:
        // a Shortcut carrying the sentence into a message or a note is most of
        // what anybody builds one of these around.
        return .result(
            value: report.spokenSummary,
            dialog: IntentDialog("\(report.spokenSummary)")
        )
    }
}
