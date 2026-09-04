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

    /// The trail's climb, computed once off the main actor: the route is
    /// walked for it, and a summary is not the place to pay that on the
    /// frame that pushed it.
    @State private var ascentMeters: Double?

    private var hike: Hike? { walk.hike }
    private var tint: Color { hike?.tintOpaque ?? .green }
    private var percent: Int { Int((walk.coveredFraction * 100).rounded()) }

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
            ascentMeters = await Self.ascent(of: route)
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

    private var showOnMapButton: some View {
        Button("Show on Map", systemImage: "map") {
            Task { await showOnMap() }
        }
        .prominentGlassButtonStyle()
        .tint(tint)
        .frame(maxWidth: .infinity)
        .disabled(hike == nil || walk.coverage.ranges.isEmpty)
        .accessibilityIdentifier("walk-show-on-map")
    }

    /// Draws the covered stretches over the route and fits the map to it.
    ///
    /// The route the stretches are measured against is the hike's *current*
    /// one, and `routeDistanceMeters` is the length it had at the time of the
    /// walk. A route re-imported since would draw the stretches against the
    /// wrong geometry, so the two lengths have to agree before anything is
    /// drawn.
    private func showOnMap() async {
        guard let hike else { return }
        let route = hike.route
        let profile = await Self.profile(of: route)
        guard abs(profile.totalDistanceMeters - walk.routeDistanceMeters) < 1 else { return }
        let segments = await WalkHighlight.segments(covering: walk.coverage.ranges, along: profile)
        walkHighlight.show(segments)
        mapController.fitToRoute()
        onShowOnMap()
    }

    @concurrent
    private static func profile(of route: [RouteCoordinate]) async -> RouteProfile {
        RouteProfile(route: route)
    }

    @concurrent
    private static func ascent(of route: [RouteCoordinate]) async -> Double? {
        RouteProfile(route: route).elevation.gainMeters
    }

    private static func length(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }
}
