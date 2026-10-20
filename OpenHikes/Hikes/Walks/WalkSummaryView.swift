//
//  WalkSummaryView.swift
//  OpenHikes
//
//  What one walk came to: the trail, the date and the active time, the
//  coverage with its bar, the furthest point, and the trail's own distance
//  and ascent for context.
//
//  Small on purpose. No elevation chart of its own — the trail's is one
//  segment away — and two actions: *Show on Map*, which draws the covered
//  stretches over the route through ``WalkHighlight``, and *Share* in the
//  bar, which puts the walk's figures and line over a photograph — see
//  ``WalkShareFlow``.
//

import CoreLocation
import OpenHikesData
import SwiftUI

struct WalkSummaryView: View {
    let walk: HikeWalk
    /// Where *Show on Map* puts the covered stretches — see ``WalkHighlight``.
    let walkHighlight: WalkHighlight
    let mapController: MapController
    /// The share card, kept by the sheet rather than here: a rotation
    /// replaces this view, and the card has to outlive it — see
    /// ``WalkShareSession``.
    @Bindable var share: WalkShareSession
    /// Told when the covered stretches have been drawn, so the sheet can get
    /// out of the way of the map it just changed.
    var onShowOnMap: () -> Void = { /* no-op default */ }

    /// The trail as this screen reads it, built off the main actor: the
    /// route is walked for it, and a summary is not the place to pay that on
    /// the frame that pushed it. It answers all three questions this screen
    /// has of the route — the ascent it shows, whether the trail is still the
    /// one the walk was walked along, and the geometry *Show on Map* draws the
    /// covered stretches over.
    @State private var trail: WalkSummaryTrail?
    /// Bumped by *Show on Map*, so the drawing runs as a `.task` the view
    /// owns rather than as a `Task` that outlives it — see ``showOnMap()``.
    @State private var showOnMapRequest = 0
    /// The lead percentage, in points at the default text size. Scaled with
    /// `.largeTitle` so it keeps pace with the `.headline` label beside it.
    @ScaledMetric(relativeTo: .largeTitle) private var figureSize = 44.0

    private var hike: Hike? { walk.hike }
    private var tint: Color { hike?.tintOpaque ?? .green }
    private var percent: Int { Int((walk.coveredFraction * 100).rounded()) }
    private var profile: RouteProfile? {
        guard let trail, trail.key == WalkSummaryRouteKey(walk: walk) else { return nil }
        return trail.profile
    }
    private var ascentMeters: Double? { profile?.elevation.gainMeters }

    /// Whether the trail on screen is still the one this walk was walked
    /// along. The stretches are measured in metres from the start of *that*
    /// route, so a route re-imported or edited since would draw them against
    /// the wrong geometry — and the line, not its length, is what says so: a
    /// reversed route is as long as it was. `false` while the profile is
    /// still being built: there is nothing to draw along yet either way.
    private var routeMatchesWalk: Bool {
        guard let trail else { return false }
        return trail.matches(walk)
    }

