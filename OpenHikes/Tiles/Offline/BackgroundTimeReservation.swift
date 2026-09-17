//
//  BackgroundTimeReservation.swift
//  OpenHikes
//
//  The few minutes iOS grants an app that asks before it suspends, and the
//  seam the ask goes through.
//
//  A bulk offline download is up to ``OfflineTileDownloader/tileBudget`` = 4000
//  tiles fetched at `.background` priority through the same gate the map uses,
//  which on a route-sized plan is minutes of wall time. Nothing kept the app
//  alive for them: `grep -r "beginBackgroundTask"` over the app returned
//  nothing, so the run was an ordinary `Task` in a process the system suspends
//  the moment the hiker locks the phone. Saving a map meant sitting and
//  watching a progress bar — which is exactly the errand people start and walk
//  away from.
//
//  ## What this does and does not buy
//
//  It buys the grant iOS gives any app that asks, which covers a large share
//  of real downloads. It does **not** survive termination: a run killed while
//  suspended still keeps none of its tiles, because
//  ``OfflineDownloadRegistry`` commits the claim only at the end and an
//  uncommitted run's tiles are reclaimed by the next launch trim. That is the
//  right rule for a *cancelled* run and the wrong one for a killed one, and
//  fixing it means committing the claim incrementally — a change to the
//  ownership model rather than to the lifetime of a task. See the issue.
//
//  ## No background mode, and that is the point
//
//  `beginBackgroundTask` needs no `UIBackgroundModes` entry. `Info.plist`
//  declares `location` and `remote-notification`, and a tile download that is
//  not part of a recording can claim neither; this asks for none of them. It
//  is the ordinary "let me finish what I started" grant, and the expiration
//  handler is the price: the system will reclaim the time, and an app that has
//  not ended its task by then is killed rather than suspended.
//
//  ## Why it is a seam
//
//  The same reason ``ScreenWakeCoordinator``'s write is one, and the same
//  reason the downloader's transport, clock and gate are: both unit bundles
//  are hosted by the app, so a suite that reserved real background time would
//  reserve it for the whole process and for every test after it. And the
//  branch that matters most here — what happens when the grant expires — is
//  not reachable at all without something to stand in for the system.
//

import Foundation
#if os(iOS)
import UIKit
#endif

/// A handle to background time the system granted, or `nil` for a reservation
/// that was refused.
///
/// An opaque value rather than `UIBackgroundTaskIdentifier` so nothing above
/// this file imports UIKit to hold one — the shape ``HikeWorkoutRequest`` takes
/// for the same reason.
nonisolated struct BackgroundTimeToken: Equatable, Sendable {
    let rawValue: Int
}

/// Where a long piece of work asks not to be suspended halfway through.
///
/// Two closures rather than a protocol, matching the downloader's existing
/// seams: a suite hands in a pair that records, and the app's default pair is
/// the only place `UIApplication` is touched.
@MainActor
struct BackgroundTimeReservation {
    /// Asks for background time, and reports the handle to end it with.
    ///
    /// - Parameter expirationHandler: run when the system is about to reclaim
    ///   the time. The caller has to stop and end the reservation from it; an
    ///   app that does not is killed rather than suspended.
    let begin: @MainActor (_ expirationHandler: @escaping @MainActor () -> Void)
        -> BackgroundTimeToken?
    let end: @MainActor (BackgroundTimeToken) -> Void

    /// The app's own, and the one place `beginBackgroundTask` is called.
    static let system = Self(
        begin: { expirationHandler in
            #if os(iOS)
            let identifier = UIApplication.shared.beginBackgroundTask(
                withName: "OfflineTileDownload",
                expirationHandler: { MainActor.assumeIsolated(expirationHandler) }
            )
            // `.invalid` is a refusal — background execution is unavailable,
            // or the app is already out of time — and is not a handle to end.
            // Reported as `nil` so a caller cannot end something that was
            // never begun, which is its own crash.
            guard identifier != .invalid else { return nil }
            return BackgroundTimeToken(rawValue: identifier.rawValue)
            #else
            return nil
            #endif
        },
        end: { token in
            #if os(iOS)
            UIApplication.shared.endBackgroundTask(
                UIBackgroundTaskIdentifier(rawValue: token.rawValue)
            )
            #endif
        }
    )

    /// A reservation that is always refused, for a launch that must not ask —
    /// a hosted suite, where `UIApplication.shared` is the test host's.
    static let unavailable = Self(
        begin: { _ in nil },
        end: { _ in /* nothing was begun */ }
    )

    /// What a downloader gets when its caller does not name one: the real
    /// reservation, except under a test launch.
    ///
    /// The guard is here rather than at each call site because there is no
    /// call site — the default is what every suite that does not care about
    /// background time silently takes, and a suite that took ``system`` would
    /// reserve the grant for the whole test host and every test after it, for
    /// the reason this file's header gives. `isRunningTests` rather than
    /// `isHostingTests`, matching ``OpenHikesModel/makeWorkoutWriter()``: a
    /// UI-automation launch is a real process and must not hold the grant
    /// either.
    static var `default`: Self {
        AppLaunchEnvironment.isRunningTests ? .unavailable : .system
    }
}
