//
//  RecordingIntents.swift
//  OpenHikes
//
//  Start, pause, resume and stop, without taking the phone out.
//
//  All four run in the background: the walker's hands are busy and the phone
//  is in a pocket, so an intent that insisted on bringing the app to the front
//  would be answering a different request than the one asked. The exception is
//  the very first start on a fresh install, where Core Location has never been
//  asked — that prompt is a foreground event and cannot be shown from here, so
//  the intent hands the walker to the app instead of quietly failing to record.
//

import AppIntents

struct StartHikeRecordingIntent: AppIntent, HikeCoordinatingIntent {
    static let title: LocalizedStringResource = "Start Hike Recording"
    // periphery:ignore - an optional `AppIntent` requirement, read through the
    // AppIntents metadata rather than by any call site.
    static let description = IntentDescription(
        "Starts recording a new hike, with the screen off and the phone in your pocket.",
        categoryName: "Recording"
    )
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Dependency var appCoordinator: HikeIntentCoordinator

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard await coordinator.authorization != .undecided else {
            // Not an error the walker can act on from here: the system prompt
            // only exists in the foreground, and a recording started without
            // it would sit in `waitingForFix` forever.
            throw needsToContinueInForegroundError(
                IntentDialog("OpenHikes needs your location before it can record a hike.")
            )
        }
        let recording = try await coordinator.startRecording()
        return .result(dialog: IntentDialog("\(Self.confirmation(for: recording))"))
    }

    /// A just-started recording has walked nothing and lasted no time, so its
    /// own summary would read "You're 0 metres in, 0s elapsed."
    nonisolated private static func confirmation(for recording: LiveRecordingReport) -> String {
        guard let trailName = recording.trailName, !trailName.isEmpty else {
            return "Recording your hike."
        }
        return "Recording your hike on \(trailName)."
    }
}

struct PauseHikeRecordingIntent: AppIntent, HikeCoordinatingIntent {
    static let title: LocalizedStringResource = "Pause Hike Recording"
    // periphery:ignore - see `StartHikeRecordingIntent.description`.
    static let description = IntentDescription(
        "Pauses the hike being recorded, and turns the GPS off until you resume.",
        categoryName: "Recording"
    )
    static let supportedModes: IntentModes = .background

    @Dependency var appCoordinator: HikeIntentCoordinator

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let recording = try await coordinator.pauseRecording()
        return .result(dialog: IntentDialog("\(recording.spokenSummary)"))
    }
}

struct ResumeHikeRecordingIntent: AppIntent, HikeCoordinatingIntent {
    static let title: LocalizedStringResource = "Resume Hike Recording"
    // periphery:ignore - see `StartHikeRecordingIntent.description`.
    static let description = IntentDescription(
        "Picks the paused hike back up where you left it.",
        categoryName: "Recording"
    )
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Dependency var appCoordinator: HikeIntentCoordinator

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let recording = try await coordinator.resumeRecording()
        return .result(dialog: IntentDialog("\(recording.spokenSummary)"))
    }
}

struct StopHikeRecordingIntent: AppIntent, HikeCoordinatingIntent {
    static let title: LocalizedStringResource = "Stop Hike Recording"
    // periphery:ignore - see `StartHikeRecordingIntent.description`.
    static let description = IntentDescription(
        "Stops the hike being recorded and saves it.",
        categoryName: "Recording"
    )
    static let supportedModes: IntentModes = .background

    @Dependency var appCoordinator: HikeIntentCoordinator

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let hike = try await coordinator.stopRecording()
        return .result(dialog: IntentDialog("\(Self.confirmation(for: hike))"))
    }

    /// Named "Saved" rather than "Stopped": stopping is what the walker asked
    /// for, and what they want confirmed is that it survived.
    nonisolated private static func confirmation(for hike: FinishedHikeReport) -> String {
        "Saved \(hike.spokenSummary)"
    }
}
