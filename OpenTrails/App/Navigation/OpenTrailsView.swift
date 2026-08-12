//
//  OpenTrailsView.swift
//  OpenTrails
//
//  Single full-screen OpenStreetMap view that zooms to the user on launch.
//

import SwiftUI
import SwiftData
import WeatherKit
import OpenTrailsShared

struct OpenTrailsView: View {
    @Environment(OpenTrailsModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    @State private var showSheet = true
    @State private var searchText = ""
    @State private var sheetDetent: PresentationDetent = .height(80)
    @State private var selectedHike: Hike?
    /// The sheet's navigation stack, held here rather than inside `MapSheet`
    /// so a widget tap can push a hike's detail view (see `openHike(from:)`).
    /// The cost is that popping the detail view now re-evaluates this body
    /// too; `MapView` is `.equatable()`, so that diff stops at the map.
    @State private var navigationPath: [SheetRoute] = []
    @State private var highlight = RouteHighlight()
    /// Set when a picked file couldn't become a hike; drives the alert that
    /// says so. `nil` the rest of the time.
    @State private var importFailure: GPXImport.ImportFailure?
    /// Lets the hike detail view drive one-shot map commands (e.g. the Zoom button).
    @State private var mapController = MapController()
    /// Keeps the selected route's Core Location projection across unrelated
    /// body passes — see ``DisplayedRouteCoordinateCache``.
    @State private var displayedRouteCoordinateCache = DisplayedRouteCoordinateCache()
    /// The drawn route's tint and width, observed directly by the map. Both are
    /// written continuously — a `ColorPicker` drag and a `Slider` drag — so
    /// reading them here would put every drag sample through this body and the
    /// `.sheet` closure inside it. It follows the selected hike instead; see
    /// ``RouteStyle``.
    @State private var routeStyle = RouteStyle()

    /// The sheet's live top edge, observed directly by the map so dragging the
    /// sheet never re-renders this view or the sheet's contents.
    @State private var sheetMetrics = SheetMetrics()

    /// The selected tile provider, persisted by the settings sheet.
    @AppStorage(SettingsKey.tileProviderID) private var tileProviderID = TileProvider.default.id

    /// The route drawn on the map — always the currently selected hike, if any.
    /// Geometry only: its appearance reaches the map through ``routeStyle``,
    /// which is what keeps a colour or width drag out of this body.
    private var displayedRoute: DisplayedRoute? {
        DisplayedRoute.forSelection(selectedHike, cache: displayedRouteCoordinateCache)
    }

    /// Resolves the selected provider (with API key substituted) for the map.
    private var activeTileSource: ActiveTileSource {
        ActiveTileSource(TileProvider.renderable(id: tileProviderID))
    }

    /// `.alert(isPresented:error:)` wants a `Bool`; the message lives in
    /// ``importFailure``, so dismissal clears that rather than a second flag
    /// the two could disagree on.
    private var showingImportFailure: Binding<Bool> {
        Binding(
            get: { importFailure != nil },
            set: { if !$0 { importFailure = nil } }
        )
    }

    var body: some View {
        // Fires on every re-evaluation of this view's body — the throttled
        // `appModel.locationManager.coordinate` publish (~1/sec while moving)
        // is the
        // most likely repeat offender; compare its rate here against the
        // `MapUpdateCalled`/`MapCentered` marks in MapView.
        RenderSignpost.mark("OpenTrailsViewBody")
        return MapView(
            locationManager: appModel.locationManager,
            route: displayedRoute,
            routeStyle: routeStyle,
            highlight: highlight,
            recordingTrace: appModel.hikeRecorder.trace,
            sheetMetrics: sheetMetrics,
            tileSource: activeTileSource,
            mapController: mapController
        )
            .equatable()
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                if let current = appModel.weatherManager.current {
                    WeatherBadge(weather: current)
                        .padding(.leading)
                        .padding(.top, 96)
                }
            }
            .task { await appModel.locationManager.start() }
            .task { await appModel.pollWeather() }
            .task { restoreLastSelectedHike() }
            .task { appModel.trimTileCache(in: modelContext) }
            .sheet(isPresented: $showSheet) {
                MapSheet(
                    searchText: $searchText,
                    detent: $sheetDetent,
                    selectedHike: $selectedHike,
                    path: $navigationPath,
                    highlight: highlight,
                    mapController: mapController,
                    onImportGPX: importGPX,
                    onImportFailed: { importFailure = .unreadable },
                    onSheetTopChange: { sheetMetrics.topY = $0 }
                )
                    .presentationDetents([.height(80), .medium, .large], selection: $sheetDetent)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationBackground {
                        #if os(visionOS)
                        Color.clear
                        #else
                        Color.clear.glassEffect(.clear, in: Rectangle())
                        #endif
                    }
                    .presentationDragIndicator(.visible)
                    .interactiveDismissDisabled()
            }
            // The sheet is the app's primary surface and must always stay up. The
            // GPX document picker (a UIKit controller presented from within a
            // detented sheet) tears the sheet down on dismissal — a known SwiftUI
            // issue — so if it ever goes away, bring it right back.
            .onChange(of: showSheet) { _, shown in
                if !shown { showSheet = true }
            }
            // Presented from here rather than from the sheet: the document
            // picker's dismissal tears the sheet down (see above), and an alert
            // owned by a view that's being rebuilt at that moment doesn't
            // reliably appear.
            .alert(isPresented: showingImportFailure, error: importFailure) {
                Button("OK", role: .cancel) {}
            }
            .onOpenURL { url in openWidgetLink(url) }
            // Follows the selected hike so auto-save always tracks what's on screen.
            .onChange(of: selectedHike) { _, hike in
                if hike == nil {
                    displayedRouteCoordinateCache.clear()
                }
                // Hands the map the new route's appearance, and re-points the
                // tracking that keeps it current, without this body ever
                // reading either value — a change handler is not a body pass,
                // so nothing here becomes a dependency of this view.
                routeStyle.follow(hike)
                appModel.selectedHikeDidChange(to: hike)
            }
    }

