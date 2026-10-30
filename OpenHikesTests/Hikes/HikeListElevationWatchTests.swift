//
//  HikeListElevationWatchTests.swift
//  OpenHikesTests
//
//  While a Hilliest list is up, a save validates the listed hikes whose line
//  may have been written, and no other (#1253): a line written here, or a
//  row saved by any context, such as an edit mirrored in from another
//  device. Before, under the hikes list's always-live `@Query`, every save
//  to the store read every listed route again, and with no `@Query` up a
//  line saved elsewhere was not validated until the list's task started
//  again.
//
//  Which hikes a save validated is read off their cached fingerprints. A
//  fingerprint no line has is planted beside a hike's figures, and any
//  validation of that hike replaces it, so whether it is still there says
//  whether the hike was looked at. That needs no seam in the list's task,
//  which is the point: the same tests ran against the task as it was.
//
//  The import is a sibling context's save under the mirroring delegate's
//  author, as in `SelectedLineStoreWatchTests`. Both stores are on disk, as
//  the app opens them.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import SwiftData
import SwiftUI
import Testing

@Suite("Library elevation validates the lines written, and no others")
struct HikeListElevationWatchTests {
    /// Who writes the new line, and whether the hikes list is up meanwhile.
    enum Writer: String, CaseIterable, Sendable {
        case elsewhereWithTheListUp = "elsewhere, with the list up"
        case elsewhereWithNoListUp = "elsewhere, with no list up"
        case hereWithTheListUp = "here, with the list up"

        var hostsTheList: Bool { self != .elsewhereWithNoListUp }
    }

    private func observe(_ stage: HikeListElevationStage) -> Task<Void, Never> {
        Task {
            await HikeListMetrics.observeElevation(in: stage.hikes, container: stage.container) {
                stage.didPublish()
            }
        }
    }

    @Test("with the hikes list up, a rename received from elsewhere or a tint saved here validates that hike alone")
    func aSaveOfOneHikeValidatesItAlone() async throws {
        let stage = try await HikeListElevationStage(hostingTheList: true)
        defer { stage.close() }
        let observing = observe(stage)
        defer { observing.cancel() }
        await settleDelegateHop(until: "the first pass is published") { stage.publications == 1 }
        let renamed = stage.hikes[1]
        let tinted = stage.hikes[2]
        let untouched = stage.hikes[3]
        try await stage.plantStaleFingerprints(on: [renamed, tinted, untouched])

        try await SelectedLineStoreWatchTests.saveElsewhere(renamed.id, in: stage.container) { hike in
            hike.title = "Renamed elsewhere"
        }
        await settleDelegateHop(until: "the renamed hike is validated") { stage.publications == 2 }
        #expect(stage.wasValidated(renamed))
        #expect(!stage.wasValidated(tinted))
        #expect(!stage.wasValidated(untouched))

        tinted.tintHex = "#FF00FF"
        try stage.container.mainContext.save()
        await settleDelegateHop(until: "the tinted hike is validated") { stage.publications == 3 }
        #expect(stage.wasValidated(tinted))
        #expect(!stage.wasValidated(untouched), "nothing saved its row or wrote its line")
        observing.cancel()
        await observing.value
    }

    @Test("a new line is measured, and no other hike is looked at", arguments: Writer.allCases)
    func aNewLineIsValidatedAlone(writer: Writer) async throws {
        let stage = try await HikeListElevationStage(hostingTheList: writer.hostsTheList)
        defer { stage.close() }
        let observing = observe(stage)
        defer { observing.cancel() }
        await settleDelegateHop(until: "the first pass is published") { stage.publications == 1 }
        let edited = stage.hikes[1]
        let other = stage.hikes[2]
        try await stage.plantStaleFingerprints(on: [other])
        let steeper = HikeListElevationStage.line(1, climb: 500)

        switch writer {
        case .elsewhereWithTheListUp, .elsewhereWithNoListUp:
            try await SelectedLineStoreWatchTests.saveElsewhere(edited.id, in: stage.container) { hike in
                hike.replaceRoute(with: steeper)
            }
        case .hereWithTheListUp:
            // Heights filled in, or a recording finished: written and saved
            // through the main context at once.
            edited.replaceRoute(with: steeper)
            try stage.container.mainContext.save()
        }
        await settleDelegateHop(until: "the new line is measured") { stage.publications == 2 }

        #expect(stage.has(edited, climbing: 500))
        #expect(!stage.wasValidated(other))
        observing.cancel()
        await observing.value
    }
}

/// A library of six hikes on disk, each climbing a little more than the one
/// before, with the hikes list's `@Query` up in a window as the sheet always
/// has it, or not. Shared with `HikeListElevationOrderingTests`.
final class HikeListElevationStage {
    /// The hikes list's query, and nothing else: what refreshes every hike in
    /// the main context on every save of the store, in the app.
    private struct HikesList: View {
        @Query(sort: \Hike.date, order: .reverse) private var hikes: [Hike]

