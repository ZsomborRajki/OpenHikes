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
//  The banner's own tap is left to the system for every kind but one: it
//  brings the app to the front, and a hiker who wanted the screen gets the
//  app. The exception is the walk offer, whose tap has to land on the trail
//  it asks about — that is where Don't Ask Again is. A delegate with no view
//  hierarchy cannot set the route, so it does what an App Intent does: it
//  leaves the request in ``HikeOpenRequests``, which the view tree watches
//  and routes exactly as a widget tap.
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
    /// Where the walk offer's tap asks for its trail to be opened. The model
    /// owns it, for the reason it owns the session.
    private weak var openRequests: HikeOpenRequests?

    init(
        recording: HikeIntentCoordinator,
        walkSession: TrailWalkSession?,
        openRequests: HikeOpenRequests? = nil
    ) {
        self.recording = recording
        self.walkSession = walkSession
        self.openRequests = openRequests
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
    ///
    /// - Parameter walkOffer: the walk a ``MovementReminderKind/walkNearby``
    ///   banner carried, which its two buttons need and no other kind has.
    func perform(
        _ action: MovementReminderAction,
        from kind: MovementReminderKind,
        walkOffer: WalkOfferSubject? = nil
    ) async {
        guard kind.actions.contains(action) else { return }
        switch kind {
        // Unreachable: the guard above refuses every action for a kind with
        // none, which is what the off-trail and severe-weather banners'
        // categories register. Spelled positively rather than defaulted so
        // that a later kind gaining a verb fails the build here instead of
        // silently doing nothing — which is what it did when
        // `.severeWeather` was added.
        case .leftTheTrail, .severeWeather: break
        case .pauseRecording: await pauseRecording()
        case .resumeRecording: await resumeRecording()
        case .resumeWalk: walkSession?.resume()
        case .walkNearby:
            guard let walkOffer else { return }
            if action == .startWalk {
                walkSession?.start(hikeID: walkOffer.hikeID, routeLengthMeters: walkOffer.routeLengthMeters)
            } else {
                walkSession?.ignoreOffer(hikeID: walkOffer.hikeID)
            }
        }
    }

    /// The banner itself, rather than a button on it: tapped, or cleared away.
    /// Only the walk offer asks to hear either — see
    /// ``MovementReminderKind/reportsDismissal``.
    func respond(toBannerOf kind: MovementReminderKind, walkOffer: WalkOfferSubject?, dismissed: Bool) {
        guard kind == .walkNearby, let walkOffer else { return }
        if dismissed {
            walkSession?.ignoreOffer(hikeID: walkOffer.hikeID)
            return
        }
        // The card first, then the screen that draws it: the detail reads the
        // offer when it appears, and a process launched by this tap has none.
        walkSession?.reoffer(hikeID: walkOffer.hikeID)
        openRequests?.open(hikeID: walkOffer.hikeID)
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
        let content = response.notification.request.content
        let categoryIdentifier = content.categoryIdentifier
        let actionIdentifier = response.actionIdentifier
        let walkOffer = WalkOfferSubject(userInfo: content.userInfo)
        guard let kind = MovementReminderKind.allCases.first(where: { candidate in
            candidate.categoryIdentifier == categoryIdentifier
        }) else { return }
        switch actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            await respond(toBannerOf: kind, walkOffer: walkOffer, dismissed: false)
        case UNNotificationDismissActionIdentifier:
            await respond(toBannerOf: kind, walkOffer: walkOffer, dismissed: true)
        default:
            guard let action = MovementReminderAction(rawValue: actionIdentifier) else { return }
            await perform(action, from: kind, walkOffer: walkOffer)
        }
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
    ///
    /// Except the walk offer, which is never shown over the app: with the app
    /// in front the trail's detail asks the same question as a card. The
    /// controller does not post one then, and this is for the one that was
    /// already on its way as the app came forward.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let category = notification.request.content.categoryIdentifier
        return category == MovementReminderKind.walkNearby.categoryIdentifier ? [] : [.banner, .sound]
    }
    // swiftlint:enable async_without_await
}
#endif
