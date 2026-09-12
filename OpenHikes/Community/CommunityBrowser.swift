//
//  CommunityBrowser.swift
//  OpenHikes
//
//  The published hikes the sheet is currently showing, and the one place that
//  decides when to go and get more of them.
//
//  A stable `@Observable` reference type, held by ``OpenHikesModel`` and
//  handed down, for the same reason ``MapController`` and ``SearchCompleter``
//  are: the map feeds it a region on every pan, and a SwiftUI body that read
//  that region would re-run at gesture frequency. So the region is
//  `@ObservationIgnored` and the *results* are not — a list re-drawing when
//  its contents change is the whole job, while a list re-drawing because the
//  map moved two streets is the cost render isolation exists to refuse.
//
//  ## Why the map drives this at all
//
//  Because a hike is a place before it is a name. A walker looking for
//  somewhere to go on Saturday pans to the hills they can drive to, and
//  typing the name of a trail they have never heard of is not something they
//  can do. The map is the query.
//
//  What that must not become is a request per pan. ``CommunityQueryPolicy``
//  holds the thresholds and the reasoning; this type holds the concurrency,
//  and the rule there is that a newer region *supersedes* an older one rather
//  than racing it. Two overlapping round trips can land in either order, and
//  the older one landing second would leave the list describing a region the
//  map has already left — the same hazard ``CloudSyncCoordinator`` chains its
//  account checks to avoid.
//

import CoreLocation
import Foundation
import MapKit
import Observation
import os

/// What the community section is currently able to say.
enum CommunityBrowseState: Equatable {
    case failed(CommunityFailure)
    /// Nothing has been asked for. The chip has not been tapped, or it has
    /// just been switched off.
    case idle
    /// The last request finished. An empty list here means "nowhere near
    /// here", which is a real answer and not a failure.
    case loaded
    /// A request is in flight and there is nothing to show yet. Distinct from
    /// ``refreshing`` because only one of the two should replace the list with
    /// a spinner.
    case loading
    /// A request is in flight over results that are already on screen.
    case refreshing
}

