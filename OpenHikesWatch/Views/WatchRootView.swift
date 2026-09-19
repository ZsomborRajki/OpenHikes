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
//  Nothing at all. It builds two tabs and never touches the model — which is
//  the render-isolation rule taken as far as it goes: a body that reads
//  nothing is re-run by nothing, and both screens below it are free to observe
//  whatever they need without their container being invalidated with them.
//

import SwiftUI

struct WatchRootView: View {
    var body: some View {
        TabView {
            Tab("Trail", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                NavigationStack {
                    TrailListView()
                }
            }
            Tab("Record", systemImage: "record.circle") {
                NavigationStack {
                    WatchRecordingView()
                }
            }
        }
        .tabViewStyle(.verticalPage)
    }
}
