//
//  CommunityPreviewSessionTests.swift
//  OpenHikesTests
//
//  A shared hike's preview, hosted in one window and then in another, as a
//  turn of the phone moves it between the sheet and the side panel (#1336).
//
//  The screen used to keep what it had loaded as its own `@State`, so the
//  screen built in the second host was a second visit: it asked the transport
//  again, downloaded again into a directory of its own, and put the chart's
//  marker back at the trailhead. These host the screen the way ``MapSheet``
//  builds it — its visit from ``SheetPresentation`` — and count what reaches
//  the transport. ``SheetDestinationStateTests`` holds the visit's lifetime
//  against the path without a window.
//
//  Two windows in turn rather than one rebuilt, because that is what a turn
//  is: the sheet and the panel are two hosts, and the view in each has an
//  identity of its own.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import SwiftData
import SwiftUI
import Testing

@MainActor
@Suite("Community preview session", .serialized, .timeLimit(.minutes(1)))
struct CommunityPreviewSessionTests {
    /// How far along the ridge the chart's marker is left before the turn —
    /// anywhere but the trailhead, where a screen starting over puts it.
    private static let scrubbedMeters = 300.0
    /// Two readings of one point along one profile, a micrometre apart at most.
    private static let sameCoordinate = 1e-9

    let container: ModelContainer
    let transport = StubCommunityTransport()
    let browser = CommunityBrowser(transport: nil, blockList: .scratch())
    let presentation = SheetPresentation()
    let listing = CommunityListing.stub()

    init() throws {
        container = try Fixture.modelContainer()
        transport.detailResult = .success(
            CommunityHikeDetail(
                listing: listing,
                route: Fixture.ridgeRoute,
                trackDescription: "A ridge walk",
                photoPins: [],
                photoFileURLs: [],
                photosOnRecord: 0
            )
        )
        presentation.path = [.communityHike(listing)]
    }

    /// The preview in a window of its own, built as ``MapSheet`` builds it.
    func host() throws -> UIWindow {
        let screen = CommunityHikeView(
            session: presentation.communityPreview(of: listing),
            transport: transport,
            blockList: .scratch(),
            browser: browser,
            onImport: { _ in /* nowhere to go */ },
            onBlock: { /* nowhere to go */ },
            remainsPushed: { [presentation, listing] in presentation.isPresentingCommunityHike(listing) }
        )
        let scene = try #require(
            UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first,
            "app-hosted tests run inside the app, which has a scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(
            rootView: NavigationStack { screen }.modelContainer(container)
        )
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    /// A turn of the phone, in the order a pool iPhone 18 Pro was measured to
    /// make one: the layout flips first; to landscape the panel's copy comes
    /// up before the sheet's goes, and back to portrait the panel's goes
    /// first and the sheet's comes up, goes and comes up again.
    func turn(from window: UIWindow, to layout: SheetLayout) throws -> UIWindow {
        presentation.layout = layout
        guard layout == .bottomSheet else {
            let panel = try host()
            Self.takeDown(window)
            return panel
        }
        Self.takeDown(window)
        Self.takeDown(try host())
        return try host()
    }

    static func takeDown(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    /// Whether the map's dot stands `meters` along the ridge.
    func dotStands(at meters: Double) -> Bool {
        let profile = RouteProfile(route: Fixture.ridgeRoute)
        guard let dot = browser.previewHighlight?.coordinate,
              let expected = profile.coordinate(atDistance: meters) else { return false }
        return dot.latitude.isApproximatelyEqual(to: expected.latitude, absoluteTolerance: Self.sameCoordinate)
            && dot.longitude.isApproximatelyEqual(to: expected.longitude, absoluteTolerance: Self.sameCoordinate)
    }

    @Test("a turn of the phone keeps the loaded page and the chart's marker, and asks nothing")
    func aTurnKeepsTheLoadedVisit() async throws {
        let session = presentation.communityPreview(of: listing)
        var window = try host()
        defer { Self.takeDown(window) }
        await settleDelegateHop(until: "the page is up, with the map's dot at the trailhead") { dotStands(at: 0) }
        // Where a finger left it. The chart writes this and nothing else.
        session.tracker.trackerDistance = Self.scrubbedMeters

        for layout in [SheetLayout.sidePanel, .bottomSheet] {
            window = try turn(from: window, to: layout)
            // The effect a screen coming up for the visit has: it puts the
            // map's dot back where the chart's marker stands.
            await settleDelegateHop(until: "the new host has put the dot where the marker was left") {
                dotStands(at: Self.scrubbedMeters)
            }
            #expect(presentation.communityPreview(of: listing) === session)
            #expect(session.prepared != nil, "the walk of the route is the one already made")
        }
        #expect(transport.recording.detailRequests == [listing.id], "one visit, one request")
        #expect(!session.hasEnded)
    }

    @Test("a turn while the hike is still loading waits for the request already out")
    func aTurnWhileLoadingAsksOnce() async throws {
        let gate = AsyncGate()
        transport.beforeDetailReturns = { await gate.wait() }
        let session = presentation.communityPreview(of: listing)
        var window = try host()
        defer { Self.takeDown(window) }
        await settleDelegateHop(until: "the first host to ask") { !transport.recording.detailRequests.isEmpty }

        // Both ways round while the request is out.
        window = try turn(from: window, to: .sidePanel)
        window = try turn(from: window, to: .bottomSheet)
        await gate.open()

        await settleDelegateHop(until: "the answer is on the page the last host draws") {
            if case .loaded = session.phase { return dotStands(at: 0) }
            return false
        }
        #expect(transport.recording.detailRequests == [listing.id], "the request out was waited for")
    }
}
