//
//  LifecycleObservation.swift
//  OpenHikes
//
//  One observation of the app's lifecycle, on every release the app supports,
//  which ends when it is released.
//
//  `MapView.Coordinator` holds these, and ``PreferenceObservation`` holds them
//  for `HikeLiveActivityController` and `MovementReminderController`. All of
//  them rest on the same two properties. The handler runs *in* the post,
//  synchronously and on the main actor — `MapCoordinatorLifecycleTests` pins
//  why that matters for the map. And the registration lives exactly as long
//  as its holder keeps it, so releasing the holder is the whole of the
//  deregistration.
//
//  On iOS 26 and later both come from the typed messages: a
//  `UIApplication.DidBecomeActiveMessage` observer is main-actor isolated, and
//  the `NotificationCenter.ObservationToken` it returns ends the observation
//  when it goes out of scope. Neither exists below 26, so there they are built
//  on the block-based observer: registered with no queue, so it runs on the
//  posting thread — UIKit posts these on the main thread, where
//  ``onMainActor(_:)`` runs synchronously — and removed in this type's
//  `deinit`, because a block-based observer is otherwise retained by the
//  centre until somebody removes it. `LifecycleObservationTests` holds both
//  forms to the same contract on the current simulator.
//
//  Registered with no subject either way, so an untyped post carrying no
//  object reaches it. That is how every suite driving a lifecycle gate posts,
//  having no way to background a test host.
//

#if canImport(UIKit)
import UIKit

final class LifecycleObservation {
    /// The moments the app watches for.
    enum Moment: CaseIterable {
        case didBecomeActive
        case didEnterBackground
        case willEnterForeground
    }

    // periphery:ignore - held and never read: releasing it is what ends the
    // observation, as the deinit says.
    /// The typed message's token, which ends the observation itself.
    private let typedToken: Any?
    /// The block-based observer's token, which ``center`` keeps until it is
    /// removed.
    private let earlierToken: (any NSObjectProtocol)?
    private let center: NotificationCenter

    /// Observes `moment` on `center` with the typed message where there is
    /// one, and the block-based observer below iOS 26.
    convenience init(
        _ moment: Moment,
        on center: NotificationCenter,
        perform: @escaping @MainActor @Sendable () -> Void
    ) {
        if #available(iOS 26.0, *) {
            self.init(
                typedToken: Self.typedToken(for: moment, on: center, perform: perform),
                earlierToken: nil,
                center: center
            )
        } else {
            self.init(earlier: moment, on: center, perform: perform)
        }
    }

    /// The block-based form on any release: what the app observes with below
    /// iOS 26, and what a suite holds to the same contract above it.
    convenience init(
        earlier moment: Moment,
        on center: NotificationCenter,
        perform: @escaping @MainActor @Sendable () -> Void
    ) {
        let token = center.addObserver(forName: moment.name, object: nil, queue: nil) { _ in
            onMainActor(perform)
        }
        self.init(typedToken: nil, earlierToken: token, center: center)
    }

    private init(
        typedToken: Any?,
        earlierToken: (any NSObjectProtocol)?,
        center: NotificationCenter
    ) {
        self.typedToken = typedToken
        self.earlierToken = earlierToken
        self.center = center
    }

    @available(iOS 26.0, *)
    private static func typedToken(
        for moment: Moment,
        on center: NotificationCenter,
        perform: @escaping @MainActor @Sendable () -> Void
    ) -> NotificationCenter.ObservationToken {
        switch moment {
        case .didBecomeActive:
            center.addObserver(for: UIApplication.DidBecomeActiveMessage.self) { _ in perform() }
        case .didEnterBackground:
            center.addObserver(for: UIApplication.DidEnterBackgroundMessage.self) { _ in perform() }
        case .willEnterForeground:
            center.addObserver(for: UIApplication.WillEnterForegroundMessage.self) { _ in perform() }
        }
    }

    /// A typed token deregisters by being released along with this. The
    /// block-based one has to be removed, which is why this is isolated:
    /// SE-0371 hops it back to the main actor that owns the token.
    isolated deinit {
        if let earlierToken {
            center.removeObserver(earlierToken)
        }
    }
}

extension LifecycleObservation.Moment {
    /// The untyped name UIKit posts, which the typed messages are bridged
    /// from.
    var name: Notification.Name {
        switch self {
        case .didBecomeActive: UIApplication.didBecomeActiveNotification
        case .didEnterBackground: UIApplication.didEnterBackgroundNotification
        case .willEnterForeground: UIApplication.willEnterForegroundNotification
        }
    }

}
#endif
