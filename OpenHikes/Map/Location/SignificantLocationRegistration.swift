//
//  SignificantLocationRegistration.swift
//  OpenHikes
//
//  The one significant-location-change registration this app has, and the two
//  reasons it has for wanting it.
//
//  `startMonitoringSignificantLocationChanges()` is not a property of the
//  `CLLocationManager` it is called on. It registers the *app* with the
//  location daemon — which is what lets the registration outlive the process
//  and relaunch it — so a second manager calling `stop` cancels what the first
//  one started, and neither of them can tell. Measured on 2026-09-17 on an
//  iPhone 18 Pro simulator: one delivery reached the delegates of two
//  different `CLLocationManager`s in this process, only one of which had
//  started anything, and a `stop` issued on the other stood the whole thing
//  down.
//
//  Two objects want that registration for unrelated reasons.
//  ``SignificantLocationFeed`` wants it while the app is on screen, so the
//  weather badge can notice the hiker has changed region.
//  ``BackgroundTrailTracker`` wants it while a followed trail is near, so a
//  suspended app still matches fixes against it. Each held a manager of its
//  own and called start and stop on it without knowing about the other, which
//  is two bugs rather than one: the tracker re-syncing took the badge's feed
//  down with it, and a tracker arming after the scene had resigned left the
//  app registered with the feed's own flag saying it was not.
//
//  So the decision is owned here, once. Delivery is not: each consumer keeps
//  the manager it always had, because each needs its own delegate and
//  CoreLocation hands a significant change to every manager in the process
//  that has one. What changes is that `start` and `stop` now state a
//  *reason's* wish, and CoreLocation hears one call per genuine transition.
//

import CoreLocation
import Foundation

/// Arbitrates the app's single significant-change registration between the
/// reasons this app has for wanting it.
final class SignificantLocationRegistration {
    /// Why the app wants significant-change delivery.
    ///
    /// Two cases, and they are not variants of one thing: one is a foreground
    /// convenience and the other is the whole of a background feature. They
    /// share only the CoreLocation service underneath, which is precisely the
    /// thing that has to be shared carefully.
    enum Reason: Hashable, CaseIterable, Sendable {
        /// The weather badge's "have they moved far enough that the region
        /// this reading is for is now wrong" feed. Armed only while the app is
        /// on screen — see ``SignificantLocationFeed``.
        case movementFeed
        /// Background matching against a followed trail — see
        /// ``BackgroundTrailTracker``. The one reason that is meant to stay
        /// armed after the app leaves the foreground.
        case trailMatching
    }

    /// The manager whose start and stop calls *are* this app's registration.
    ///
    /// Its own, rather than one of the consumers'. Which manager issues the
    /// call does not matter — the registration is app-scoped, which is exactly
    /// why two of them issuing calls without knowing about each other was a
    /// bug — but it has to be *one*, and it has to be one no consumer can also
    /// reach. Nothing is ever delivered to it: it has no delegate, and the
    /// consumers are fed through the managers they already hold.
    private let monitor: any SignificantLocationMonitor

    private var armedReasons: Set<Reason> = []

    /// What this process has told CoreLocation, which is not the same question
    /// as what it wants.
    ///
    /// Three states rather than a `Bool`, and the third is load-bearing rather
    /// than pedantic. Significant-change monitoring outlives the process that
    /// armed it, so a launch inherits whatever the previous one left and has no
    /// way to ask what that was. A `Bool` starting at `false` would make the
    /// first stand-down of a launch look like a no-op transition and skip it,
    /// leaving that inherited registration standing — the exact leak
    /// ``BackgroundTrailTracker``'s launch-time `syncMonitoring()` and
    /// `HikeRecorder+State`'s unconditional `stopMovementWatch()` each exist to
    /// close. ``unsaid`` differs from *both* answers, so whichever direction
    /// this process's first call goes, it reaches CoreLocation.
    private enum Issued {
        case unsaid
        case armed
        case stoodDown
    }

    private var issued: Issued = .unsaid

