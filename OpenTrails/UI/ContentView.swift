//
//  ContentView.swift
//  OpenTrails
//
//  Single full-screen OpenStreetMap view that zooms to the user on launch.
//

import SwiftUI
import SwiftData
import CoreLocation
import WeatherKit
import OpenTrailsShared

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext

    /// Owned by `OpenTrailsApp`, not here — it has to already exist (and be
    /// delegated for location updates) before this view is ever built, so it
    /// can catch a background relaunch that never reaches this view at all.
    let backgroundTracker: BackgroundTrailTracker
    /// Owned by `OpenTrailsApp`, so scene lifecycle events are handled there.
    let autoSaveController: AutoSaveController

    @State private var locationManager = LocationManager()
    @State private var weatherManager = WeatherManager()
    @State private var showSheet = true
    @State private var searchText = ""
    @State private var sheetDetent: PresentationDetent = .height(80)
    @State private var selectedHike: Hike?
    /// The sheet's navigation stack, held here rather than inside `MapSheet`
    /// so a widget tap can push a hike's detail view (see `openHike(from:)`).
    /// The cost is that popping the detail view now re-evaluates this body
    /// too; `MapView` is `.equatable()`, so that diff stops at the map.
    @State private var navigationPath: [Hike] = []
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
        // `locationManager.coordinate` publish (~1/sec while moving) is the
        // most likely repeat offender; compare its rate here against the
        // `MapUpdateCalled`/`MapCentered` marks in MapView.
        RenderSignpost.mark("ContentViewBody")
        return MapView(
            locationManager: locationManager,
            route: displayedRoute,
            routeStyle: routeStyle,
            highlight: highlight,
            sheetMetrics: sheetMetrics,
            tileSource: activeTileSource,
            mapController: mapController
        )
            .equatable()
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                if let current = weatherManager.current {
                    WeatherBadge(weather: current)
                        .padding(.leading)
                        .padding(.top, 96)
                }
            }
            .task { await locationManager.start() }
            .task { await pollWeather() }
            .task { restoreLastSelectedHike() }
            .task { trimTileCache() }
            .sheet(isPresented: $showSheet) {
                MapSheet(
                    searchText: $searchText,
                    detent: $sheetDetent,
                    selectedHike: $selectedHike,
                    path: $navigationPath,
                    highlight: highlight,
                    mapController: mapController,
                    autoSave: autoSaveController,
                    locationManager: locationManager,
                    backgroundTracker: backgroundTracker,
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
            .onOpenURL { url in openHike(from: url) }
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
                autoSaveController.hikeSelectionChanged(to: hike)
                backgroundTracker.hikeSelectionChanged(to: hike)
                // The one persisted record of "what's selected" — restores it
                // on a normal launch (see `restoreLastSelectedHike`) and, on a
                // background relaunch, is all `backgroundTracker` has to go on.
                UserDefaults.standard.set(hike?.id.uuidString, forKey: SettingsKey.lastSelectedHikeID)
            }
    }

    /// Handles a tap on the trail widget: opens that hike's detail view.
    ///
    /// Does nothing if its detail view is already the thing on screen —
    /// coming back to the app you were already looking at shouldn't reshuffle
    /// it. Otherwise the hike is selected (drawing its route on the map) and
    /// pushed, replacing rather than stacking onto whatever was open, since
    /// the widget is a jump to one trail and not a step in a journey.
    private func openHike(from url: URL) {
        guard let id = TrailWidgetDeepLink.hikeID(from: url),
              navigationPath.last?.id != id else { return }

        let descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })
        // A hike deleted while the widget still showed it: open the app and
        // leave the user on the search page rather than acting on a ghost.
        guard let hike = try? modelContext.fetch(descriptor).first else { return }

        // Clearing the query drops the search results the sheet would
        // otherwise still be showing over the detail view.
        searchText = ""
        selectedHike = hike
        navigationPath = [hike]
        // The compact detent is only tall enough for the search field, so a
        // push there would arrive off-screen.
        withAnimation { sheetDetent = .medium }
    }

    /// Restores the last-selected hike across launches — today `selectedHike`
    /// starts every launch as `nil`, so without this the widget would
    /// stay empty until the user reselects a trail by hand.
    private func restoreLastSelectedHike() {
        guard selectedHike == nil,
              let stored = UserDefaults.standard.string(forKey: SettingsKey.lastSelectedHikeID),
              let id = UUID(uuidString: stored) else { return }
        let descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })
        selectedHike = try? modelContext.fetch(descriptor).first
    }

    /// Once-per-launch housekeeping: brings tiles no hike claims back under
    /// ``TileCache/cacheByteLimit``.
    ///
    /// Launch rather than a timer, and rather than on each save: browsing adds
    /// tiles a few tens of kilobytes at a time, so a bound that's checked once
    /// a session is checked often enough, and the check itself stats every
    /// cached file. Offline coverage is exempt — reading the manifests here is
    /// what makes it exempt, so this must not run before they can be read.
    private func trimTileCache() {
        // Auto-save can have tiles on disk that no manifest claims *yet*; a
        // trim that ran first would count them as residue and be entitled to
        // delete them.
        autoSaveController.flushPendingKeys()
        let claims = (try? modelContext.fetch(FetchDescriptor<Hike>()))?
            .filter(\.hasStoredTiles)
            .map(TileOwnership.init) ?? []
        Task.detached {
            let keys = claims.reduce(into: Set<String>()) { $0.formUnion($1.tileKeys()) }
            TileCache.shared.trimCache(claimedBy: keys)
        }
    }

    /// Polls without reading location from `body`, refreshing after movement or
    /// when the current reading expires. Failures use capped backoff so a
    /// stationary user recovers without continuously hitting WeatherKit.
    private func pollWeather() async {
        var state = WeatherPollState()
        while !Task.isCancelled {
            if let coordinate = locationManager.coordinate {
                let key = Self.weatherKey(for: coordinate)
                let requestedAt = Date()
                if state.shouldRequest(key: key, at: requestedAt) {
                    if await weatherManager.update(for: coordinate) {
                        state.recordSuccess(key: key, at: .now)
                    } else {
                        state.recordFailure(key: key, at: .now)
                    }
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private static func weatherKey(for coordinate: CLLocationCoordinate2D) -> String {
        "\(Int(coordinate.latitude * 100)),\(Int(coordinate.longitude * 100))"
    }

    /// Parses a picked .gpx file, persists it as a `Hike`, and shows it on the map.
    /// A file that can't become a hike raises ``importFailure`` rather than
    /// leaving the user looking at an unchanged screen.
    private func importGPX(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        Task {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let track: GPXImport.Track
            // Typed, so the catch below can't quietly widen to `any Error` and
            // start swallowing something this screen has no message for.
            do throws(GPXImport.ImportFailure) {
                track = try await GPXImport.loadOffMain(from: url)
                guard track.points.count > 1 else { throw .tooShort }
            } catch {
                importFailure = error
                return
            }

            let title = track.name ?? url.deletingPathExtension().lastPathComponent
            let hike = Hike(
                title: title,
                distanceMeters: track.distanceMeters,
                date: track.startTime ?? .now,
                tintHex: Hike.randomTintHex(),
                route: track.route,
                trackDescription: track.trackDescription,
                author: track.author,
                keywords: track.keywords
            )
            modelContext.insert(hike)

            // Select it (draws + zooms the route via `displayedRoute`) and reveal the map.
            selectedHike = hike
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
    ContentView(
        backgroundTracker: BackgroundTrailTracker(container: container),
        autoSaveController: AutoSaveController()
    )
    .modelContainer(container)
}