@MainActor
@Observable
final class CommunityBrowser {
    /// Non-isolated so releasing the last reference never requires proving we
    /// are on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    @ObservationIgnored private static let logger = Logger(
        subsystem: "OpenHikes",
        category: "Community"
    )

    /// How many rows one query asks for. More than fits on a phone, few enough
    /// that a list nobody scrolls to the bottom of does not pay for a second
    /// page — see ``CloudKitCommunityTransport``'s `run`, which deliberately
    /// drops the cursor.
    private static let resultLimit = 25

    /// What the section draws. Read by the sheet, and the reason this type is
    /// observable at all.
    private(set) var listings: [CommunityListing] = []
    private(set) var state: CommunityBrowseState = .idle
    /// Whether the walker has turned the community layer on. Drawn as the
    /// chip's selected state, so it is observed on purpose.
    private(set) var isBrowsing = false

    /// The last region the map settled on.
    ///
    /// Ignored by observation and that is the point: this is written on every
    /// pan, and nothing that draws may depend on it. Held rather than merely
    /// passed through so that tapping the chip can ask about wherever the map
    /// already is, without the chip's call site knowing about the map.
    @ObservationIgnored private var latestRegion: MKCoordinateRegion?
    @ObservationIgnored private var policy = CommunityQueryPolicy()
    @ObservationIgnored private let transport: (any CommunityTransporting)?
    @ObservationIgnored private var requestTask: Task<Void, Never>?

    /// - Parameter transport: `nil` for a launch that must not reach CloudKit
    ///   — a hosted test bundle, or UI automation. Every entry point is then a
    ///   no-op, in the same shape ``HikeLiveActivityController`` is absent for
    ///   those launches rather than stubbed.
    init(transport: (any CommunityTransporting)?) {
        self.transport = transport
    }

    /// Requests that reached the transport. The policy above is what makes
    /// this smaller than the number of pans, and this is what proves it.
    @ObservationIgnored private(set) var issuedRequests = 0

    /// Whether this launch can reach the community at all.
    ///
    /// False for a hosted suite or UI automation — see
    /// ``OpenHikesModel/makeCommunityTransport()``. The chip and the share
    /// button are *absent* rather than disabled when it is false, because a
    /// disabled control is a promise to do something later and this launch is
    /// never going to.
    var hasTransport: Bool { transport != nil }

    // MARK: - The map

    /// The map came to rest. Called from `MapView.Coordinator`, never from a
    /// SwiftUI body.
    ///
    /// Cheap by contract: while browsing is off this stores a value and
    /// returns, which is what lets it sit on `regionDidChangeAnimated`
    /// alongside the highlight update without costing a walker who has never
    /// used this feature anything at all.
    func regionDidSettle(_ region: MKCoordinateRegion) {
        latestRegion = region
        guard case let .search(coordinate, radius) = policy.action(for: region) else { return }
        search(near: coordinate, radiusMeters: radius)
    }

    // MARK: - The chip

    /// Turns the community layer on and asks about wherever the map is.
    func startBrowsing() {
        guard !isBrowsing else { return }
        policy.startBrowsing()
        isBrowsing = true
        guard let latestRegion else {
            // The map has not reported a region yet — a sheet opened before the
            // first `regionDidChangeAnimated`. Nothing to ask about, and the
            // next settle will ask, because the policy has no remembered query.
            state = .loading
            return
        }
        guard case let .search(coordinate, radius) = policy.action(for: latestRegion) else {
            // Zoomed out past the ceiling. Saying so is better than an empty
            // list, which would read as "there are none near you".
            state = .loaded
            return
        }
        search(near: coordinate, radiusMeters: radius)
    }

    func stopBrowsing() {
        policy.stopBrowsing()
        isBrowsing = false
        requestTask?.cancel()
        requestTask = nil
        listings = []
        state = .idle
    }

    func toggleBrowsing() {
        if isBrowsing {
            stopBrowsing()
        } else {
            startBrowsing()
        }
    }

    /// Asks again about the current region, ignoring the thresholds.
    ///
    /// What a failed request needs: the policy remembers a query that produced
    /// nothing, so without forgetting it first the same region would never be
    /// asked about again and the walker's only recourse would be to pan away
    /// and back.
    func retry() {
        guard isBrowsing, let latestRegion else { return }
        policy.forgetLastQuery()
        regionDidSettle(latestRegion)
    }

    // MARK: - The search field

    /// Published hikes whose title matches a typed query.
    ///
    /// Separate from the location path and deliberately not gated by the chip:
    /// somebody who types a trail's name has asked for it by name, wherever
    /// they are and whether or not they have turned the map layer on.
    func search(matching query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            requestTask?.cancel()
            requestTask = nil
            // The two searches write to one list, so clearing the field cannot
            // just stop: the title matches would still be there, now drawn
            // under the *Nearby* heading and describing a query nobody is
            // running. While browsing, the map's own question is asked again;
            // otherwise there is nothing left to show.
            guard isBrowsing, let latestRegion else {
                listings = []
                return
            }
            policy.forgetLastQuery()
            regionDidSettle(latestRegion)
            return
        }
        perform(describing: "a title search") { transport in
            try await transport.listings(matching: trimmed, limit: Self.resultLimit)
        }
    }

    // MARK: - Requests

    private func search(near coordinate: CLLocationCoordinate2D, radiusMeters: Double) {
        perform(describing: "a nearby search") { transport in
            try await transport.listings(
                near: coordinate,
                radiusMeters: radiusMeters,
                limit: Self.resultLimit
            )
        }
    }

    /// Runs one request, superseding whatever was in flight.
    ///
    /// The new task awaits the old one before doing anything, which is what
    /// makes "supersede" true rather than merely likely: cancelling a task
    /// asks it to stop and does not stop it, so two results could otherwise
    /// still land in either order and the stale one could land last.
    private func perform(
        describing reason: String,
        _ work: @escaping @Sendable (any CommunityTransporting) async throws -> [CommunityListing]
    ) {
        guard let transport else { return }
        issuedRequests += 1
        state = listings.isEmpty ? .loading : .refreshing
        let previous = requestTask
        previous?.cancel()
        requestTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                let results = try await work(transport)
                guard !Task.isCancelled else { return }
                self?.listings = results
                self?.state = .loaded
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let failure = error as? CommunityFailure
                    ?? .unavailable(error.localizedDescription)
                Self.logger.error(
                    "Community \(reason, privacy: .public) failed: \(failure.localizedDescription, privacy: .public)"
                )
                // The rows already on screen are kept. They were true when they
                // arrived, and replacing a usable list with an error because a
                // pan happened to fail is worse than showing it alongside one.
                self?.state = .failed(failure)
                // And the region that failed is forgotten, so panning back to
                // it asks again rather than being refused as "the same
                // question".
                self?.policy.forgetLastQuery()
            }
        }
    }
}
