//
//  MovementReminderActions.swift
//  OpenHikes
//
//  What the button on a reminder does.
//
//  A notification action runs in this process without a view hierarchy behind
//  it — the system may launch the app purely to perform one — which is the
//  same situation an App Intent runs in, and it is answered the same way:
//  through ``HikeIntentCoordinator``, which owns the whole of what can be done
//  to a recording without a screen. Nothing here reads or writes recording
//  state itself, so the recorder stays the single authority and the buttons
//  cannot drift away from what Siri, the Control Center toggle and the
//  recording screen do.
//
//  The banner's own tap is deliberately left to the system: it brings the app
//  to the front, and this app's route to a particular screen is view state
//  that a delegate with no view hierarchy has no way to set. A hiker who
//  wanted the screen gets the app; one who wanted the recording resumed has a
//  button that does it without unlocking anything.
//

import Foundation
import os
#if canImport(UserNotifications)
import UserNotifications
#endif

@MainActor
final class MovementReminderActions: NSObject {
    private static let logger = Logger(
        subsystem: "OpenHikes",
        category: "MovementReminders"
    )

    private let recording: HikeIntentCoordinator
    /// Weak for the reason ``BackgroundTrailTracker/walkSession`` is: the model
    /// owns both, and a strong reference here would be a cycle through the
    /// notification centre, which holds this object for the life of the app.
    private weak var walkSession: TrailWalkSession?

    init(recording: HikeIntentCoordinator, walkSession: TrailWalkSession?) {
        self.recording = recording
        self.walkSession = walkSession
    }

    /// Becomes the notification centre's delegate.
    ///
    /// Here rather than at the call site so that the one file importing
    /// `UserNotifications` for this feature is this one, and returning `self`
    /// so the caller cannot register without also keeping the object: the
    /// centre's delegate is a weak reference, and a handler nobody retains is
    /// a Resume button that silently does nothing.
    @discardableResult func registerAsNotificationDelegate() -> Self {
        #if canImport(UserNotifications)
        UNUserNotificationCenter.current().delegate = self
        #endif
        return self
    }

    /// Performs one button, or does nothing when the button and the reminder
    /// it came from do not belong together — a banner delivered by a build
    /// that spelled its categories differently, or one the hiker had sitting
    /// in Notification Centre across an update.
    func perform(_ action: MovementReminderAction, from kind: MovementReminderKind) async {
        guard action == kind.action else { return }
        switch kind {
        case .pauseRecording: await pauseRecording()
        case .resumeRecording: await resumeRecording()
        case .resumeWalk: walkSession?.resume()
        }
    }

    private func resumeRecording() async {
        do {
            _ = try await recording.resumeRecording()
        } catch {
            // Spoken failures are for Siri; here there is nobody listening, and
            // the hiker's next look at the recording screen shows the truth
            // either way — including a `.preciseLocationRequired` refusal,
            // which is the one this path can genuinely walk into.
            Self.logger.error("Reminder could not resume the recording: \(error, privacy: .public)")
        }
    }

    private func pauseRecording() async {
        do {
            _ = try await recording.pauseRecording()
        } catch {
            Self.logger.error("Reminder could not pause the recording: \(error, privacy: .public)")
        }
    }
}

#if canImport(UserNotifications)
extension MovementReminderActions: UNUserNotificationCenterDelegate {
    /// The strings are read here, on whatever thread the system delivered on,
    /// and the work is done on the main actor: `UNNotificationResponse` is a
    /// non-`Sendable` class, and its identifiers are not.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let categoryIdentifier = response.notification.request.content.categoryIdentifier
        let actionIdentifier = response.actionIdentifier
        guard let kind = MovementReminderKind.allCases.first(where: { candidate in
            candidate.categoryIdentifier == categoryIdentifier
        }),
            let action = MovementReminderAction(rawValue: actionIdentifier) else { return }
        await perform(action, from: kind)
    }

    // `async` with nothing to await, and it has to be: this witnesses an
    // `@objc` requirement whose Swift spelling is the async one, so a
    // synchronous function here would not satisfy the protocol at all.
    // swiftlint:disable async_without_await
    /// Shown while the app is in the foreground as well.
    ///
    /// A hiker looking at the map with the recording paused is exactly the
    /// person this feature is for — the screen they are on says "Paused" in
    /// small print at the top and nothing else knows they have started walking
    /// again. Sound and banner, no badge: the app has never used one.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
    // swiftlint:enable async_without_await
}
#endif
