//
//  HikeElevationRequestTests.swift
//  OpenHikesTests
//
//  When a hike's screen asks for the heights of a line that has none — see
//  `HikeElevationFill.swift`. The placeholder keys its request on
//  ``HikeElevationFill/Request``, and SwiftUI's `.task(id:)` asks again only
//  when that key changes. Keyed on whether the line needed heights alone, two
//  lines with none were one request, so a line saved over the first while the
//  screen was up was never asked about (#1440). ``KeyedTask`` does here what
//  `.task(id:)` does there, and the source is a stub whose first request is
//  held.
//
//  On-disk stores, as `ShownLineTests` has them: the store watch that brings a
//  line saved elsewhere to the screen reads history.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Synchronization
import Testing

@MainActor
@Suite("Hike elevation request", .serialized)
final class HikeElevationRequestTests {
    /// Heights rising a metre per point asked about, counting every request.
    /// Holds the first until opened, and answers any asked meanwhile at once.
    nonisolated private final class HeldSource: CuratedElevationSourcing {
        private let gate = TestGate()
        private let asked = Mutex(0)

        var requests: Int { asked.withLock { $0 } }
        var isHolding: Bool { gate.isHolding }

        func open() { gate.open() }

        @concurrent
        func heights(at coordinates: [CLLocationCoordinate2D]) async -> [Double] {
            asked.withLock { $0 += 1 }
            await gate.wait()
            return coordinates.indices.map { 500 + Double($0) }
        }
    }

    let container: ModelContainer

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "hike-elevation-request/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        container = try ModelContainer.openHikes(
            url: directory.appending(path: "OpenHikes.store"),
            localURL: directory.appending(path: "OpenHikesLocal.store")
        )
        container.mainContext.autosaveEnabled = false
    }

    /// A line of 500 points heading north along `longitude`, with no heights.
    private static func heightless(along longitude: Double) -> [RouteCoordinate] {
        (0..<500).map { index in
            RouteCoordinate(latitude: 47.6 + Double(index) * 0.0005, longitude: longitude)
        }
    }

    /// `hike`'s line as its screen has it while the hike is the selected one:
    /// through the selection's reader, and the watch that follows the hike in
    /// the store for it.
    private func shownLine(of hike: Hike) async throws -> ShownLine {
        let selection = ShownLineTests.selection()
        _ = selection.lines.read(of: hike)
        selection.watch.follow(hike, since: try #require(selection.lines.readBegan(for: hike)))
        await settleDelegateHop(until: "the watch has caught up with the hike") { selection.watch.isSettled }
        let shown = ShownLine()
        shown.show(hike, selection: selection.lines, followedBy: selection.watch)
        await shown.landing?.value
        return shown
    }

    /// The issue's steps: a subscriber's hike with no heights is open, its
    /// request is out, and another device saves a different line with no
    /// heights over it.
    @Test("a different line with no heights, saved while the first is asked about, is asked about for itself")
    func aNewLineIsAskedAboutAgain() async throws {
        let first = Self.heightless(along: 12.86)
        let second = Self.heightless(along: 12.87)
        let hike = Fixture.hike(in: container.mainContext, title: "Imported", route: first)
        try await RemoteChangeLog.save(container.mainContext, settling: hike)
        let shown = try await shownLine(of: hike)
        let source = HeldSource()
        defer { source.open() }
        let task = KeyedTask()
        let context = container.mainContext
        // What the placeholder's body and its `.task(id:)` do on each pass.
        func pass() -> HikeElevationFill.Request {
            let request = HikeElevationFill.Request(hike: hike, line: shown, isEntitled: true)
            task.update(request) { await request.fill(hike, shown: shown, from: source, in: context) }
            return request
        }

        #expect(pass().asks)
        await settleDelegateHop(until: "the first line's request is out") { source.isHolding }

        try await SelectedLineStoreWatchTests.saveElsewhere(hike.id, in: container) { $0.replaceRoute(with: second) }
        await settleDelegateHop(until: "the second line has landed") { shown.current?.route == second }
        await shown.landing?.value
        #expect(pass().asks)

        try #require(task.runs.count == 2, "a new line is a new request")
        #expect(await task.runs[1].value, "the second line has its heights")
        source.open()
        #expect(await task.runs[0].value == false, "and the first line's answer is not written over them")
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<Hike>()).first)
        #expect(stored.route.map { RouteCoordinate(latitude: $0.latitude, longitude: $0.longitude) } == second)
        #expect(stored.route.allSatisfy { $0.elevation?.isFinite == true })

        // The heights are a new line too, which moves the key and asks nothing.
        await settleDelegateHop(until: "the line with heights has landed") {
            shown.current.map { !HikeElevationFill.needsHeights($0.route) } ?? false
        }
        await shown.landing?.value
        #expect(!pass().asks)
        #expect(await task.runs.last?.value == false)
        #expect(source.requests == 2, "one request for each line without heights")
    }
}

/// What SwiftUI's `.task(id:)` does with the placeholder's request: runs the
/// action for the first key, and again for each key that is not the one
/// before it, cancelling the run before.
@MainActor
private final class KeyedTask {
    private var key: HikeElevationFill.Request?
    /// Every run started, oldest first.
    private(set) var runs: [Task<Bool, Never>] = []

    func update(_ key: HikeElevationFill.Request, _ action: @escaping @MainActor () async -> Bool) {
        guard key != self.key else { return }
        self.key = key
        runs.last?.cancel()
        runs.append(Task { await action() })
    }
}
