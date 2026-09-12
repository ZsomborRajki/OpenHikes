import CoreLocation
import Foundation
import MapKit
import Observation
import os

enum CommunityBrowseState: Equatable {
    case failed(CommunityFailure)
    case idle
    case loaded
    case loading
    case refreshing
}

/// Owns committed search results. Map movement only publishes a coarse refresh
/// affordance; it never replaces a query or spends a network request on a pan.
@MainActor
@Observable
final class CommunityBrowser {
    nonisolated deinit { /* intentionally empty */ }

    @ObservationIgnored private static let logger = Logger(subsystem: "OpenHikes", category: "Community")
    private static let resultLimit = 25
    private static let typingDelayMilliseconds = 300
    private static let typingDelay: Duration = .milliseconds(typingDelayMilliseconds)

    // Read-time filtering also removes authors blocked after a request landed.
    var nearbyListings: [CommunityListing] { blockList.excludingBlocked(nearbyResults) }
    var matchingListings: [CommunityListing] { blockList.excludingBlocked(matchingResults) }
    private var nearbyResults: [CommunityListing] = []
    private var matchingResults: [CommunityListing] = []
    private(set) var state: CommunityBrowseState = .idle
    private(set) var matchingState: CommunityBrowseState = .idle
    private(set) var isBrowsing = false
    private(set) var areaChoice: CommunityAreaChoice = .map
    private(set) var needsZoom = false
    private(set) var canSearchThisArea = false

    // Neither SwiftUI nor a GPS update reads or writes the committed circle.
    @ObservationIgnored private var latestRegion: MKCoordinateRegion?
    @ObservationIgnored private(set) var selectedArea: CommunitySearchArea?
    @ObservationIgnored private var policy = CommunityQueryPolicy()
    @ObservationIgnored private let transport: (any CommunityTransporting)?
    @ObservationIgnored let blockList: CommunityBlockList
    @ObservationIgnored private var nearbyTask: Task<Void, Never>?
    @ObservationIgnored private var matchTask: Task<Void, Never>?
    @ObservationIgnored private var titleQuery = ""
    @ObservationIgnored private var titleUsesArea = false
    @ObservationIgnored private var hasCommittedArea = false
    @ObservationIgnored private(set) var issuedRequests = 0
    @ObservationIgnored private(set) var requestsInFlight = 0

    init(transport: (any CommunityTransporting)?, blockList: CommunityBlockList) {
        self.transport = transport
        self.blockList = blockList
    }

    var hasTransport: Bool { transport != nil }

    func regionDidSettle(_ region: MKCoordinateRegion) {
        latestRegion = region
        guard isBrowsing else { return }
        if !hasCommittedArea, areaChoice == .map {
            selectArea(.map)
        } else {
            updateMapAffordance()
        }
    }

    func startBrowsing() {
        guard hasTransport, !isBrowsing else { return }
        isBrowsing = true
        if !hasCommittedArea, areaChoice == .map {
            selectArea(.map)
        } else {
            refreshNearby()
            updateMapAffordance()
        }
    }

    func stopBrowsing() {
        isBrowsing = false
        nearbyTask?.cancel()
        nearbyTask = nil
        nearbyResults = []
        state = .idle
        canSearchThisArea = false
    }

    /// Commits the area only on an explicit action, or the first map delivery
    /// after the user selects Community before MapKit has supplied a region.
    func selectArea(_ choice: CommunityAreaChoice, region: MKCoordinateRegion? = nil) {
        areaChoice = choice
        let committedRegion = choice == .map ? latestRegion : region
        selectedArea = committedRegion.flatMap(CommunitySearchArea.init(region:))
        hasCommittedArea = choice != .map || committedRegion != nil
        needsZoom = choice != .anywhere && committedRegion != nil && selectedArea == nil
        policy.startBrowsing()
        if let committedRegion { _ = policy.action(for: committedRegion) }
        nearbyTask?.cancel()
        nearbyResults = []
        state = .idle
        if isBrowsing { refreshNearby() }
        if titleUsesArea { search(matching: titleQuery, inSelectedArea: true) }
        updateMapAffordance()
    }