    /// The same disagreement, once it is known to be one rather than a
    /// profile that has not arrived — which is what the button explains.
    private var trailHasChanged: Bool { profile != nil && !routeMatchesWalk }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                completion
                statsSummary
                showOnMapButton
            }
            .padding()
        }
        .navigationTitle("Hike Summary")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // Waits for the profile: the card's line is drawn from it.
                Button("Share", systemImage: "square.and.arrow.up") { share.start() }
                    .disabled(profile == nil)
                    .accessibilityIdentifier("walk-share")
            }
        }
        // From the sheet's contents, never beside it — see *Repository-specific
        // conventions* in the repository instructions.
        // A rotation takes this view away with the cover still meant to be
        // up, so only a dismissal that cleared the flag closes the session.
        .fullScreenCover(isPresented: $share.isPresented, onDismiss: share.closed) {
            WalkShareFlow(walk: walk, trail: profile, trailMatchesWalk: routeMatchesWalk, session: share)
        }
        // Keyed on the line as well as the walk, for the reason
        // ``HikeDetailRouteKey`` gives: *Edit Route* keeps the hike and
        // replaces its route, here or on another device while this screen is
        // up, and keyed on the walk alone the summary went on drawing the
        // stretches along the line that was replaced.
        .task(id: WalkSummaryRouteKey(walk: walk)) {
            let key = WalkSummaryRouteKey(walk: walk)
            // Clear an outdated line only when one exists: writing nil over
            // nil rebuilds the summary without changing what it can show.
            if let preparedKey = trail?.key, preparedKey != key { trail = nil }
            guard !key.route.isEmpty else { return }
            guard let prepared = try? await WalkSummaryTrail.prepare(along: key),
                  !Task.isCancelled,
                  key == WalkSummaryRouteKey(walk: walk) else { return }
            trail = prepared
        }
        // A `.task` rather than the unstructured `Task` the button used to
        // start: that one outlived this view, and a hiker who backed out and
        // opened another trail during the await had the old walk's stretches
        // drawn over it by a task nothing could stop. This one is cancelled
        // when the summary goes away.
        .task(id: showOnMapRequest) {
            guard showOnMapRequest > 0 else { return }
            await showOnMap()
        }
    }

    /// The place-card title row the hike detail opens with.
    private var header: some View {
        PlaceCardHeader {
            if let hike {
                HikeHeaderSymbol(hike: hike)
            }
        } title: {
            Text(hike?.displayTitle ?? "Hike")
                .accessibilityAddTraits(.isHeader)
        } subtitle: {
            Text(walk.startedAt.formatted(date: .complete, time: .shortened))
        }
    }

    /// The figure the summary leads with. Spoken as a value rather than
    /// drawn as a bar: "62 percent complete, 3.5 km remaining".
    private var completion: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(percent)%")
                    .font(.system(size: figureSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(WalkRow.outcome(walk.endReason))
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            ProgressView(value: walk.coveredFraction)
                .progressViewStyle(.linear)
                .tint(tint)
            if let left = Self.leftUnhiked(walk.uncoveredMeters) {
                Text("\(Self.length(left)) of the trail not hiked")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Completion")
        .accessibilityValue(spokenCompletion)
        .accessibilityIdentifier("walk-completion")
    }

    /// The completion as VoiceOver reads it, with the remainder only when
    /// there is one — the same rule ``leftUnhiked(_:)`` sets for the caption.
    private var spokenCompletion: Text {
        if let left = Self.leftUnhiked(walk.uncoveredMeters) {
            Text("\(percent) percent complete, \(Self.length(left)) remaining")
        } else {
            Text("\(percent) percent complete")
        }
    }

    /// The part of the trail a walk did not cover, or `nil` when it left none.
    ///
    /// A walk that covered all of it used to say so anyway, as "0 m of the
    /// trail not hiked" under *100% Completed* — a sentence about nothing,
    /// which read like a bug. Under a metre is none: the formatter would print
    /// it as zero.
    nonisolated static func leftUnhiked(_ uncoveredMeters: Double) -> Double? {
        uncoveredMeters >= 1 ? uncoveredMeters : nil
    }

    /// The walk's own two figures in the strip, and the trail's and the
    /// clock's in the list under them.
    private var statsSummary: some View {
        var stats = [
            Stat("Active Time", HikeFormat.duration(walk.activeSeconds), headline: true),
            Stat("Furthest Point", Self.length(walk.furthestDistanceMeters), headline: true),
            Stat("Trail Distance", Self.length(walk.routeDistanceMeters)),
        ]
        if let ascentMeters {
            stats.append(Stat(
                "Trail Ascent",
                HikeFormat.elevation(Measurement(value: ascentMeters, unit: UnitLength.meters))
            ))
        }
        stats.append(Stat("Started", HikeFormat.timestamp(walk.startedAt)))
        stats.append(Stat("Ended", HikeFormat.timestamp(walk.endedAt)))
        return StatSummary(stats: stats)
    }

    /// *Show on Map*, and the one case where it cannot draw.
    ///
    /// The route disagreement is a state the button is in, not something the
    /// tap discovers: it used to stay live on a re-imported route, return
    /// silently, and leave the hiker tapping a control that did nothing and
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
                Text("This trail has changed since the hike, so the stretches "
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
        guard let trail, let segments = try? await trail.coveredSegments(of: walk) else { return }
        walkHighlight.show(segments)
        mapController.fitToRoute()
        onShowOnMap()
    }

    private static func length(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }
}

/// The line a walk summary was prepared from, and so what its `.task(id:)` is
/// keyed on — the route itself, for the cost reasons ``HikeDetailRouteKey``
/// gives.
nonisolated struct WalkSummaryRouteKey: Equatable, Sendable {
    let walkID: UUID
    let route: [RouteCoordinate]

    @MainActor
    init(walk: HikeWalk) {
        walkID = walk.id
        route = walk.hike?.route ?? []
    }
}

/// The current trail, as a walk summary needs it: its profile, and the
/// ``TrailWalkRecord/routeRevision(of:)`` the walk is compared against.
nonisolated struct WalkSummaryTrail: Sendable {
    let key: WalkSummaryRouteKey
    let profile: RouteProfile
    let revision: String

    @concurrent
    static func prepare(along key: WalkSummaryRouteKey) async throws(CancellationError) -> Self {
        assertOffMainThread("Walk summary route preparation must stay off the main thread")
        let built = try RouteProfile.cancellable(route: key.route)
        let signature = TrailWalkRecord.routeRevision(of: key.route)
        guard !Task.isCancelled else { throw CancellationError() }
        return Self(
            key: key,
            profile: built,
            revision: signature
        )
    }

    /// The prepared line must still be current as well as the walk's own.
    /// A route edit can arrive before SwiftUI restarts its preparation task.
    @MainActor
    func matches(_ walk: HikeWalk) -> Bool {
        key == WalkSummaryRouteKey(walk: walk) && walk.isAlong(revision: revision)
    }

    /// An edit during the off-main calculation invalidates the request just
    /// as leaving the summary does. Neither may apply its old geometry or
    /// move the camera to a route the calculation was never about.
    @MainActor
    func coveredSegments(
        of walk: HikeWalk,
        using build: ([ClosedRange<Double>], RouteProfile) async -> [[CLLocationCoordinate2D]] = { ranges, profile in
            await WalkHighlight.segments(covering: ranges, along: profile)
        }
    ) async throws(CancellationError) -> [[CLLocationCoordinate2D]] {
        guard matches(walk) else { throw CancellationError() }
        let segments = await build(walk.coverage.ranges, profile)
        guard !Task.isCancelled, matches(walk) else { throw CancellationError() }
        return segments
    }
}
