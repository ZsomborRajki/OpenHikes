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

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var locationManager = LocationManager()
    @State private var weatherManager = WeatherManager()
    @State private var showSheet = true
    @State private var searchText = ""
    @State private var sheetDetent: PresentationDetent = .height(80)
    @State private var selectedHike: Hike?
    @State private var highlight = RouteHighlight()
    /// Lets the hike detail view drive one-shot map commands (e.g. the Zoom button).
    @State private var mapController = MapController()
    /// Tracks which hike (if any) is passively auto-saving OSM tiles while browsed.
    @State private var autoSaveController = AutoSaveController()

    /// The sheet's live top edge, observed directly by the map so dragging the
    /// sheet never re-renders this view or the sheet's contents.
    @State private var sheetMetrics = SheetMetrics()

    /// The selected tile provider, persisted by the settings sheet.
    @AppStorage(SettingsKey.tileProviderID) private var tileProviderID = TileProvider.default.id

    /// The route drawn on the map — always the currently selected hike, if any.
    private var displayedRoute: DisplayedRoute? {
        guard let hike = selectedHike else { return nil }
        return DisplayedRoute(
            id: hike.id,
            coordinates: hike.coordinates,
            tint: hike.tint,
            width: hike.routeWidth
        )
    }

    /// Resolves the selected provider (with API key substituted) for the map.
    /// A key typed into Settings wins; otherwise fall back to the bundled key.
    private var activeTileSource: ActiveTileSource {
        let provider = TileProvider.provider(id: tileProviderID)
        let apiKey = provider.apiKeyDefaultsKey == SettingsKey.stadiaAPIKey ? (Secrets.stadiaAPIKey ?? "") : ""
        return ActiveTileSource(
            providerID: provider.id,
            urlTemplate: provider.resolvedTemplate(apiKey: apiKey),
            maximumZ: provider.maximumZ
        )
    }

    var body: some View {
        OSMMapView(
            coordinate: locationManager.coordinate,
            route: displayedRoute,
            highlight: highlight,
            sheetMetrics: sheetMetrics,
            tileSource: activeTileSource,
            mapController: mapController
        )
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                if let current = weatherManager.current {
                    WeatherBadge(weather: current)
                        .padding(.leading)
                        .padding(.top, 96)
                }
            }
            .task { await locationManager.start() }
            .task(id: weatherKey) {
                if let coordinate = locationManager.coordinate {
                    await weatherManager.update(for: coordinate)
                }
            }
            .sheet(isPresented: $showSheet) {
                MapSheet(
                    searchText: $searchText,
                    detent: $sheetDetent,
                    selectedHike: $selectedHike,
                    highlight: highlight,
                    mapController: mapController,
                    autoSave: autoSaveController,
                    onRecord: recordHike,
                    onImportGPX: importGPX,
                    onSheetTopChange: { sheetMetrics.topY = $0 }
                )
                    .presentationDetents([.height(80), .medium, .large], selection: $sheetDetent)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationBackground {
                        Color.clear.glassEffect(.clear, in: Rectangle())
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
            // Follows the selected hike so auto-save always tracks what's on screen.
            .onChange(of: selectedHike) { _, hike in
                autoSaveController.hikeSelectionChanged(to: hike)
            }
    }

    /// Coarse location key (~1 km) so weather refetches only on meaningful moves.
    private var weatherKey: String {
        guard let c = locationManager.coordinate else { return "none" }
        return "\(Int(c.latitude * 100)),\(Int(c.longitude * 100))"
    }

    // TODO: start a live GPS recording session.
    private func recordHike() {}

    /// Parses a picked .gpx file, persists it as a `Hike`, and shows it on the map.
    private func importGPX(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let track = GPXImport.load(from: url), track.points.count > 1 else { return }

        let title = track.name ?? url.deletingPathExtension().lastPathComponent
        let hike = Hike(
            title: title,
            distanceMeters: track.distanceMeters,
            date: track.startTime ?? .now,
            route: track.points.map {
                RouteCoordinate(
                    latitude: $0.coordinate.latitude,
                    longitude: $0.coordinate.longitude,
                    elevation: $0.elevation,
                    timestamp: $0.time
                )
            },
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
    ContentView()
}
