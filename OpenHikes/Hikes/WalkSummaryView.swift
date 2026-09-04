//
//  WalkSummaryView.swift
//  OpenHikes
//
//  What one walk came to: the trail, the date and the active time, the
//  coverage with its bar, the furthest point, and the trail's own distance
//  and ascent for context.
//
//  Small on purpose. No elevation chart of its own — the trail's is one
//  segment away — and one action, *Show on Map*, which draws the covered
//  stretches over the route through ``WalkHighlight``.
//

import CoreLocation
import SwiftUI

struct WalkSummaryView: View {
    let walk: HikeWalk
    /// Where *Show on Map* puts the covered stretches — see ``WalkHighlight``.
    let walkHighlight: WalkHighlight
    let mapController: MapController
    /// Told when the covered stretches have been drawn, so the sheet can get
    /// out of the way of the map it just changed.
    var onShowOnMap: () -> Void = { /* no-op default */ }

    /// The trail's profile, built once off the main actor: the route is
    /// walked for it, and a summary is not the place to pay that on the
    /// frame that pushed it. It answers all three questions this screen has
    /// of the route — the ascent it shows, whether the trail is still the one
    /// the walk was walked along, and the geometry *Show on Map* draws the
    /// covered stretches over.
    @State private var profile: RouteProfile?
    /// Bumped by *Show on Map*, so the drawing runs as a `.task` the view
    /// owns rather than as a `Task` that outlives it — see ``showOnMap()``.
    @State private var showOnMapRequest = 0

    private var hike: Hike? { walk.hike }
    private var tint: Color { hike?.tintOpaque ?? .green }
    private var percent: Int { Int((walk.coveredFraction * 100).rounded()) }
    private var ascentMeters: Double? { profile?.elevation.gainMeters }

    /// Whether the trail on screen is still the one this walk was walked
    /// along. The stretches are measured in metres from the start of *that*
    /// route, so a route re-imported or edited since would draw them against
    /// the wrong geometry. `false` while the profile is still being built:
    /// there is nothing to draw along yet either way.
    private var routeMatchesWalk: Bool {
        guard let profile else { return false }
        return abs(profile.totalDistanceMeters - walk.routeDistanceMeters) < 1
    }

    /// The same disagreement, once it is known to be one rather than a
    /// profile that has not arrived — which is what the button explains.
    private var trailHasChanged: Bool { profile != nil && !routeMatchesWalk }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                completion
                statsGrid
                showOnMapButton
            }
            .padding()
        }
        .navigationTitle("Walk Summary")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: walk.id) {
            guard let route = hike?.route, !route.isEmpty else { return }
            profile = await Self.profile(of: route)
        }
        // A `.task` rather than the unstructured `Task` the button used to
        // start: that one outlived this view, and a walker who backed out and
        // opened another trail during the await had the old walk's stretches
        // drawn over it by a task nothing could stop. This one is cancelled
        // when the summary goes away.
        .task(id: showOnMapRequest) {
            guard showOnMapRequest > 0 else { return }
            await showOnMap()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let hike {
                HikeHeaderSymbol(hike: hike)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(hike?.displayTitle ?? "Walk")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(walk.startedAt.formatted(date: .complete, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// The figure the summary leads with. Spoken as a value rather than
    /// drawn as a bar: "62 percent complete, 3.5 km remaining".
    private var completion: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(percent)%")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(WalkRow.outcome(walk.endReason))
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            ProgressView(value: walk.coveredFraction)
                .progressViewStyle(.linear)
                .tint(tint)
            Text("\(Self.length(walk.uncoveredMeters)) of the trail not walked")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Completion")
        .accessibilityValue("\(percent) percent complete, \(Self.length(walk.uncoveredMeters)) remaining")
        .accessibilityIdentifier("walk-completion")
    }

    private var statsGrid: some View {
        StatGrid {
            StatTile(label: "Active Time", value: HikeFormat.duration(walk.activeSeconds))
            StatTile(label: "Furthest Point", value: Self.length(walk.furthestDistanceMeters))
            StatTile(label: "Trail Distance", value: Self.length(walk.routeDistanceMeters))
            if let ascentMeters {
                StatTile(
                    label: "Trail Ascent",
                    value: HikeFormat.length(Measurement(value: ascentMeters, unit: UnitLength.meters))
                )
            }
            StatTile(label: "Started", value: HikeFormat.timestamp(walk.startedAt))
            StatTile(label: "Ended", value: HikeFormat.timestamp(walk.endedAt))
        }
    }

    /// *Show on Map*, and the one case where it cannot draw.
    ///
    /// The length disagreement is a state the button is in, not something the
    /// tap discovers: it used to stay live on a re-imported route, return
    /// silently, and leave the walker tapping a control that did nothing and
    /// explained nothing.
    private var showOnMapButton: some View {
        VStack(spacing: 8) {
            Button("Show on Map", systemImage: "map") {
                showOnMapRequest += 1
            }
            .prominentGlassButtonStyle()
            .tint(tint)
            .frame(maxWidth: .infinity)
            .disabled(hike == nil || walk.coverage.ranges.isEmpty || !routeMatchesWalk)
            .accessibilityIdentifier("walk-show-on-map")
            if trailHasChanged {
                Text("This trail has changed since the walk, so the stretches "
                    + "it covered can no longer be drawn along it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("walk-trail-changed")
            }
        }
    }

    /// Draws the covered stretches over the route and fits the map to it.
    private func showOnMap() async {
        guard routeMatchesWalk, let profile else { return }
        let segments = await WalkHighlight.segments(covering: walk.coverage.ranges, along: profile)
        // The await above is where a selection change gets in. Cancellation
        // is what this view's lifetime speaks through, so it is asked again
        // here rather than only before the await.
        guard !Task.isCancelled else { return }
        walkHighlight.show(segments)
        mapController.fitToRoute()
        onShowOnMap()
    }

    @concurrent
    private static func profile(of route: [RouteCoordinate]) async -> RouteProfile {
        RouteProfile(route: route)
    }

    private static func length(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }
}
