//
//  HikeDetailLineTests+PushedScreens.swift
//  OpenHikesTests
//
//  What ``HikeDetailLineTests`` holds the hike's own screen to, for everything
//  else that reads its line (#1263): a place's screen, *Add Place*, *Places
//  Around Trail*, a walk's summary, the community share form and its check,
//  and the walk session. Each read `hike.route` on the main actor, about 30 ms
//  of a 20,000-point line when it opened and again after any save under the
//  hikes list's query.
//
//  Seen the same way: the line is still cold in the main context once the
//  screen is up, and again once a save has refreshed the hike and every body
//  it invalidated has run. A screen that read it there would leave it warm.
//
//  From iOS 27, for the reason in that suite's header.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import SwiftUI
import Testing

extension HikeDetailLineTests {
    /// A long line with a place on it, a neighbor whose save refreshes it,
    /// and the line landed as the hike's own screen has it before anything is
    /// pushed over it.
    struct OpenedLine {
        let hike: Hike
        let neighbor: Hike
        let line: ShownLine
        let placeID: UUID
    }

    private func openedLine() async throws -> OpenedLine {
        let route = Self.longRoute(points: Self.longPoints)
        let hike = try hikeSavedElsewhere(route: route)
        let neighbor = Fixture.hike(in: container.mainContext, title: "Neighbor", route: Fixture.loopRoute)
        let spot = try #require(route.dropFirst().first)
        let place = TrailPlace(latitude: spot.latitude, longitude: spot.longitude, name: "Hut")
        hike.addPlace(place, in: container.mainContext)
        try await RemoteChangeLog.save(container.mainContext, settling: neighbor)
        await select(hike)
        let line = ShownLine()
        line.show(hike, selection: model.selectedLine, followedBy: model.selectedLineStoreWatch)
        await line.landing?.value
        return OpenedLine(hike: hike, neighbor: neighbor, line: line, placeID: place.id)
    }

    /// `screen` in a window beside the hikes list's query, as the sheet has
    /// it.
    private func host(pushed screen: some View) throws -> UIWindow {
        let window = try window(hosting: VStack {
            HikesListStandIn()
            NavigationStack { screen }
        })
        window.layoutIfNeeded()
        return window
    }

    /// Holds the line to being cold now, and after a save with `window`'s
    /// bodies run again.
    private func expectColdLine(_ opened: OpenedLine, in window: UIWindow) async throws {
        let onOpening = Self.mainActorRead(of: opened.hike)
        #expect(onOpening.points == Self.longPoints)
        #expect(onOpening.duration >= .milliseconds(5), "read on opening: \(onOpening.duration)")

        try await save(refreshing: opened.hike, in: window) {
            opened.neighbor.tintHex = "#FF00FF"
            try await RemoteChangeLog.save(self.container.mainContext, settling: opened.neighbor)
        }

        let afterSaving = Self.mainActorRead(of: opened.hike)
        #expect(afterSaving.duration >= .milliseconds(5), "read after a save: \(afterSaving.duration)")
    }

    @available(iOS 27.0, *)
    @Test("a place's screen decodes none of the line on the main actor")
    func aPlaceScreenDecodesNothing() async throws {
        let opened = try await openedLine()
        let window = try host(pushed: HikePlaceView(
            hike: opened.hike,
            placeID: opened.placeID,
            line: opened.line,
            mapController: MapController(),
            placePins: model.placePins
        ))
        defer { Self.takeDown(window) }
        await settleDelegateHop(until: "the screen has claimed its pins") { !self.model.placePins.rows.isEmpty }

        try await expectColdLine(opened, in: window)
    }

    @available(iOS 27.0, *)
    @Test("Add Place decodes none of the line on the main actor")
    func addPlaceDecodesNothing() async throws {
        let opened = try await openedLine()
        let window = try host(pushed: HikePlaceAdder(
            hike: opened.hike,
            line: opened.line,
            spot: HikePlaceSpot(CLLocationCoordinate2D(latitude: 47.001, longitude: 12.001)),
            placePins: model.placePins,
            session: HikePlaceAdderSession(),
            onAdded: { _ in /* no-op */ },
            onCancel: { /* no-op */ }
        ))
        defer { Self.takeDown(window) }
        await settleDelegateHop(until: "the form has claimed its pins") { !self.model.placePins.rows.isEmpty }

        try await expectColdLine(opened, in: window)
    }

    @available(iOS 27.0, *)
    @Test("Places Around Trail decodes none of the line on the main actor")
    func placesAroundDecodesNothing() async throws {
        let opened = try await openedLine()
        let window = try host(pushed: HikePlacesAroundView(
            hike: opened.hike,
            line: opened.line,
            around: model.placePins.around,
            mapController: MapController(),
            placePins: model.placePins,
            search: HikePlacesAroundSearch()
        ))
        defer { Self.takeDown(window) }
        await settleDelegateHop(until: "the screen has claimed its pins") { !self.model.placePins.rows.isEmpty }

        try await expectColdLine(opened, in: window)
    }

