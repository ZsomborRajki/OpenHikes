//
//  TrailListView.swift
//  OpenHikesWatch
//
//  The hiker's trails, as the phone last described them.
//
//  Rows are ``SharedHikeSummary``s — a name, a date and a length, which is
//  what a picker row shows everywhere else in this project. Tapping one asks
//  the phone for its geometry; the trail that arrives opens as a map in
//  ``TrailMapScreen``.
//

import OpenHikesShared
import SwiftUI

struct TrailListView: View {
    @Environment(WatchModel.self)
    private var model

    var body: some View {
        List {
            if model.library.hikes.isEmpty {
                emptyState
            } else {
                ForEach(model.library.hikes) { hike in
                    // The request is made by the destination rather than by
                    // the row, so a trail opened from anywhere asks the same
                    // way — and so a row is an ordinary `NavigationLink` with
                    // the traits the system gives one.
                    //
                    // A *value* rather than a closure, so the same destination
                    // can be reached by pushing onto the stack's path instead
                    // of by tapping. `WatchRootView` owns the path and the
                    // `navigationDestination` that resolves this.
                    NavigationLink(
                        value: WatchTrailDestination(hikeID: hike.id, name: hike.name)
                    ) {
                        TrailRow(hike: hike)
                    }
                }
            }
            if model.queuedWalkCount > 0 { queuedFooter }
        }
        .navigationTitle("Trails")
    }

    /// Three different absences, said as three different sentences. A hiker
    /// whose phone has never been in range is waiting; one whose library is
    /// genuinely empty has nothing to wait for; one with no companion app has
    /// nothing at all. Drawing one spinner for all three is how a watch comes
    /// to look broken when it is working.
    @ViewBuilder private var emptyState: some View {
        if !model.link.isCompanionInstalled {
            ContentUnavailableView(
                "No OpenHikes on Your iPhone",
                systemImage: "iphone.slash",
                description: Text("Install OpenHikes on the iPhone paired with this watch to send trails across.")
            )
        } else if model.library.sentAt == .distantPast {
            // Two sentences, because the two cases want different things from
            // the hiker. In range, the watch has already asked and the honest
            // report is that it is waiting for an answer — telling somebody to
            // open an app they have open is how this screen used to be wrong.
            // Out of range there is nothing to wait for yet, and bringing the
            // phone closer is the whole of what helps.
            ContentUnavailableView(
                "Waiting for Your iPhone",
                systemImage: "antenna.radiowaves.left.and.right",
                description: Text(
                    model.link.isReachable
                        ? "Asking your iPhone for your trails…"
                        : "Bring your iPhone nearby, with OpenHikes installed, to send your trails over."
                )
            )
        } else {
            ContentUnavailableView(
                "No Trails Yet",
                systemImage: "map",
                description: Text("Import a GPX file or record a hike on your iPhone, and it will appear here.")
            )
        }
    }

    private var queuedFooter: some View {
        Label {
            Text(
                model.queuedWalkCount == 1
                    ? "1 walk waiting for your iPhone"
                    : "\(model.queuedWalkCount) walks waiting for your iPhone"
            )
            .font(.footnote)
        } icon: {
            Image(systemName: "arrow.up.circle")
        }
        .foregroundStyle(.secondary)
    }
}

/// One trail, as a row.
///
/// One accessibility element rather than three, which is the rule the app's
/// `HikeRow` follows and for the same reason: a row read out as three
/// fragments is three swipes to hear one trail.
private struct TrailRow: View {
    let hike: SharedHikeSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(hike.name)
                .font(.headline)
                .lineLimit(2)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let day = hike.date.formatted(date: .abbreviated, time: .omitted)
        return "\(day) · \(WidgetFormat.length(meters: hike.distanceMeters))"
    }
}
