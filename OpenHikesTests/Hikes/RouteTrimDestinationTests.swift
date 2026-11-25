//
//  RouteTrimDestinationTests.swift
//  OpenHikesTests
//
//  What *Edit Route* writes against while this device is still bringing in
//  a line the hiker's other device saved: the destination its screen builds
//  from ``ShownLine``. The hike holds the saved row before the screen's line
//  hears of it, because the store watch brings the row in before it asks for
//  the line to be compared, and the hikes list's query can bring it in
//  before the watch has heard of the save. Until both have landed the
//  screen's line still reads as settled, so *Looks Good*, Save and *Revert
//  to Original* ask the watch to look and wait for it, rather than act on a
//  line the hike no longer has.
//
//  Each look is held where it can be, and the tap is made while it is: the
//  watch's check, with the row brought in as the query brings it, and the
//  comparison, with the row brought in by the watch. And the row is brought
//  in as the query brings it before the store's remote change has reached
//  the watch, with nothing looking at it when the tap comes.
//
//  On-disk stores, as the store watch's own suite has them: history is what
//  the watch reads.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@MainActor
@Suite("Route trim destination", .serialized)
final class RouteTrimDestinationTests {
    /// Where the look at a save another context made is held.
    enum Hold: String, CaseIterable, Sendable {
        /// The store watch's look at the store's history, with the saved row
        /// already in the hike.
        case check = "check"
        /// The comparison of the line the watch brought in with the one on
        /// screen.
        case comparison = "comparison"
    }

    /// A screen up on a hike, its line read through the selection's
    /// reader, as the app wires it.
    private struct Stage {
        let hold: Hold?
        let hike: Hike
        let line: ShownLine
        let session: RouteTrimSession
        let lines: SelectedLine
        let watch: SelectedLineStoreWatch
        let checks: HeldStoreCheck
        let fetches: HeldLineFetch
    }

    /// Whether a tap's task has got as far as it was meant to.
    private final class Reached {
        var isReached = false
    }

    /// The recording's line, moved onto the fixes beside it by the other
    /// device.
    private static let moved = RouteEditChecksTests.saved.map { point in
        RouteCoordinate(
            latitude: point.latitude,
            longitude: point.longitude + RouteEditChecksTests.Line.traceOffset,
            timestamp: point.timestamp
        )
    }

