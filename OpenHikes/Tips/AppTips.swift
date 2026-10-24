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
//  hike are for a new hiker. TipKit cannot tell a first install from an
//  update, but the library can: a hiker who has a hike has found those
//  buttons. Who is new is ``CreationTipsAudience``'s decision, made once and
//  kept in TipKit's store beside the tips (``isNewHiker``). For an existing
//  hiker the two are retired, rather than merely not drawn, because an
//  ordered group keeps offering the first tip nobody has retired: left alone,
//  it would offer *Record a Hike* to a map that never draws it and never
//  reach the *Community* tab's. That tip, its pill's and the recording
//  screen's are for anybody who has not used those features yet, existing
//  hikers included.
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
    private static let logger = Logger(subsystem: "OpenHikes", category: "Tips")

    /// Whether this hiker began their first hike from the map's pill — see
    /// ``CreationTipsAudience``. A TipKit parameter, so it is kept in the
    /// store the tips are: a launch from an empty store, as every
    /// `--ui-test-tips` one is, starts undecided too.
    ///
    /// Spelled out as `@Parameter` would write it, because the macro cannot
    /// be used in a class: its initializer names `Self`.
    private static var isNewHiker = Tips.Parameter(AppTips.self, "+isNewHiker", false)

    /// The main screen's: *Record a Hike*, *Make a Trail*, the *Community*
    /// tab, then its *Search this area* pill — see ``MapTipPlacement`` and
    /// ``CommunityTabTipView`` for where each one is drawn.
    let main: TipGroup
    /// The recording screen's: *Add Place*, then *Places Nearby* beside it.
    let recording: TipGroup
    /// Who the two tips about making a hike are for, which the map's cards
    /// wait on — see ``libraryDidLoad(holdsAHike:)`` and
    /// ``pillUsed(retiring:)``.
    private(set) var creationAudience: CreationTipsAudience

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
        creationAudience = CreationTipsAudience(isNewHiker: Self.isNewHiker.wrappedValue)
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

    /// Hears whether the hiker's list holds a hike, and retires the two tips
    /// about making one for good when that says this is an existing hiker —
    /// see ``CreationTipsAudience/libraryDidLoad(holdsAHike:)``.
    func libraryDidLoad(holdsAHike: Bool) {
        var audience = creationAudience
        let retires = audience.libraryDidLoad(holdsAHike: holdsAHike)
        // Assigned whole, so a report that changes nothing is a write the map
        // never hears.
        creationAudience = audience
        guard retires else { return }
        used(RecordHikeTip())
        used(MakeTrailTip())
    }

    /// Retires `tip`, one of the two about the pill's buttons, because its
    /// button has just been tapped — and on a list with nothing in it keeps,
    /// for good, that this is a new hiker, so the hike they are making
    /// retires neither. See ``CreationTipsAudience/pillUsed()``.
    func pillUsed(retiring tip: some Tip) {
        var audience = creationAudience
        if audience.pillUsed() {
            Self.isNewHiker.wrappedValue = true
        }
        creationAudience = audience
        used(tip)
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
