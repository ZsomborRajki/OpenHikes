//
//  AppTips.swift
//  OpenHikes
//
//  The first-run tips: the two queues they wait in, how a launch loads them,
//  and what retires each one.
//
//  Six tips, in two queues. The main screen's four point at what a first
//  launch has nothing else pointing at — the two buttons on the map, and the
//  *Community* tab with its *Search this area* pill — and the recording
//  screen's two at the places feature, which lives in that screen's bar. Each
//  queue is one ordered `TipGroup`, so a screen never shows two tips at once,
//  and a later tip waits until the one before it has been closed or used.
//
//  Everybody sees each tip once, with one exception. The two about making a
//  hike appear only while the library is empty. TipKit cannot tell a first
//  install from an update, but the library can: a hiker who has a hike has
//  found those buttons. They are retired the first time the list loads with
//  anything in it, rather than merely not drawn, because an ordered group
//  keeps offering the first tip nobody has retired: left alone, it would
//  offer *Record a Hike* to a map that never draws it and never reach the
//  *Community* tab's. That tip, its pill's and the recording screen's are for
//  anybody who has not used those features yet, existing hikers included.
//
//  Three kinds of launch get no TipKit at all — see ``TipLaunch``.
//
//  The store is TipKit's own default, in the app's container, and not the App
//  Group. A lock held at suspension is fatal only inside a shared container
//  (`0xdead10cc`), which is what moved the app's own stores out of it, and
//  nothing outside the app reads these tips. Nor is it synced: closing a tip
//  on one device leaves it on another, which costs at most one tip there.
//

import Foundation
import Observation
import os
import SwiftUI
import TipKit

@Observable
final class AppTips {
    /// What the hiker's list was last seen to hold.
    enum Library: Equatable {
        case empty
        case hasHikes
        /// Not yet reported, which the two tips about making a hike treat as
        /// *not empty*: an existing hiker never sees them, not even for the
        /// moment before the list has loaded.
        case notLoaded
    }

    private static let logger = Logger(subsystem: "OpenHikes", category: "Tips")

    /// The main screen's: *Record a Hike*, *Make a Trail*, the *Community*
    /// tab, then its *Search this area* pill — see ``MapTipPlacement`` and
    /// ``CommunityTabTipView`` for where each one is drawn.
    let main: TipGroup
    /// The recording screen's: *Add Place*, then *Places Nearby* beside it.
    let recording: TipGroup
    /// What the hiker's list holds, which the two tips about making a hike
    /// wait on — see ``libraryDidLoad(isEmpty:)``.
    private(set) var library = Library.notLoaded

    /// Built only after TipKit is configured — see ``forThisLaunch(startupIssue:)``.
    private init() {
        main = TipGroup(.ordered) {
            RecordHikeTip()
            MakeTrailTip()
            CommunityTabTip()
            SearchThisAreaTip()
        }
        recording = TipGroup(.ordered) {
            AddPlaceTip()
            PlacesNearbyTip()
        }
    }

    /// Loads TipKit for this launch, or returns `nil` for a launch that shows
    /// no tips.
    ///
    /// Once per process, before any view exists: TipKit has to be configured
    /// before a tip is drawn, and configuring it twice is an error.
    static func forThisLaunch(startupIssue: StorageStartupIssue?) -> AppTips? {
        let location: Tips.ConfigurationOption.DatastoreLocation
        switch TipLaunch(
            isHostingTests: AppLaunchEnvironment.isHostingTests,
            isUITesting: AppLaunchEnvironment.isUITesting,
            showsTips: AppLaunchEnvironment.showsTips,
            storeFailed: startupIssue != nil
        ) {
        case .fresh:
            guard let directory = AppLaunchEnvironment.tipDatastoreDirectory() else { return nil }
            location = .url(directory)
        case .live:
            location = .applicationDefault
        case .off:
            return nil
        }
        do {
            try Tips.configure([.displayFrequency(.immediate), .datastoreLocation(location)])
        } catch {
            logger.error("TipKit did not load: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return AppTips()
    }

    /// Hears what the hiker's list holds, and retires the two tips about
    /// making a hike for good the first time it holds anything.
    func libraryDidLoad(isEmpty: Bool) {
        let reported = isEmpty ? Library.empty : .hasHikes
        guard library != reported else { return }
        library = reported
        guard !isEmpty else { return }
        used(RecordHikeTip())
        used(MakeTrailTip())
    }

    /// Retires `tip` for good, because the hiker has done what it is about.
    func used(_ tip: some Tip) {
        tip.invalidate(reason: .actionPerformed)
    }
}

/// Whether a launch gets the first-run tips at all, and from which store.
nonisolated enum TipLaunch: Equatable {
    /// UI automation that asked for tips with `--ui-test-tips`: a store of its
    /// own, empty, so the launch sees what a first one does whatever an earlier
    /// run closed, and the simulator app's own tips are left alone.
    case fresh
    /// Every launch a hiker makes: TipKit's own store, in the app's container.
    case live
    /// No TipKit at all.
    ///
    /// For a launch hosting a test bundle, because a suite never reaches the
    /// app's singletons and TipKit's store is one. For UI automation that did
    /// not ask, so every other UI test and the App Store screenshots run
    /// exactly as they did. And for a launch whose store failed to open, whose
    /// empty library says nothing about whether the hiker is new.
    case off

    init(isHostingTests: Bool, isUITesting: Bool, showsTips: Bool, storeFailed: Bool) {
        if isHostingTests || storeFailed {
            self = .off
        } else if isUITesting {
            self = showsTips ? .fresh : .off
        } else {
            self = .live
        }
    }
}

// `nonisolated` for the reason the sheet-depth key's extension is: `@Entry`
// writes its key as a type nested in this extension. See *Concurrency* in
// `AGENTS.md`.
nonisolated extension EnvironmentValues {
    /// The first-run tips, or `nil` for a launch that shows none — set once, by
    /// the app's root view, and read by the screens that draw one. Absent from
    /// every preview and every suite, which is the point of a default.
    @Entry var appTips: AppTips?
}