    let container: ModelContainer

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "route-trim-destination/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        container = try ModelContainer.openHikes(
            url: directory.appending(path: "OpenHikes.store"),
            localURL: directory.appending(path: "OpenHikesLocal.store")
        )
        container.mainContext.autosaveEnabled = false
    }

    /// Opens *Edit Route* on a saved recording that asks for a look, or on
    /// one trimmed before with its original kept, with the next look at a
    /// save of its row to be held at `hold`, or nowhere. The selected line's
    /// first fetch is the selection's own read, so its second is the
    /// comparison.
    private func stage(holding hold: Hold?, edited: Bool = false) async throws -> Stage {
        let main = container.mainContext
        let saved = RouteEditChecksTests.saved
        let trimmed = Array(saved.prefix(9))
        let hike = Fixture.hike(in: main, route: edited ? trimmed : saved)
        hike.rawRoute = RouteEditChecksTests.raw
        if edited {
            hike.originalRoute = saved
            hike.routeEdit = RouteEdit(
                original: RouteEdit.Original(
                    distanceMeters: saved.lengthMeters,
                    date: hike.date,
                    recordedWalk: nil,
                    notOnFoot: nil
                ),
                lineRevision: TrailWalkRecord.routeRevision(of: trimmed)
            )
        } else {
            hike.routeEdit = RouteEdit(assembly: RouteEditChecksTests.assembly)
        }
        try await RemoteChangeLog.save(main, settling: hike)
        let checks = HeldStoreCheck()
        let fetches = HeldLineFetch(holding: hold == .comparison ? 2 : 0)
        let lines = SelectedLine(fetch: fetches.fetch)
        let watch = SelectedLineStoreWatch(making: checks.making) { lines.refresh() }
        _ = lines.read(of: hike)
        watch.follow(hike, since: try #require(lines.readBegan(for: hike)))
        await settleDelegateHop(until: "the watch has caught up with the hike") { watch.isSettled }
        let line = ShownLine()
        line.show(hike, selection: lines, followedBy: watch)
        await line.landing?.value
        let drawn = try #require(line.current?.route)
        let session = RouteTrimSession()
        await session.load(RouteEditSources.reading(hike, drawn: drawn, in: container))
        if edited {
            #expect(session.hasOriginal, "precondition: the original can be put back")
        } else {
            #expect(session.isOwedALook, "precondition: the hike asks for a look")
        }
        return Stage(
            hold: hold,
            hike: hike,
            line: line,
            session: session,
            lines: lines,
            watch: watch,
            checks: checks,
            fetches: fetches
        )
    }

    /// Saves `edit` to the hike's row through another context, as the
    /// mirroring import does, and waits until the look at it is held with the
    /// saved row in the hike.
    private func saveElsewhere(_ stage: Stage, _ edit: @escaping @Sendable (Hike) -> Void) async throws {
        if stage.hold == .check { stage.checks.arm() }
        try await SelectedLineStoreWatchTests.saveElsewhere(stage.hike.id, in: container, edit)
        switch stage.hold {
        case .check:
            await settleDelegateHop(until: "the watch's look at the store is held") { stage.checks.arrived == 1 }
            // What the hikes list's query does with every save to the store.
            _ = try SelectedLine.fetchHike(container.mainContext, stage.hike.persistentModelID)
        case .comparison:
            await settleDelegateHop(until: "the comparison is held") { stage.lines.refreshing != nil }
        case nil:
            break
        }
    }

    /// Saves `route` as the hike's line through another context, as the
    /// mirroring import does, and brings the row into the hike as the hikes
    /// list's query does, without leaving the main actor: the store's remote
    /// change cannot have reached the watch by the time the next tap begins.
    private func saveUnheard(_ route: [RouteCoordinate], to stage: Stage) throws {
        let other = ModelContext(container)
        other.author = "NSCloudKitMirroringDelegate.import"
        let id = stage.hike.id
        let row = try #require(try other.fetch(FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })).first)
        row.replaceRoute(with: route)
        try other.save()
        _ = try SelectedLine.fetchHike(container.mainContext, stage.hike.persistentModelID)
        #expect(stage.hike.route == route, "precondition: the hike holds the other device's line")
        #expect(stage.line.isSettled, "precondition: and the screen's line still reads as the hike's")
        #expect(stage.watch.check == nil && stage.lines.refreshing == nil, "precondition: and nothing is looking")
    }

    private func destination(of stage: Stage) -> RouteTrimSession.Destination {
        RouteTrimSession.Destination(hike: stage.hike, context: container.mainContext, health: nil, line: stage.line)
    }

    /// Taps as the screen does, in a task of its own, through the screen's
    /// own destination, and lets the held look land once the tap is waiting
    /// for it, or has finished without it.
    private func tap(
        _ stage: Stage,
        _ action: @escaping (RouteTrimSession.Destination) async -> Bool
    ) async -> Bool {
        let reached = Reached()
        var target = destination(of: stage)
        let settle = target.settle
        target.settle = {
            reached.isReached = true
            await settle()
        }
        let tapped = Task {
            let landed = await action(target)
            reached.isReached = true
            return landed
        }
        await settleDelegateHop(until: "the tap waits for the store, or is done") { reached.isReached }
        stage.checks.open()
        stage.fetches.open()
        return await tapped.value
    }

    @Test("Looks Good waits for a line the other device saved, and is refused once it is in", arguments: Hold.allCases)
    func lookWaitsForASavedLine(hold: Hold) async throws {
        let stage = try await stage(holding: hold)
        let replacement = Self.moved
        try await saveElsewhere(stage) { $0.replaceRoute(with: replacement) }
        #expect(stage.hike.route == replacement, "precondition: the hike holds the other device's line")
        #expect(stage.line.isSettled, "precondition: and the screen's line still reads as the hike's")
        let shown = stage.session.sourcesRevision

        let landed = await tap(stage) { await stage.session.confirmChecks(in: $0, tappedOn: shown) }

        #expect(!landed)
        #expect(stage.session.refusal == .lineChanged)
        #expect(stage.hike.routeEdit?.isOwedALook == true, "the checks stay owed, for the line the screen reloads on")
    }

    @Test("Looks Good waits for a save that left the line as it was, and is taken", arguments: Hold.allCases)
    func lookAfterAnotherSaveIsTaken(hold: Hold) async throws {
        let stage = try await stage(holding: hold)
        try await saveElsewhere(stage) { $0.title = "Renamed" }
        let shown = stage.session.sourcesRevision

        let landed = await tap(stage) { await stage.session.confirmChecks(in: $0, tappedOn: shown) }

        #expect(landed)
        #expect(stage.session.refusal == nil)
        #expect(stage.hike.routeEdit?.isOwedALook == false)
        #expect(stage.hike.title == "Renamed")
    }

    @Test("Save waits for a line the other device saved, and is refused once it is in", arguments: Hold.allCases)
    func saveWaitsForASavedLine(hold: Hold) async throws {
        let stage = try await stage(holding: hold)
        stage.session.move(.end, to: RouteEditChecksTests.savedDistances[8])
        let replacement = Self.moved
        try await saveElsewhere(stage) { $0.replaceRoute(with: replacement) }

        let landed = await tap(stage) { await stage.session.save(to: $0) }

        #expect(!landed)
        #expect(stage.session.refusal == .lineChanged)
        #expect(stage.hike.route == replacement, "the other device's line is not cut by distances measured on another")
        #expect(!stage.hike.hasOriginalRoute)
    }

    @Test("Revert waits for a line the other device saved, and is refused once it is in", arguments: Hold.allCases)
    func revertWaitsForASavedLine(hold: Hold) async throws {
        let stage = try await stage(holding: hold, edited: true)
        let replacement = Self.moved
        try await saveElsewhere(stage) { $0.replaceRoute(with: replacement) }

        let landed = await tap(stage) { await stage.session.revert(in: $0) }

        #expect(!landed)
        #expect(stage.session.refusal == .lineChanged)
        #expect(stage.hike.route == replacement, "the other device's line is not written over")
    }

    /// The tap's own question to the store: with nothing yet looking at the
    /// save, waiting only for a look already begun would wait for nothing.
    @Test("Looks Good on a line brought in before the watch heard of it is refused")
    func lookAtAnUnheardLineIsRefused() async throws {
        let stage = try await stage(holding: nil)
        try saveUnheard(Self.moved, to: stage)

        let landed = await stage.session.confirmChecks(
            in: destination(of: stage),
            tappedOn: stage.session.sourcesRevision
        )

        #expect(!landed)
        #expect(stage.session.refusal == .lineChanged)
        #expect(stage.hike.routeEdit?.isOwedALook == true)
    }

    @Test("Revert over a line brought in before the watch heard of it is refused")
    func revertOverAnUnheardLineIsRefused() async throws {
        let stage = try await stage(holding: nil, edited: true)
        try saveUnheard(Self.moved, to: stage)

        let landed = await stage.session.revert(in: destination(of: stage))

        #expect(!landed)
        #expect(stage.session.refusal == .lineChanged)
        #expect(stage.hike.route == Self.moved, "the other device's line is not written over")
    }
}
