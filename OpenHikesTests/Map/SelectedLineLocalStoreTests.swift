//
//  SelectedLineLocalStoreTests.swift
//  OpenHikesTests
//
//  What the device-local store saves while a hike is followed never reaches
//  the watch's check of the store's history. Two of that store's columns are
//  composite, and SwiftData traps building a transaction that wrote one: a
//  walk in progress on iOS 18.6 and 27, and a drawing's travel mode on 18.6.
//  A check with no token read both stores by time until this was fixed, and
//  so the app crashed in the middle of a walk. See `SelectedLineStoreCheck`.
//
//  The checks are the watch's own, started by the store's own remote-change
//  notification, and the other device's save is the stand-in
//  `SelectedLineStoreWatchTests` uses for the import.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@Suite("Selected line store watch beside the device-local store")
struct SelectedLineLocalStoreTests {
    private struct Stage {
        let container: ModelContainer
        let hike: Hike
        let lines: SelectedLine
        let looks: Looks
        let watch: SelectedLineStoreWatch
        /// The checks the watch had made once it caught up with the hike.
        let checked: Int
    }

    /// Where the stores go: emptied once per run, never during one — see
    /// `StoreSandbox` for why.
    private static let sandbox: URL = {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "selected-line-local-store", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: root)
        return root
    }()

    /// A saved hike with its device-local row, read and then followed from
    /// the moment that read began, as the app follows a selection. Both
    /// stores are on disk, as the app opens them.
    private func stage() async throws -> Stage {
        let directory = Self.sandbox.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let container = try ModelContainer.openHikes(
            url: directory.appending(path: "OpenHikes.store"),
            localURL: directory.appending(path: "OpenHikesLocal.store")
        )
        let main = container.mainContext
        main.autosaveEnabled = false
        let hike = Fixture.hike(in: main, title: "Followed", route: SelectedLineStoreWatchTests.original)
        // The device-local row first, so that a walk's writes update it, as
        // every milestone after a walk's first does.
        hike.autoSaveTilesEnabled = false
        try await RemoteChangeLog.save(main, settling: hike)
        let lines = SelectedLine()
        _ = await lines.read(of: hike).route
        let looks = Looks()
        let watch = SelectedLineStoreWatch {
            looks.count += 1
            lines.refresh()
        }
        watch.follow(hike, since: try #require(lines.readBegan(for: hike)))
        await settleDelegateHop(until: "the watch has caught up with the hike") { watch.isSettled }
        return Stage(
            container: container,
            hike: hike,
            lines: lines,
            looks: looks,
            watch: watch,
            checked: watch.completedChecks
        )
    }

    /// Waits until a check has landed after the `checks` that had landed
    /// before, with nothing queued behind it, and for any look it started.
    private func settle(_ stage: Stage, after checks: Int) async {
        await settleDelegateHop(until: "the watch has checked the store") {
            stage.watch.completedChecks > checks && stage.watch.isSettled
        }
        await stage.lines.refreshing?.value
    }

    /// A walk keeps its progress in the hike's device-local row, and ends in
    /// one save of both stores: the walk's row in the hike's store, and the
    /// column cleared in the other. That save starts a check. With no import
    /// first, the watch holds no token yet, and `WalkUITests` crashed here,
    /// four tests of nine. After one, the check reads by token.
    @Test(
        "a walk saved while the hike is followed traps no check, and a line saved elsewhere then reaches it",
        arguments: [false, true]
    )
    func aWalkTrapsNoCheck(afterAnImport: Bool) async throws {
        let stage = try await stage()
        let main = stage.container.mainContext
        let moved = SelectedLineStoreWatchTests.Edit.moved.route
        var checks = stage.checked
        if afterAnImport {
            try await SelectedLineStoreWatchTests.saveElsewhere(stage.hike.id, in: stage.container) { stored in
                stored.title = "Renamed elsewhere"
            }
            await settle(stage, after: checks)
            checks = stage.watch.completedChecks
        }
        var walk = TrailWalkRecord(hikeID: stage.hike.id, routeDistanceMeters: 600, startedAt: .now)
        stage.hike.walkInProgress = walk
        try main.save()
        walk.phase = .paused
        stage.hike.walkInProgress = walk
        try main.save()
        let ended = HikeWalk(
            hikeID: stage.hike.id,
            startedAt: walk.startedAt,
            endedAt: .now,
            activeSeconds: 60,
            coveredIntervals: [0, 300],
            furthestDistanceMeters: 300,
            routeDistanceMeters: 600,
            endReason: .ended
        )
        main.insert(ended)
        ended.hike = stage.hike
        stage.hike.walkInProgress = nil
        try main.save()
        await settle(stage, after: checks)
        if !afterAnImport {
            #expect(stage.looks.count == 0, "nothing was saved elsewhere")
        }
        let looks = stage.looks.count

        try await SelectedLineStoreWatchTests.saveElsewhere(stage.hike.id, in: stage.container) { stored in
            stored.replaceRoute(with: moved)
        }
        await settleDelegateHop(until: "the hike is looked at") {
            stage.looks.count == looks + 1 && stage.watch.isSettled
        }
        await stage.lines.refreshing?.value

        #expect(await stage.lines.read(of: stage.hike).route == moved)
    }

    /// The trail maker lets the selection go, and keeps its drawing in the
    /// device-local store, travel mode and all. Followed again, the hike is
    /// checked from the read its readers still hold, which began before the
    /// drawing. Only iOS 18.6 trapped on the drawing; 27 builds that column.
    @Test("a drawing saved while the hike was let go traps no check once it is followed again")
    func aDrawingTrapsNoCheck() async throws {
        let stage = try await stage()
        let main = stage.container.mainContext
        let moved = SelectedLineStoreWatchTests.Edit.moved.route
        stage.watch.stopFollowing()
        let drawing = TrailDraftRecord(
            waypoints: moved,
            waypointNames: [],
            places: [],
            snapsToPaths: true,
            updatedAt: .now
        )
        main.insert(drawing)
        try main.save()
        drawing.travelMode = .cycling
        try main.save()
        try await SelectedLineStoreWatchTests.saveElsewhere(stage.hike.id, in: stage.container) { stored in
            stored.replaceRoute(with: moved)
        }

        stage.watch.follow(stage.hike, since: try #require(stage.lines.readBegan(for: stage.hike)))
        await settleDelegateHop(until: "the hike is looked at") { stage.looks.count == 1 && stage.watch.isSettled }
        await stage.lines.refreshing?.value

        #expect(await stage.lines.read(of: stage.hike).route == moved)
    }
}

/// How many times the watch had the line looked at.
private final class Looks {
    var count = 0
}