    /// - Parameter monitor: what the start and stop calls reach. `nil`
    ///   composes a real `CLLocationManager`, matching
    ///   ``BackgroundTrailTracker/init(container:monitor:regionMonitor:defaults:liveActivityController:clock:widgetReload:)``:
    ///   a launch that must not have a location stack passes
    ///   ``DormantLocationSource`` instead, and one that may passes nothing.
    init(monitor: (any SignificantLocationMonitor)? = nil) {
        self.monitor = monitor ?? CLLocationManager()
    }

    /// The monitor to hand the consumer that wants delivery for `reason`.
    ///
    /// - Parameter monitor: the consumer's own manager, which is what carries
    ///   its delegate and answers its authorization questions. `nil` composes
    ///   a real `CLLocationManager`, as everywhere else here.
    func client(
        for reason: Reason,
        monitor: (any SignificantLocationMonitor)? = nil
    ) -> Client {
        Client(
            reason: reason,
            registration: self,
            monitor: monitor ?? CLLocationManager()
        )
    }

    /// What the app is currently registered for. A test seam, and the only
    /// way to assert the thing this type exists to get right.
    var armed: Set<Reason> { armedReasons }

    /// States one reason's wish and brings CoreLocation in line with all of
    /// them.
    ///
    /// Idempotent per reason, so re-stating a wish costs nothing — which
    /// matters because ``BackgroundTrailTracker/syncMonitoring(trackingEnabled:)``
    /// re-states its own on every authorization change, every selection and
    /// every region crossing.
    private func setArmed(_ isArmed: Bool, for reason: Reason) {
        if isArmed {
            armedReasons.insert(reason)
        } else {
            armedReasons.remove(reason)
        }
        let wanted: Issued = armedReasons.isEmpty ? .stoodDown : .armed
        guard wanted != issued else { return }
        issued = wanted
        switch wanted {
        case .armed: monitor.startSignificantLocationUpdates()
        case .stoodDown: monitor.stopSignificantLocationUpdates()
        case .unsaid: break
        }
    }
}

extension SignificantLocationRegistration {
    /// One reason's view of the shared registration.
    ///
    /// Conforms to ``SignificantLocationMonitor`` so that the consumer which
    /// used to hold a `CLLocationManager` of its own holds this instead and
    /// changes nothing else: it answers the same members, and the questions
    /// are forwarded to that consumer's own manager unchanged. The two
    /// commands are the point — they state this reason's wish instead of
    /// reaching CoreLocation, and the registration decides what CoreLocation
    /// is told.
    final class Client: SignificantLocationMonitor {
        private let reason: Reason
        /// Strong, and the direction is deliberate: the registration holds no
        /// reference back, so the consumers that own their clients are what
        /// keep the one registration alive for as long as anything wants it.
        private let registration: SignificantLocationRegistration
        /// This consumer's own manager. Delivery is still per-manager — every
        /// `CLLocationManager` in the process with a delegate receives a
        /// significant change, whichever one armed it — so the consumer is fed
        /// exactly as it was before this type existed.
        private let monitor: any SignificantLocationMonitor

        /// Not called directly: ``SignificantLocationRegistration/client(for:monitor:)``
        /// is the way in, because a client that is not one of *that*
        /// registration's is a decision nobody is arbitrating.
        init(
            reason: Reason,
            registration: SignificantLocationRegistration,
            monitor: any SignificantLocationMonitor
        ) {
            self.reason = reason
            self.registration = registration
            self.monitor = monitor
        }

        var isAlwaysAuthorized: Bool { monitor.isAlwaysAuthorized }
        var canRequestAlwaysAccess: Bool { monitor.canRequestAlwaysAccess }

        var monitorDelegate: CLLocationManagerDelegate? {
            get { monitor.monitorDelegate }
            set { monitor.monitorDelegate = newValue }
        }

        func requestAlwaysAccess() {
            monitor.requestAlwaysAccess()
        }

        func startSignificantLocationUpdates() {
            registration.setArmed(true, for: reason)
        }

        func stopSignificantLocationUpdates() {
            registration.setArmed(false, for: reason)
        }
    }
}