        var body: some View {
            Text(verbatim: "\(hikes.count)")
        }
    }

    /// A fingerprint no line has: see the suite header.
    private static let staleFingerprint = "a line this device no longer has"
    /// Where the library lies and how high it starts: its hikes a hundredth
    /// of a degree apart, and each hike's points a thousandth.
    nonisolated private static let startLatitude = 47.0
    nonisolated private static let longitude = 19.0
    nonisolated private static let hikeSpacing = 0.01
    nonisolated private static let pointSpacing = 0.001
    nonisolated private static let startHeight = 100.0
    /// How near two climbs are to count as one.
    private static let tolerance = 0.001

    /// Where the stores go: emptied once per run, never during one — see
    /// `StoreSandbox` for why.
    private static let sandbox: URL = {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "hike-list-elevation", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: root)
        return root
    }()

    let container: ModelContainer
    let hikes: [Hike]
    private let window: UIWindow?
    /// How many times the list's task published a changed figure.
    private(set) var publications = 0
    /// The climb `hikes[1]` had after each of those publications.
    private(set) var publishedClimbs: [Double?] = []

    /// Saves the library, and waits for its remote change to be delivered
    /// before the list's task can be started to hear it.
    init(hostingTheList: Bool) async throws {
        let directory = Self.sandbox.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        container = try ModelContainer.openHikes(
            url: directory.appending(path: "OpenHikes.store"),
            localURL: directory.appending(path: "OpenHikesLocal.store")
        )
        let main = container.mainContext
        main.autosaveEnabled = false
        let library = (0..<6).map { index in
            Fixture.hike(in: main, title: "Trail \(index)", route: Self.line(index, climb: Self.climb(index)))
        }
        try await RemoteChangeLog.save(main, settling: library[0])
        hikes = library
        window = hostingTheList ? try Self.host(HikesList().modelContainer(container)) : nil
        await settleDelegateHop()
    }

    /// The climb `hikes[index]` is first saved with.
    nonisolated static func climb(_ index: Int) -> Double {
        startHeight + 10 * Double(index)
    }

    /// A line of `hikes[index]`'s, rising `climb` metres in two even steps,
    /// each well clear of the climb's three metre deadband.
    nonisolated static func line(_ index: Int, climb: Double) -> [RouteCoordinate] {
        (0..<3).map { step in
            RouteCoordinate(
                latitude: startLatitude + Double(index) * hikeSpacing + Double(step) * pointSpacing,
                longitude: longitude,
                elevation: startHeight + climb * Double(step) / 2
            )
        }
    }

    private static func host(_ view: some View) throws -> UIWindow {
        let scene = try #require(
            UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first,
            "app-hosted tests run inside the app, which has a scene"
        )
        let hosting = UIWindow(windowScene: scene)
        hosting.frame = scene.coordinateSpace.bounds
        hosting.rootViewController = UIHostingController(rootView: view)
        hosting.isHidden = false
        hosting.layoutIfNeeded()
        return hosting
    }

    func close() {
        window?.isHidden = true
        window?.rootViewController = nil
    }

    /// What the list's task is handed to call after each publication.
    func didPublish() {
        publications += 1
        publishedClimbs.append(hikes[1].climbMeters)
    }

    /// Whether `hike`'s cached climb is `climb`.
    func has(_ hike: Hike, climbing climb: Double) -> Bool {
        climb.isApproximatelyEqual(to: hike.climbMeters ?? .nan, absoluteTolerance: Self.tolerance)
    }

    /// Whether `hikes[1]` was ever published climbing `climb`.
    func published(climbing climb: Double) -> Bool {
        publishedClimbs.contains { climb.isApproximatelyEqual(to: $0 ?? .nan, absoluteTolerance: Self.tolerance) }
    }

    /// Whether `hikes[1]` was last published climbing `climb`.
    func lastPublished(climbing climb: Double) -> Bool {
        let last = publishedClimbs.last.flatMap(\.self)
        return climb.isApproximatelyEqual(to: last ?? .nan, absoluteTolerance: Self.tolerance)
    }

    /// Plants a fingerprint no line has beside each hike's figures, saved to
    /// the device-local store, and waits for that save's remote change.
    func plantStaleFingerprints(on planted: [Hike]) async throws {
        for hike in planted {
            hike.elevationRouteRevision = Self.staleFingerprint
        }
        let changes = RemoteChangeLog()
        changes.start()
        defer { changes.stop() }
        try container.mainContext.save()
        let localStore = try #require(planted.first?.localState?.persistentModelID.storeIdentifier)
        await settleDelegateHop(until: "the device-local save's change is delivered") { changes.posted(localStore) }
        await settleDelegateHop()
    }

    /// Whether `hike` was validated since its fingerprint was planted.
    func wasValidated(_ hike: Hike) -> Bool {
        hike.elevationRouteRevision != Self.staleFingerprint
    }
}
