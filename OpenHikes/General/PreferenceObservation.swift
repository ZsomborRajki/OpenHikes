//
//  PreferenceObservation.swift
//  OpenHikes
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The two observations a controller keeps when its behaviour is switched on
/// and off by a preference it does not own.
///
/// ``HikeLiveActivityController`` and ``MovementReminderController`` both have
/// one, and for the same reason: each is governed by a pair of switches that
/// report themselves by different means and neither by asking.
///
/// The app's own half is a `UserDefaults` key that `SettingsView` writes
/// through `@AppStorage`, so the defaults notification — scoped to the
/// controller's own suite, never the process-wide one — is what sees it. The
/// system's half is not a default at all and changing it means leaving for
/// iOS Settings, so returning to the foreground is the only moment the app can
/// re-ask; `UIApplication`'s lifecycle message rather than `scenePhase` keeps
/// this off SwiftUI's render path entirely, which is the same choice
/// `MapView.Coordinator` makes and for the same reason.
///
/// **The two are not the same kind of observation and must not be collapsed
/// into one.** `DidBecomeActiveMessage` is a `MainActorMessage`, so its handler
/// is synchronously main-actor isolated and needs no hop.
/// `UserDefaults.didChangeNotification` has no typed message and arrives on
/// whichever thread wrote the key, so it keeps its `onMainActor`.
///
/// What they do share is how they are *held*, which is the half that leaks if
/// it is written twice and typed once wrong — so it is written here.
@MainActor
final class PreferenceObservation {
    /// The typed lifecycle observation, held for exactly as long as its owner
    /// is — which is the whole of its deregistration.
    /// `NotificationCenter.ObservationToken` ends its observation when it goes
    /// out of scope, so releasing this array is what takes the observer off
    /// the centre; dropping the token at the end of ``observe(lifecycleCenter:defaults:onForeground:onDefaultsChange:)``
    /// would instead take the registration down before the hiker ever left the
    /// app. `LifecycleObservationTokenTests` pins both halves.
    private var lifecycleObservers: [NotificationCenter.ObservationToken] = []

    /// The untyped one, which has no such lifetime: a block-based observer is
    /// retained by the notification centre until it is removed by token, and
    /// the app-hosted test bundles build hundreds of these controllers. That
    /// is the entire job of the `isolated deinit` below — SE-0371 hops it back
    /// to the main actor before it runs, which is what lets it read main-actor
    /// storage and what removed the `nonisolated` box this used to need.
    /// ``PowerStateMonitor`` makes the same choice.
    private var defaultsObservers: [any NSObjectProtocol] = []

    isolated deinit {
        for token in defaultsObservers { NotificationCenter.default.removeObserver(token) }
    }

    /// - Parameters:
    ///   - lifecycleCenter: Where the foreground message is listened for. A
    ///     suite passes a private centre so it can drive the registration
    ///     itself rather than the reconciliation behind it, without posting a
    ///     process-wide notification into a running test host.
    ///   - defaults: The suite whose changes matter. Scoped deliberately: the
    ///     process-wide notification fires for every key any part of the app
    ///     writes.
    ///   - onForeground: Run when the app comes back, to re-ask the system
    ///     switch that cannot be observed.
    ///   - onDefaultsChange: Run when the suite changes, already on the main
    ///     actor.
    func observe(
        lifecycleCenter: NotificationCenter,
        defaults: UserDefaults,
        onForeground: @escaping @MainActor @Sendable () -> Void,
        onDefaultsChange: @escaping @MainActor @Sendable () -> Void
    ) {
        #if canImport(UIKit)
        lifecycleObservers.append(
            lifecycleCenter.addObserver(
                for: UIApplication.DidBecomeActiveMessage.self
            ) { _ in
                onForeground()
            }
        )
        #endif
        defaultsObservers.append(
            NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: defaults,
                queue: nil
            ) { _ in
                onMainActor { onDefaultsChange() }
            }
        )
    }
}
