//
//  OpenHikesView.swift
//  OpenHikes
//
//  Single full-screen OpenStreetMap view that zooms to the user on launch.
//

import OpenHikesShared
import SwiftData
import SwiftUI
import WeatherKit

struct OpenHikesView: View {
    @Environment(OpenHikesModel.self)
    private var appModel
    @Environment(\.modelContext)
    private var modelContext

    @State private var showSheet = true
    @State private var searchText = ""
    @State private var sheetDetent: PresentationDetent = .height(Self.compactDetentHeight)
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
    /// Invalidates an import's permission to replace the current selection
    /// when recording or navigation moves on while GPX parsing is off-main.
    @State private var importSelectionGate = ImportSelectionGate()
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
    @State private var didProcessLaunchFixture = false

    /// The selected tile provider, persisted by the settings sheet.
    @AppStorage(SettingsKey.tileProviderID)
    private var tileProviderID = TileProvider.default.id

    /// Height of the compact (search-only) sheet detent.
    private static let compactDetentHeight: CGFloat = 80
    /// Top padding for the weather badge, sitting below the Dynamic Island/notch.
    private static let weatherBadgeTopPadding: CGFloat = 96

    init() {
        _sheetDetent = State(
            initialValue: AppLaunchEnvironment.startsWithExpandedSheet
                ? .medium
                : .height(Self.compactDetentHeight)
        )
    }

    /// The route drawn on the map — always the currently selected hike, if any.
    /// Geometry only: its appearance reaches the map through ``routeStyle``,
    /// which is what keeps a colour or width drag out of this body.
    private var displayedRoute: DisplayedRoute? {
        DisplayedRoute.forSelection(
            selectedHike,
            cache: displayedRouteCoordinateCache,
            recordingPresented: navigationPath.last == .recording
                || selectedHike?.belongsToActiveRecording(
                    currentHikeID: currentRecordingHikeID
                ) == true
        )
    }

    private var selectedHikeState: SelectedHikeState? {
        selectedHike.map { hike in
            SelectedHikeState(
                id: hike.id,
                isRecording: hike.isRecording,
                isRecorderOwned: hike.id == currentRecordingHikeID
            )
        }
    }

    private var currentRecordingHikeID: UUID? {
        appModel.hikeRecorder.currentHike?.id
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

    private var showingStorageStartupIssue: Binding<Bool> {
        Binding(
            get: { appModel.startupIssue != nil },
            set: { if !$0 { appModel.startupIssue = nil } }
        )
    }

    var body: some View {
        // Fires on every re-evaluation of this view's body — the throttled
        // `appModel.locationManager.coordinate` publish (~1/sec while moving)
        // is the
        // most likely repeat offender; compare its rate here against the
        // `MapUpdateCalled`/`MapCentered` marks in MapView.
        RenderSignpost.mark("OpenHikesViewBody")
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
            .accessibilityIdentifier("trail-map")
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                if let current = appModel.weatherManager.current {
                    WeatherBadge(weather: current)
                        .padding(.leading)
                        .padding(.top, Self.weatherBadgeTopPadding)
                }
            }
            // Reads nothing and draws nothing outside a measured launch; see
            // ``PerformanceCounterProbe``.
            .overlay(alignment: .topTrailing) {
                #if DEBUG
                PerformanceCounterProbe()
                #endif
            }
            .onAppear {
                restoreLastSelectedHike()
                if AppLaunchEnvironment.usesLiveLocation {
                    appModel.locationManager.start()
                }
                if !AppLaunchEnvironment.isUITesting {
                    appModel.trimTileCache(in: modelContext)
                }
            }
            .task {
                if !AppLaunchEnvironment.isUITesting {
                    await appModel.pollWeather()
                }
            }
            .task { await importRequestedGPXFixture() }
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
                    .presentationDetents([.height(Self.compactDetentHeight), .medium, .large], selection: $sheetDetent)
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
                Button("OK", role: .cancel) { /* dismiss */ }
            }
            .alert(
                "Saved Hikes Unavailable",
                isPresented: showingStorageStartupIssue
            ) {
                Button("OK", role: .cancel) { /* dismiss */ }
            } message: {
                Text(
                    "OpenHikes couldn't open its saved hikes. " +
                    "This launch is using temporary storage, so changes won't survive a relaunch. " +
                    "Existing data was left untouched."
                )
            }
            .onOpenURL { url in openWidgetLink(url) }
            // Follows finished selections for map styling, auto-save, and
            // background route matching. A recording draft remains selected
            // in the list but is filtered by `OpenHikesModel`.
            .onChange(of: selectedHikeState) { _, _ in
                importSelectionGate.invalidate()
                if selectedHike == nil {
                    displayedRouteCoordinateCache.clear()
                }
                // Hands the map the new route's appearance, and re-points the
                // tracking that keeps it current, without this body ever
                // reading either value — a change handler is not a body pass,
                // so nothing here becomes a dependency of this view.
                routeStyle.follow(selectedHike)
                appModel.selectedHikeDidChange(to: selectedHike)
            }
            .onChange(of: navigationPath) { _, _ in
                importSelectionGate.invalidate()
            }
            .onChange(of: currentRecordingHikeID) { _, id in
                importSelectionGate.invalidate()
                guard let id,
                      let hike = appModel.hikeRecorder.currentHike,
                      hike.id == id else { return }
                selectedHike = hike
                highlight.move(to: nil)
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
        guard let destination = TrailWidgetDeepLink.destination(from: url) else { return }
        switch destination {
        case .recording:
            guard appModel.hikeRecorder.isActive else { return }
            searchText = ""
            SheetRoute.openRecording(
                hike: appModel.hikeRecorder.currentHike,
                selectedHike: &selectedHike,
                in: &navigationPath
            )
            highlight.move(to: nil)
            withAnimation { sheetDetent = .medium }
        case .hike(let id):
            openHike(id: id)
        }
    }