    @available(iOS 27.0, *)
    @Test("a walk's summary decodes none of the line on the main actor")
    func aWalkSummaryDecodesNothing() async throws {
        let opened = try await openedLine()
        let walk = HikeWalk(
            hikeID: opened.hike.id,
            startedAt: .now,
            endedAt: .now,
            activeSeconds: 60,
            coveredIntervals: [0, 100],
            furthestDistanceMeters: 100,
            routeDistanceMeters: 1000,
            endReason: .ended,
            routeRevision: "the walked line"
        )
        container.mainContext.insert(walk)
        walk.hike = opened.hike
        try await RemoteChangeLog.save(container.mainContext, settling: opened.hike)
        let window = try host(pushed: WalkSummaryView(
            walk: walk,
            line: opened.line,
            walkHighlight: WalkHighlight(),
            mapController: MapController(),
            share: WalkShareSession()
        ))
        defer { Self.takeDown(window) }

        try await expectColdLine(opened, in: window)
    }

    @available(iOS 27.0, *)
    @Test("the community share form decodes none of the line on the main actor")
    func theShareFormDecodesNothing() async throws {
        let opened = try await openedLine()
        let window = try host(pushed: CommunityShareSheet(
            hike: opened.hike,
            line: opened.line,
            transport: StubCommunityTransport()
        ))
        defer { Self.takeDown(window) }

        try await expectColdLine(opened, in: window)
    }

    @available(iOS 27.0, *)
    @Test("the community check decodes neither the hike's line nor the lines already shared on the main actor")
    func theCommunityCheckDecodesNothing() async throws {
        let route = Self.longRoute(points: Self.longPoints)
        let hike = try hikeSavedElsewhere(route: route)
        let shared = try hikeSavedElsewhere(route: route)
        shared.communitySubmissionID = "sent"
        try await RemoteChangeLog.save(container.mainContext, settling: shared)

        let eligibility = await CommunityPublishingCheck.eligibility(of: hike, in: container.mainContext)

        #expect(eligibility.reason != nil, "the line was read, and found to retrace the one already shared")
        for line in [hike, shared] {
            let read = Self.mainActorRead(of: line)
            #expect(read.points == Self.longPoints)
            #expect(read.duration >= .milliseconds(5), "read on the main actor: \(read.duration)")
        }
    }

    /// The hike's own line is not a screen's here: a walk goes on in a pocket
    /// and under another hike's screen, and the session asks after its line
    /// on every fix, on every return and at launch.
    @available(iOS 27.0, *)
    @Test("a walk's checks on its line decode none of it on the main actor")
    func aWalksChecksDecodeNothing() async throws {
        let route = Self.longRoute(points: Self.longPoints)
        let hike = try hikeSavedElsewhere(route: route)
        let revision = TrailWalkRecord.routeRevision(of: route)
        let session = model.walkSession
        let profile = RouteProfile(route: route)
        #expect(session.start(hike: hike, profile: profile, revision: revision))
        let shown = Fixture.hike(in: container.mainContext, title: "Shown", route: Fixture.loopRoute)
        try await RemoteChangeLog.save(container.mainContext, settling: shown)

        session.checkWalkedLine()
        await session.lineCheck?.value
        session.recordBackgroundMatch(hikeID: hike.id, distance: 10, at: .now, revision: revision)
        session.recordForegroundMatch(hike: shown, profile: profile, distance: 10, revision: "shown")
        await session.lineCheck?.value

        #expect(session.walkedHikeID == hike.id, "the line is the one the walk began on")
        let read = Self.mainActorRead(of: hike)
        #expect(read.points == Self.longPoints)
        #expect(read.duration >= .milliseconds(5), "read on the main actor: \(read.duration)")
    }

    /// A line saved on another device reaches the pushed screen the way it
    /// reaches the hike's own: the place is measured along it.
    @Test("a line saved elsewhere reaches a place's screen")
    func aLineSavedElsewhereReachesAPlaceScreen() async throws {
        let hike = Fixture.hike(in: container.mainContext)
        let place = TrailPlace(
            latitude: Self.movedRoute[1].latitude,
            longitude: Self.movedRoute[1].longitude,
            name: "Hut"
        )
        hike.addPlace(place, in: container.mainContext)
        try await RemoteChangeLog.save(container.mainContext, settling: hike)
        await select(hike)
        let line = ShownLine()
        line.show(hike, selection: model.selectedLine, followedBy: model.selectedLineStoreWatch)
        await line.landing?.value
        let window = try host(pushed: HikePlaceView(
            hike: hike,
            placeID: place.id,
            line: line,
            mapController: MapController(),
            placePins: model.placePins
        ))
        defer { Self.takeDown(window) }
        await settleDelegateHop(until: "the screen has claimed its pins") { !self.model.placePins.rows.isEmpty }
        let before = model.placePins.rows.first?.anchor?.offRouteMeters ?? .infinity

        let moved = Self.movedRoute
        try await SelectedLineStoreWatchTests.saveElsewhere(hike.id, in: container) { $0.replaceRoute(with: moved) }

        await settleDelegateHop(until: "the pins are measured along the new line") {
            (self.model.placePins.rows.first?.anchor?.offRouteMeters ?? .infinity) < before
        }
    }
}
