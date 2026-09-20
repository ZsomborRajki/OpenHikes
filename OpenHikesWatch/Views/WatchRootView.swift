//
//  WatchRootView.swift
//  OpenHikesWatch
//
//  The two things this app does, side by side: follow a trail the phone sent,
//  and record a walk.
//
//  A `TabView` rather than a list of destinations, because they are peers
//  rather than a hierarchy — a hiker records with no trail selected as often
//  as they follow one — and because a horizontal swipe is what a watch's own
//  apps put a second screen behind.
//
//  ## What this body reads
//
//  Nothing of the model at all. It builds two tabs and never touches it —
//  which is the render-isolation rule taken as far as it goes: a body that
//  reads nothing is re-run by nothing, and both screens below it are free to
//  observe whatever they need without their container being invalidated with
//  them. The tab and the navigation path below are `@State` holding plain
//  values, which is a different thing: they change when the hiker navigates,
//  which is exactly when this should be re-run.
//
//  ## Where a trail is pushed from
//
//  The stack is here and the rows are in ``TrailListView``, so the destination
//  is a *value* rather than a closure. That is what lets a launch open one
//  without a tap — see ``WatchLaunchEnvironment``, whose seeded path is the
//  only reason this is not still a `NavigationLink { }`.
//

import OpenHikesShared
import SwiftUI

/// One trail, as somewhere to navigate to.
///
/// Carries the name as well as the identifier because the screen it opens
/// shows a title before it has any geometry to take one from: the map screen
/// is where a hiker waits for the package to arrive, and "Rinnkendlsteig" over
/// a spinner is a better wait than a blank bar over one.
struct WatchTrailDestination: Hashable {
    let hikeID: UUID
    let name: String
    /// Whether the figures sheet is already up when it opens. Only ever `true`
    /// from a seeded launch; a hiker gets there with the button.
    var showsFigures = false
}

struct WatchRootView: View {
    private enum Tab: Hashable {
        case trail
        case record
    }

    /// Which screen this launch asked to open on. A plain value, resolved once
    /// at launch — never read from the model, so it cannot invalidate anything.
    let screen: WatchLaunchEnvironment.Screen

    @State private var tab: Tab
    @State private var trailPath: [WatchTrailDestination]

    init(screen: WatchLaunchEnvironment.Screen = .trails) {
        self.screen = screen
        _tab = State(initialValue: screen == .record ? .record : .trail)
        _trailPath = State(initialValue: Self.initialPath(for: screen))
    }

    var body: some View {
        TabView(selection: $tab) {
            SwiftUI.Tab(
                "Trail",
                systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                value: Tab.trail
            ) {
                NavigationStack(path: $trailPath) {
                    TrailListView()
                        .navigationDestination(for: WatchTrailDestination.self) { destination in
                            TrailMapScreen(
                                hikeID: destination.hikeID,
                                name: destination.name,
                                initiallyShowingFigures: destination.showsFigures
                            )
                        }
                }
            }
            SwiftUI.Tab("Record", systemImage: "record.circle", value: Tab.record) {
                NavigationStack {
                    WatchRecordingView()
                }
            }
        }
        .tabViewStyle(.verticalPage)
    }

    /// The stack a launch starts with: empty for every real one.
    private static func initialPath(
        for screen: WatchLaunchEnvironment.Screen
    ) -> [WatchTrailDestination] {
        #if DEBUG
        switch screen {
        case .map, .figures:
            return [
                WatchTrailDestination(
                    hikeID: SeededWatchFixture.openTrail.id,
                    name: SeededWatchFixture.openTrail.name,
                    showsFigures: screen == .figures
                ),
            ]
        case .trails, .record:
            return []
        }
        #else
        return []
        #endif
    }
}