    /// Handles a widget tap, opening either the live recording or a hike.
    ///
    /// Does nothing if its detail view is already the thing on screen —
    /// coming back to the app you were already looking at shouldn't reshuffle
    /// it. Otherwise the hike is selected (drawing its route on the map) and
    /// pushed, replacing rather than stacking onto whatever was open, since
    /// the widget is a jump to one trail and not a step in a journey.
    private func openWidgetLink(_ url: URL) {
        guard let destination = TrailWidgetDeepLink.destination(from: url)
        else {
            return
        }
        switch destination {
        case .recording:
            guard appModel.hikeRecorder.isActive else { return }
            searchText = ""
            SheetRoute.reopenRecording(in: &navigationPath)
            withAnimation { sheetDetent = .medium }
        case .hike(let id):
            openHike(id: id)
        }
    }

    private func openHike(id: UUID) {
        if case let .hike(current)? = navigationPath.last, current.id == id {
            return
        }

        let descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })
        // A hike deleted while the widget still showed it: open the app and
        // leave the user on the search page rather than acting on a ghost.
        guard let hike = try? modelContext.fetch(descriptor).first else { return }

        // Clearing the query drops the search results the sheet would
        // otherwise still be showing over the detail view.
        searchText = ""
        selectedHike = hike
        if navigationPath.contains(.recording) {
            navigationPath.append(.hike(hike))
        } else {
            navigationPath = [.hike(hike)]
        }
        // The compact detent is only tall enough for the search field, so a
        // push there would arrive off-screen.
        withAnimation { sheetDetent = .medium }
    }

    /// Restores the last-selected hike across launches — today `selectedHike`
    /// starts every launch as `nil`, so without this the widget would
    /// stay empty until the user reselects a trail by hand.
    ///
    /// Skipped while hosting tests: restoring a selection publishes a widget
    /// payload into the App Group and reloads the widget's timelines,
    /// underneath suites whose whole subject is that one file. It's a race no
    /// test can win, and it made a widget-feed assertion fail with whatever
    /// trail this simulator was last left on. See ``AppLaunchEnvironment``.
    private func restoreLastSelectedHike() {
        guard selectedHike == nil else { return }
        selectedHike = appModel.restoreLastSelectedHike(in: modelContext)
    }

    /// Parses a picked .gpx file, persists it as a `Hike`, and shows it on the map.
    /// A file that can't become a hike raises ``importFailure`` rather than
    /// leaving the user looking at an unchanged screen.
    private func importGPX(from url: URL) {
        Task {
            // Typed, so the catch below can't quietly widen to `any Error` and
            // start swallowing something this screen has no message for.
            do throws(GPXImport.ImportFailure) {
                selectedHike = try await appModel.importHike(
                    from: url,
                    into: modelContext
                )
            } catch {
                importFailure = error
                return
            }

            // The selection draws the imported route; expanding reveals it.
            withAnimation { sheetDetent = .medium }
        }
    }
}

private struct WeatherBadge: View {
    let weather: CurrentWeather

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: weather.symbolName)
                .symbolRenderingMode(.multicolor)
                .font(.title3)
            Text("\(Int(weather.temperature.value.rounded()))°")
                .font(.headline)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

#Preview {
    let container = try! ModelContainer(for: Hike.self, configurations: .init(isStoredInMemoryOnly: true))
    let model = OpenTrailsModel(
        container: container,
        backgroundTracker: BackgroundTrailTracker(container: container),
        autoSaveController: AutoSaveController(),
        hikeRecorder: HikeRecorder(
            container: container,
            journalDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("recording-preview", isDirectory: true),
            automaticallyRecovers: false
        ),
        locationManager: LocationManager(),
        weatherManager: WeatherManager()
    )
    OpenTrailsView()
        .environment(model)
        .modelContainer(container)
}
