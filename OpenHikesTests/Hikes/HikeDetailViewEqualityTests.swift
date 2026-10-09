//
//  HikeDetailViewEqualityTests.swift
//  OpenHikesTests
//
//  `MapSheet` builds the hike detail screen again on every push and pop over
//  it, and on every pass of the sheet, handing it five new closures each time.
//  It is `.equatable()` there so that a copy differing only in those closures
//  is the same screen and its card is not rebuilt — see
//  `HikeDetailView+Equatable.swift`. What is pinned here is the comparison: the
//  closures are left out of it, and what the screen draws from is not.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import SwiftUI
import Testing

@MainActor
@Suite("Hike detail equality")
struct HikeDetailViewEqualityTests {
    /// Everything the screen is handed, made once, so that two copies share all
    /// of it but what a case varies.
    private struct Dependencies {
        let container: ModelContainer
        let sandbox = TileSandbox()
        let highlight = RouteHighlight()
        let mapController = MapController()
        let autoSave: AutoSaveController
        let entitlement: MapEntitlementStore
        let settings: StoredSettings
        let locationManager = LocationManager()
        let backgroundTracker: BackgroundTrailTracker
        let walkSession: TrailWalkSession

        init() throws {
            container = try Fixture.modelContainer()
            let defaults = try #require(UserDefaults(suiteName: "HikeDetailViewEqualityTests-\(UUID().uuidString)"))
            autoSave = AutoSaveController(store: sandbox.store, drainInterval: nil)
            entitlement = MapEntitlementStore(defaults: defaults, currentEntitlements: { false })
            settings = StoredSettings(defaults: defaults)
            // Stand-ins for both monitors, because the tracker re-takes its
            // monitoring as it is built and the system's are the app's.
            backgroundTracker = BackgroundTrailTracker(
                container: container,
                monitor: StubLocationMonitor(),
                regionMonitor: FakeTrailRegionMonitor(),
                defaults: defaults
            )
            walkSession = TrailWalkSession(context: ModelContext(container))
        }

        func screen(
            of hike: Hike,
            interaction: HikeDetailInteraction,
            mapController: MapController? = nil,
            isSheetCompact: Bool = false,
            onOpenPhoto: @escaping (HikePhoto) -> Void = { _ in /* never tapped */ }
        ) -> HikeDetailView {
            HikeDetailView(
                hike: hike,
                highlight: highlight,
                mapController: mapController ?? self.mapController,
                autoSave: autoSave,
                entitlement: entitlement,
                settings: settings,
                locationManager: locationManager,
                backgroundTracker: backgroundTracker,
                walkSession: walkSession,
                onOpenPhoto: onOpenPhoto,
                onZoomToRoute: { /* never tapped */ },
                isSheetCompact: isSheetCompact,
                interaction: interaction
            )
        }
    }

    @Test("a copy that differs only in its closures is the same screen")
    func closuresAreLeftOut() throws {
        let dependencies = try Dependencies()
        let hike = Fixture.hike(in: dependencies.container.mainContext)
        let interaction = HikeDetailInteraction()

        // Two closure literals are two values whatever they do, which is the
        // whole of what made every copy of this screen a different view.
        let first = dependencies.screen(of: hike, interaction: interaction) { _ in /* the first copy's */ }
        let second = dependencies.screen(of: hike, interaction: interaction) { _ in /* the second copy's */ }

        #expect(first == second)
    }

    @Test("another hike, another detent or another selection is another screen")
    func whatTheScreenDrawsFromIsCompared() throws {
        let dependencies = try Dependencies()
        let context = dependencies.container.mainContext
        let hike = Fixture.hike(in: context)
        let interaction = HikeDetailInteraction()
        let screen = dependencies.screen(of: hike, interaction: interaction)

        #expect(screen != dependencies.screen(of: Fixture.hike(in: context), interaction: interaction))
        #expect(screen != dependencies.screen(of: hike, interaction: interaction, isSheetCompact: true))
        #expect(screen != dependencies.screen(of: hike, interaction: HikeDetailInteraction()))
        #expect(screen != dependencies.screen(of: hike, interaction: interaction, mapController: MapController()))
    }

    /// The inputs `==` compares, by name.
    private static let compared: Set = [
        "hike", "isSheetCompact", "highlight", "mapController", "autoSave", "entitlement",
        "settings", "locationManager", "backgroundTracker", "walkSession",
        "photoCapture", "photoPins", "placePins", "trailMaker",
    ]
    /// The inputs it leaves out, each for the reason
    /// `HikeDetailView+Equatable.swift` gives.
    private static let leftOut: Set = ["trailGraphProvider", "communityTransport"]

    /// A comparison written out by hand is a list somebody has to remember to
    /// extend, and an input it forgets fails quietly: a copy that differs only
    /// there compares equal, and the screen goes on drawing the one it was
    /// first handed. So a new input fails here until `==` has an answer for
    /// it, compared or left out on purpose.
    @Test("every input the screen is handed is compared or left out on purpose")
    func everyInputIsAccountedFor() throws {
        let dependencies = try Dependencies()
        let hike = Fixture.hike(in: dependencies.container.mainContext)
        let screen = dependencies.screen(of: hike, interaction: HikeDetailInteraction())

        // Plain stored properties only: SwiftUI's wrappers are stored as
        // `_name`, and the closures are left out by design.
        let inputs = Set(Mirror(reflecting: screen).children.compactMap { child -> String? in
            guard let label = child.label, !label.hasPrefix("_") else { return nil }
            return String(describing: type(of: child.value)).contains("->") ? nil : label
        })

        #expect(inputs == Self.compared.union(Self.leftOut))
    }
}