    private func openHike(id: UUID) {
        if case let .hike(current)? = navigationPath.last, current.id == id { return }

        let descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })
        // A hike deleted while the widget still showed it: open the app and
        // leave the user on the search page rather than acting on a ghost.
        guard let hike = try? modelContext.fetch(descriptor).first else { return }

        if hike.belongsToActiveRecording(
            currentHikeID: currentRecordingHikeID
        ), appModel.hikeRecorder.isActive {
            searchText = ""
            SheetRoute.openRecording(
                hike: hike,
                selectedHike: &selectedHike,
                in: &navigationPath
            )
            highlight.move(to: nil)
            withAnimation { sheetDetent = .medium }
            return
        }

        // Clearing the query drops the search results the sheet would
        // otherwise still be showing over the detail view.
        searchText = ""
        selectedHike = hike
        navigationPath = [.hike(hike)]
        // The compact detent is only tall enough for the search field, so a
        // push there would arrive off-screen.
        withAnimation { sheetDetent = .medium }
    }

    /// Restores an active recording draft when recovery has already found it;
    /// otherwise restores the last selected finished hike across launches.
    ///
    /// Skipped while hosting tests: restoring a selection publishes a widget
    /// payload into the App Group and reloads the widget's timelines,
    /// underneath suites whose whole subject is that one file. It's a race no
    /// test can win, and it made a widget-feed assertion fail with whatever
    /// trail this simulator was last left on. See ``AppLaunchEnvironment``.
    private func restoreLastSelectedHike() {
        if let recordingHike = appModel.hikeRecorder.currentHike {
            selectedHike = recordingHike
            highlight.move(to: nil)
            return
        }
        guard selectedHike == nil else { return }
        selectedHike = appModel.restoreLastSelectedHike(in: modelContext)
    }

    /// Parses a picked .gpx file, persists it as a `Hike`, and shows it on the map.
    /// A file that can't become a hike raises ``importFailure`` rather than
    /// leaving the user looking at an unchanged screen.
    private func importGPX(from url: URL) {
        Task { await performImport(from: url) }
    }

    private func importRequestedGPXFixture() async {
        guard !didProcessLaunchFixture,
              let name = AppLaunchEnvironment.importedGPXFixtureName else {
            return
        }
        didProcessLaunchFixture = true
        guard let url = Bundle.main.url(
            forResource: name,
            withExtension: "gpx"
        ) else {
            importFailure = .unreadable
            return
        }
        await performImport(from: url)
    }

    private func performImport(from url: URL) async {
        let selectionToken = importSelectionGate.token(
            selectedHikeID: selectedHike?.id,
            path: navigationPath
        )
        let importedHike: Hike
        // Typed, so the catch below can't quietly widen to `any Error` and
        // start swallowing something this screen has no message for.
        do throws(GPXImport.ImportFailure) {
            importedHike = try await appModel.importHike(
                from: url,
                into: modelContext
            )
        } catch {
            importFailure = error
            return
        }

        // The imported row remains persisted when another action won the
        // selection race; only its stale attempt to take over the map and
        // sheet is dropped.
        guard importSelectionGate.permits(
            token: selectionToken,
            selectedHikeID: selectedHike?.id,
            path: navigationPath,
            currentRecordingHikeID: currentRecordingHikeID,
            recordingPresented: navigationPath.last == .recording
        ) else { return }
        selectedHike = importedHike
        // The selection draws the imported route; expanding reveals it.
        withAnimation { sheetDetent = .medium }
    }
}

private struct SelectedHikeState: Equatable {
    let id: UUID
    let isRecording: Bool
    let isRecorderOwned: Bool
}

struct ImportSelectionGate {
    struct Token: Equatable {
        let revision: UInt64
        let selectedHikeID: UUID?
        let destination: Destination
    }

    enum Destination: Equatable {
        case root
        case recording
        case hike(UUID)
    }

    private(set) var revision: UInt64 = 0

    func token(
        selectedHikeID: UUID?,
        path: [SheetRoute]
    ) -> Token {
        Token(
            revision: revision,
            selectedHikeID: selectedHikeID,
            destination: destination(for: path)
        )
    }

    mutating func invalidate() {
        revision &+= 1
    }

    func permits(
        token: Token,
        selectedHikeID: UUID?,
        path: [SheetRoute],
        currentRecordingHikeID: UUID?,
        recordingPresented: Bool
    ) -> Bool {
        token.revision == revision
            && token.selectedHikeID == selectedHikeID
            && token.destination == destination(for: path)
            && currentRecordingHikeID == nil
            && !recordingPresented
    }

    private func destination(
        for path: [SheetRoute]
    ) -> Destination {
        switch path.last {
        case nil: .root
        case .some(.recording): .recording
        case .some(.hike(let hike)): .hike(hike.id)
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
                .accessibilityLabel(weather.condition.description)
            Text("\(Int(weather.temperature.value.rounded()))°")
                .font(.headline)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

#Preview {
    let container: ModelContainer
    do {
        container = try ModelContainer(for: Hike.self, configurations: .init(isStoredInMemoryOnly: true))
    } catch {
        preconditionFailure("Failed to create preview container: \(error)")
    }
    let model = OpenHikesModel(
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
    return OpenHikesView()
        .environment(model)
        .modelContainer(container)
}
