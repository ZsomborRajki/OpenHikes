//
//  WatchLaunchEnvironment.swift
//  OpenHikesWatch
//
//  Facts about *how this process was launched*, for the watch.
//
//  The same shape as `AppLaunchEnvironment` on the phone, and for the same
//  reasons: one definition rather than two guards that drift, and the parsing
//  compiled only into `DEBUG` builds so a shipping watch app never looks at
//  `ProcessInfo.arguments` at all.
//
//  ## What this exists for that the phone's does not
//
//  The phone's flags are driven by `OpenHikesUITests`. This target has no test
//  bundle and no gate boots a watch simulator — see the watch section of the
//  repository instructions — so nothing here is driven by a suite. It is
//  driven by `Scripts/watch-screenshots.sh`, which launches the app once per
//  frame with the arguments for that frame and takes a picture.
//
//  That is why there is a ``Screen`` at all, which has no equivalent on the
//  phone. The phone's screenshots are navigated to by a UI test tapping its
//  way there; this app is navigated by being *launched into* the screen,
//  because `simctl` can install, launch and photograph a watch app but cannot
//  tap one. Before this existed, looking at a watch screen meant editing
//  `OpenHikesWatchApp`'s `WindowGroup` by hand and putting it back afterwards.
//

import Foundation

nonisolated enum WatchLaunchEnvironment {
    /// Which screen a launch asked to open on.
    ///
    /// Deliberately the screens a *listing* shows rather than every screen
    /// there is: an empty state and a refusal are worth looking at while
    /// working on them, and `--ui-test-seed-trails=0` already reaches the
    /// first by leaving the library empty.
    enum Screen: String, CaseIterable, Sendable {
        /// One trail with its figures sheet up.
        case figures = "figures"
        /// One trail, open as a map.
        case map = "map"
        /// The Record tab.
        case record = "record"
        /// The hiker's trails, which is where the app opens anyway.
        case trails = "trails"
    }

    /// What a recording is doing, when a launch asked for one.
    enum RecordingState: String, CaseIterable, Sendable {
        case paused = "paused"
        case running = "running"
    }

    /// Everything a `--ui-test-*` argument can say about a watch launch.
    struct Configuration: Equatable, Sendable {
        let isUITesting: Bool
        let screen: Screen
        /// How many trails the seeded library holds. `0` leaves it empty,
        /// which is what draws the waiting-for-your-iPhone state.
        let seededTrailCount: Int
        /// Whether the watch is holding the trail's geometry. Separate from
        /// the library because the two arrive separately in life, and the gap
        /// between them is a screen of its own — the one that says it is
        /// fetching the trail from your iPhone, which
        /// `--ui-test-withhold-trail` is how to reach.
        let holdsTrail: Bool
        /// How far along the trail the hiker is, `0...1`, or `nil` for a watch
        /// that has not had a fix yet.
        let followFraction: Double?
        /// A recording running on this watch, if a launch asked for one.
        let watchRecording: RecordingState?
        /// A recording running on the paired phone, if a launch asked for one.
        let phoneRecording: RecordingState?
        /// How many finished walks are waiting to be sent.
        let queuedWalkCount: Int

        // periphery:ignore - the `#else` branch below is the only reader a
        // Release-configuration scan compiles, and it is one this file's own
        // `#if DEBUG` hides from the other.
        /// What every shipping launch gets, and what a debug launch with no
        /// arguments parses to.
        static let production = Self()

        private init() {
            isUITesting = false
            screen = .trails
            seededTrailCount = 0
            holdsTrail = false
            followFraction = nil
            watchRecording = nil
            phoneRecording = nil
            queuedWalkCount = 0
        }

        #if DEBUG
        private static let uiTestingArgument = "--ui-testing"
        private static let screenPrefix = "--ui-test-screen="
        private static let seedTrailsPrefix = "--ui-test-seed-trails="
        private static let withholdTrailArgument = "--ui-test-withhold-trail"
        private static let followPrefix = "--ui-test-follow="
        private static let recordingPrefix = "--ui-test-recording="
        private static let phoneRecordingPrefix = "--ui-test-phone-recording="
        private static let queuedWalksPrefix = "--ui-test-queued-walks="

        /// Enough to fill a 49 mm list and leave it scrollable, and few enough
        /// that the seeding is not what a launch spends its time on. The real
        /// ceiling is ``WatchLibraryDigest/hikeBudget``, which is 50 — a
        /// screenshot wants a list that looks like a library, not one.
        private static let maximumSeededTrails = 12
        /// As many as the footer has a sentence for. Past two it says "N
        /// walks" and the exact N is not what the frame is about.
        private static let maximumQueuedWalks = 9

        /// - Parameter arguments: the process arguments to parse.
        init(arguments: [String]) {
            // Whole-self assignment before any stored property is written,
            // rather than a `--ui-testing` check repeated at every use: every
            // flag below is inert without it, and a `Configuration` that
            // parsed them anyway would be a set of fixtures one missing
            // argument away from a shipping launch.
            guard arguments.contains(Self.uiTestingArgument) else {
                self = .production
                return
            }
            isUITesting = true
            screen = Self.value(of: Self.screenPrefix, in: arguments)
                .flatMap(Screen.init(rawValue:)) ?? .trails
            // A launch that named a screen other than the list wants a trail
            // to look at, so the library is seeded unless it was asked for
            // empty. Spelling `--ui-test-seed-trails=6` on every frame would
            // be a default written out six times.
            let requestedTrails = Self.value(of: Self.seedTrailsPrefix, in: arguments)
                .flatMap(Int.init)
            seededTrailCount = min(max(requestedTrails ?? 6, 0), Self.maximumSeededTrails)
            // A map or a figures frame is a trail already fetched, and they
            // are the only two screens that draw one — so the flag has to be
            // an opt-*out*. An opt-in could never reach the screen it exists
            // for: the two that would show the waiting state are the two that
            // already imply the trail is here.
            holdsTrail = (screen == .map || screen == .figures)
                && !arguments.contains(Self.withholdTrailArgument)
            followFraction = Self.value(of: Self.followPrefix, in: arguments)
                .flatMap(Double.init)
                .map { min(max($0, 0), 1) }
            watchRecording = Self.value(of: Self.recordingPrefix, in: arguments)
                .flatMap(RecordingState.init(rawValue:))
            phoneRecording = Self.value(of: Self.phoneRecordingPrefix, in: arguments)
                .flatMap(RecordingState.init(rawValue:))
            let requestedWalks = Self.value(of: Self.queuedWalksPrefix, in: arguments)
                .flatMap(Int.init)
            queuedWalkCount = min(max(requestedWalks ?? 0, 0), Self.maximumQueuedWalks)
        }

        /// The text after a `--flag=` prefix, or `nil` when no argument
        /// carried it. Last one wins, which is how a shell flag behaves and
        /// what lets the script append an override rather than rebuild its
        /// argument list.
        private static func value(of prefix: String, in arguments: [String]) -> String? {
            arguments.last { $0.hasPrefix(prefix) }
                .map { String($0.dropFirst(prefix.count)) }
        }
        #endif
    }

    /// How this process was launched.
    static let configuration: Configuration = {
        #if DEBUG
        Configuration(arguments: ProcessInfo.processInfo.arguments)
        #else
        .production
        #endif
    }()
}