    func searchThisArea() {
        selectArea(.map)
    }

    /// Retry the committed question, even if the map has moved since it failed.
    func retry() {
        guard isBrowsing else { return }
        refreshNearby()
    }

    func retryTitleSearch() {
        search(matching: titleQuery, inSelectedArea: titleUsesArea)
    }

    func refreshAfterBlock() {
        if isBrowsing, !nearbyResults.isEmpty, nearbyListings.isEmpty { retry() }
        if !matchingResults.isEmpty, matchingListings.isEmpty { retryTitleSearch() }
    }

    func search(matching query: String, inSelectedArea: Bool = false) {
        titleQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        titleUsesArea = inSelectedArea
        matchTask?.cancel()
        // Old title matches never appear under a new query, including failures.
        matchingResults = []
        matchingState = .idle
        guard !titleQuery.isEmpty else {
            if isBrowsing, state == .idle { refreshNearby() }
            return
        }
        let area = inSelectedArea && areaChoice != .anywhere ? selectedArea : nil
        guard !inSelectedArea || areaChoice == .anywhere || area != nil else { return }
        let fragment = titleQuery
        let excluded = blockList.blockedIDs
        perform(.title) { transport in
            try await transport.listings(matching: fragment, area: area, limit: Self.resultLimit, excluding: excluded)
        }
    }

    private func updateMapAffordance() {
        guard isBrowsing, let latestRegion, CommunitySearchArea(region: latestRegion) != nil else {
            canSearchThisArea = false
            return
        }
        // Probe a copy: only the user's next commit advances the remembered area.
        var candidate = policy
        if case .search = candidate.action(for: latestRegion) {
            canSearchThisArea = true
        } else {
            canSearchThisArea = false
        }
    }

    private func refreshNearby() {
        guard !titleUsesArea || titleQuery.isEmpty else { return }
        guard areaChoice != .anywhere, let area = selectedArea else {
            state = hasCommittedArea ? .idle : .loading
            return
        }
        let excluded = blockList.blockedIDs
        perform(.nearby) { transport in
            try await transport.listings(
                near: area.coordinate,
                radiusMeters: area.radiusMeters,
                limit: Self.resultLimit,
                excluding: excluded
            )
        }
    }

    private enum Question { case nearby, title }

    private func perform(
        _ question: Question,
        _ work: @escaping @Sendable (any CommunityTransporting) async throws -> [CommunityListing]
    ) {
        guard let transport else { return }
        let previous = question == .nearby ? nearbyTask : matchTask
        previous?.cancel()
        if question == .nearby {
            state = nearbyListings.isEmpty ? .loading : .refreshing
        } else {
            matchingState = .loading
        }
        requestsInFlight += 1
        let task = Task { [weak self] in
            defer { self?.requestsInFlight -= 1 }
            do {
                // A typing debounce, not a test barrier. Cancelled fragments
                // never enter the transport or consume the public query budget.
                if question == .title { try await Task.sleep(for: Self.typingDelay) }
                try Task.checkCancellation()
                self?.issuedRequests += 1
                let results = try await work(transport)
                try Task.checkCancellation()
                self?.accept(results, answering: question)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let failure = error as? CommunityFailure ?? .unavailable(error.localizedDescription)
                Self.logger.error("Community search failed: \(failure.localizedDescription, privacy: .public)")
                if question == .nearby {
                    self?.state = .failed(failure)
                } else {
                    self?.matchingState = .failed(failure)
                }
            }
        }
        if question == .nearby { nearbyTask = task } else { matchTask = task }
    }

    private func accept(_ results: [CommunityListing], answering question: Question) {
        switch question {
        case .nearby:
            nearbyResults = results
            state = .loaded
        case .title:
            matchingResults = results
            matchingState = .loaded
        }
    }
}
