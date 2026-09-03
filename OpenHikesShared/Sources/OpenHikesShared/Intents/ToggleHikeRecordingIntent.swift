//
//  ToggleHikeRecordingIntent.swift
//  OpenHikesShared
//
//  The action shared by the app and its Control Center control.
//
//  A control's AppIntent type has to be visible to the widget extension that
//  draws the control and to the app process that performs it. The protocol is
//  the narrow bridge back to the app's recorder; the shared package never
//  owns or guesses recording state.
//

import AppIntents

@preconcurrency
@MainActor
public protocol HikeRecordingControlHandling: Sendable {
    func toggleHikeRecording() async throws -> HikeRecordingControlOutcome
}

public enum HikeRecordingControlOutcome: Equatable, Sendable {
    case completed
    case requiresForegroundAuthorization
}

public struct ToggleHikeRecordingIntent: AppIntent {
    public static let title: LocalizedStringResource = "Toggle Hike Recording"
    public static let supportedModes: IntentModes = [
        .background,
        .foreground(.dynamic),
    ]

    @Dependency private var recordingControl: any HikeRecordingControlHandling

    public init() {
        // Required for App Intents metadata construction.
    }

    public func perform() async throws -> some IntentResult {
        switch try await recordingControl.toggleHikeRecording() {
        case .completed:
            return .result()
        case .requiresForegroundAuthorization:
            throw needsToContinueInForegroundError(
                IntentDialog(
                    "OpenHikes needs your location before it can record a hike."
                )
            )
        }
    }
}
