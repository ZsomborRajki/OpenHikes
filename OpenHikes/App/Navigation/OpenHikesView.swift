//
//  OpenHikesView.swift
//  OpenHikes
//
//  Single full-screen tiled map — OpenStreetMap by default, whichever
//  provider Settings selected otherwise — that zooms to the user's first fix.
//

import OpenHikesShared
import PhotosUI
import SwiftData
import SwiftUI

struct OpenHikesView: View {
    @Environment(OpenHikesModel.self)
    private var appModel
    @Environment(\.modelContext)
    private var modelContext

    @State private var showSheet = true
    @State private var searchText = ""
    @State private var selectedHike: Hike?
    /// The sheet's navigation stack and the height it rests at, held here
    /// rather than inside `MapSheet` so a widget tap can push a hike's detail
    /// view (see `openHike(id:)`) and so the detent picker can be attached to
    /// the sheet from out here.
    ///
    /// A reference type rather than two pieces of `@State`, because `@State`
    /// invalidates the view that declares it whether or not its body reads it —
    /// which is what made opening a photo from a hike's gallery re-render this
    /// view, the sheet and the hikes list. Only the coarse flags on it are read
    /// below; see ``SheetPresentation``.
    @State private var sheet = SheetPresentation()
    @State private var highlight = RouteHighlight()
    /// The stretches of the drawn route a finished walk covered, observed
    /// directly by the map — see ``WalkHighlight``.
    @State private var walkHighlight = WalkHighlight()
    /// Set when a picked file couldn't become a hike; drives the alert that
    /// says so. `nil` the rest of the time.
    ///
    /// Wider than the parser's own failure, because a file that read perfectly
    /// and a store that refused to keep it are different sentences and only
    /// one of them is about the walker's file. See ``HikeImportFailure``.
    @State private var importFailure: HikeImportFailure?
    @State private var searchFailure: SearchFailure?
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
    /// Whether the weather badge's detail sheet is up. A reference type for
    /// the reason ``SheetPresentation`` is one — and *presented* from inside
    /// `MapSheet`, because a modal attached beside a sheet that is never
    /// dismissed is never presented at all. See the `.weatherDetailSheet`
    /// call below.
    @State private var weatherDetail = WeatherDetailPresentation()
    /// Where the open hike's photos were taken, observed directly by the map.
    /// Owned here for the same reason ``photoCapture`` is: the pins are drawn
    /// on the map and the photos live on a screen inside the sheet.
    @State private var photoPins = PhotoMapPinController()
    @State private var didProcessLaunchFixture = false

    // swiftlint:disable private_swiftui_state
    /// Which screen a photo would be filed under. Owned here because the map's
    /// camera pill and the screens that offer it live on opposite sides of the
    /// sheet; see ``PhotoCaptureController``.
    ///
    /// Internal rather than private, along with the presentation state below,
    /// so the capture actions in `OpenHikesView+Photos.swift` can reach them —
    /// `private` is file-scoped in Swift, and those actions are long enough to
    /// have pushed this file past its length limit.
    @State var photoCapture = PhotoCaptureController()
    /// Camera and library presentation, driven by the pill's request tokens.
    /// Owned here because the pill and the screens that offer it sit on
    /// opposite sides of the sheet, but *presented* from inside `MapSheet` —
    /// a modal attached beside a sheet that is never dismissed is never
    /// presented at all. See the `.photoCapturePickers` call below.
    @State var photoPresentation = PhotoCaptureState()
    // swiftlint:enable private_swiftui_state

    /// The selected tile provider, persisted by the settings sheet.
    @AppStorage(SettingsKey.tileProviderID)
    private var tileProviderID = TileProvider.default.id

    /// Opt-in second copy of every photo in the system photo library. Off by
    /// default, and the only reason the app ever asks for photo-library
    /// access — see ``PhotoLibraryWriter``.
    @AppStorage(SettingsKey.savePhotosToLibrary)
    var savePhotosToLibrary = SettingsDefault.savePhotosToLibrary

    /// The route drawn on the map — always the currently selected hike, if any.
    /// Geometry only: its appearance reaches the map through ``routeStyle``,
    /// which is what keeps a colour or width drag out of this body.
    private var displayedRoute: DisplayedRoute? {
        DisplayedRoute.forSelection(
            selectedHike,
            cache: displayedRouteCoordinateCache,
            // The flag, not the path: a push inside the sheet that isn't the
            // recording screen leaves this alone, and the map's route with it.
            recordingPresented: sheet.isRecordingPresented
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
    /// `nil` when the selection draws MapKit's own base map, which installs no
    /// overlay and starts none of the tile pipeline.
    ///
    /// Reads `entitlement.state` rather than letting `renderable` default to
    /// the process-wide ``MapEntitlement``, and that is what the parameter is
    /// for. The global is a `Mutex`, not an observable: a subscription
    /// resolving to `.notEntitled` after launch — or lapsing while the app is
    /// running — changed the answer here without invalidating this body, so
    /// the paid overlay stayed on screen until something unrelated re-rendered
    /// the map. An observable read inside a computed var is an input of the
    /// body that calls it, which is precisely what makes the overlay be
    /// replaced. Not a render-isolation cost: entitlement settles once per
    /// launch and changes at most on a purchase or a lapse.
    private var activeTileSource: ActiveTileSource? {
        TileProvider.renderable(
            id: tileProviderID,
            entitlement: appModel.entitlement.state
        ).renderedSource
    }

    var body: some View {
        // Fires on every re-evaluation of this view's body. The observable
        // inputs here are `appModel.weatherManager.current` (~15 min) and
        // `appModel.hikeRecorder.currentHike` (start/stop) — everything
        // high-frequency is passed by reference and read inside MapKit
        // instead. `locationManager.coordinate` in particular is deliberately
        // *not* an input, so a rate here that tracks the ~1 Hz fix rate means
        // something upstream has started reading it. Compare against the
        // `MapUpdateCalled` mark in MapView and `MapCentered` in
        // MapCoordinator.
        RenderSignpost.mark("OpenHikesViewBody")
        return MapView(
            locationManager: appModel.locationManager,
            route: displayedRoute,
            routeStyle: routeStyle,
            highlight: highlight,
            walkHighlight: walkHighlight,
            recordingTrace: appModel.hikeRecorder.trace,
            sheetMetrics: sheetMetrics,
            tileSource: activeTileSource,
            mapController: mapController,
            photoCapture: photoCapture,
            photoPins: photoPins,
            // The same condition the overlay below is built on, so the credit
            // line knows whether there is a badge above it to hang from. Read
            // here rather than there because a `@ViewBuilder` closure cannot
            // hand a value back to the view it decorates.
            showsWeatherBadge: appModel.weatherManager.current != nil
        )
            .equatable()
            .accessibilityIdentifier("trail-map")
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                if let current = appModel.weatherManager.current {
                    WeatherBadge(weather: current) { weatherDetail.present() }
                        .padding(.leading, WeatherBadge.leadingPadding)
                        .padding(.top, WeatherBadge.topPadding)
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
                // Before the selection below, and before either sweep: it
                // rewrites the manifests both of them read, and the hike
                // restored here is the one whose auto-save store is seeded
                // from one. See ``LegacyTileKeyMigration``.
                //
                // Guarded exactly as the sweeps below are, and for the reason
                // spelled out there: this writes to the store and renames
                // files in it.
                if !AppLaunchEnvironment.isRunningTests, appModel.startupIssue == nil {
                    LegacyTileKeyMigration.run(in: modelContext)
                }
                restoreLastSelectedHike()
                if AppLaunchEnvironment.usesLiveLocation {
                    appModel.locationManager.start()
                }
                // `isRunningTests`, not `isUITesting`: a hosted unit-test run
                // launches the app against the *real* on-disk store, so the
                // narrower flag would let a sweep delete a developer's tiles
                // and photos.
                //
                // `startupIssue` is the same argument for the same reason. A
                // launch on the in-memory fallback fetches zero hikes
                // *successfully*, so the "a failed fetch sweeps nothing" rule
                // never fires — the claim set is legitimately empty and every
                // photo past the grace period is deleted, permanently, even
                // though the persistent store may open again next launch.
                if !AppLaunchEnvironment.isRunningTests, appModel.startupIssue == nil {
                    appModel.trimTileCache(in: modelContext)
                    appModel.reclaimOrphanedPhotos(in: modelContext)
                    // After the trim, which reads the sidecars this deletes
                    // rows from — the ones it reads belong to hikes that are
                    // still here, and are never the ones swept.
                    appModel.reclaimOrphanedLocalStates(in: modelContext)
                }
            }
            .task {
                if !AppLaunchEnvironment.isRunningTests {
                    await appModel.pollWeather()
                }
            }
            .task { await importRequestedGPXFixture() }
            .task { await seedRequestedLaunchFixtures() }
            .sheet(isPresented: $showSheet) {
                MapSheet(
                    searchText: $searchText,
                    selectedHike: $selectedHike,
                    presentation: sheet,
                    highlight: highlight,
                    walkHighlight: walkHighlight,
                    mapController: mapController,
                    photoCapture: photoCapture,
                    photoPins: photoPins,
                    onImportGPX: importGPX,
                    onImportFailed: { importFailure = .file(.unreadable) },
                    onSearchFailed: { failure in searchFailure = failure },
                    onSheetTopChange: { topY in
                        // Read when the sheet reports, not when this body runs:
                        // a drag reports at display rate, and this closure is
                        // called from a geometry change rather than evaluated
                        // here, so `isAtMiddleDetent` is not an input of this
                        // view.
                        sheetMetrics.report(topY: topY, atMiddleDetent: sheet.isAtMiddleDetent)
                    },
                    // The sheet settled at a new detent: let the map measure
                    // where the middle one rests, so the "my location" button
                    // knows how far it may follow the sheet up.
                    //
                    // Reported by the sheet rather than watched from here.
                    // Watching it would make the detent an input of this body
                    // again — and this view draws a map that does not move when
                    // the sheet does, which is the whole reason `SheetMetrics`
                    // exists.
                    onSheetDetentCommitted: { atMiddle in
                        sheetMetrics.detentCommitted(toMiddle: atMiddle)
                    }
                )
                    .presentationDetents(SheetPresentation.detents, selection: sheet.detentBinding)
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
                    // The camera and the library picker are presented from
                    // here, not from the view that presents this sheet: a view
                    // can only have one modal up at a time, and this sheet is
                    // never taken down, so a picker attached alongside it is
                    // never presented at all. Same reason the GPX importer
                    // hangs off ``MapSheet``.
                    .photoCapturePickers(
                        $photoPresentation,
                        onCaptured: attachCapturedPhoto,
                        onPicked: attachPickedPhotos
                    )
                    // Here for exactly the same reason: the badge that opens
                    // it is over the map, but a `.sheet` attached out there
                    // would be a tap that silently does nothing.
                    .weatherDetailSheet(weatherDetail, weather: appModel.weatherManager)
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
            // Here for the same reason as the import failure above, and
            // because a silent search is indistinguishable from a broken one.
            .alert(isPresented: showingSearchFailure, error: searchFailure) {
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
            .onOpenURL { url in openInboundURL(url) }
            .photoCaptureAlerts($photoPresentation)
            // The pill posts a token; flipping the presentation flags is this
            // view's job because it owns `photoPresentation`. The pickers
            // themselves hang off `MapSheet` above — a modal attached beside a
            // sheet that is never dismissed is never presented at all.
            .onChange(of: photoCapture.cameraRequest) { _, _ in
                Task { await presentCamera() }
            }
            .onChange(of: photoCapture.libraryRequest) { _, _ in
                photoPresentation.pickedPhotos = []
                photoPresentation.showLibraryPicker = true
            }
            // Re-points map styling, auto-save and background route matching
            // at the new selection. A recording draft still styles its route;
            // `OpenHikesModel` filters it out of the rest.
            .onChange(of: selectedHikeState) { _, _ in
                importSelectionGate.invalidate()
                if selectedHike == nil {
                    displayedRouteCoordinateCache.clear()
                }
                // A covered stretch belongs to the route it was drawn over.
                walkHighlight.clear()
                // Hands the map the new route's appearance, and re-points the
                // tracking that keeps it current, without this body ever
                // reading either value — a change handler is not a body pass,
                // so nothing here becomes a dependency of this view.
                routeStyle.follow(selectedHike)
                appModel.selectedHikeDidChange(to: selectedHike)
            }
            // Switching to (or away from) the system base map turns the tile
            // pipeline off (or back on) for whatever is already selected.
            // Without this, picking Apple Maps would leave auto-save running
            // for a map that draws no tiles, and picking a tile source back
            // again would leave it off until the selection changed.
            .onChange(of: tileProviderID) { _, _ in
                appModel.tileProviderDidChange(selectedHike: selectedHike)
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

    /// Restores an active recording draft when recovery has already found it;
    /// otherwise restores the last selected finished hike across launches.
    ///
    /// The stored-selection half is skipped while any test bundle is running:
    /// restoring a selection publishes a widget payload into the App Group and
    /// reloads the widget's timelines, underneath suites whose whole subject is
    /// that one file. The guard itself is in
    /// ``OpenHikesModel/restoreLastSelectedHike(in:)``; see
    /// ``AppLaunchEnvironment``.
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
        // Discarded explicitly rather than by `@discardableResult`: a
        // single-expression closure returns its value, and a `Task` carrying
        // an outcome that holds a `Hike` is a task carrying something
        // SwiftData does not let cross an isolation boundary.
        Task { _ = await performImport(from: url) }
    }

    private func importRequestedGPXFixture() async {
        guard !didProcessLaunchFixture,
              let name = AppLaunchEnvironment.importedGPXFixtureName else { return }
        didProcessLaunchFixture = true
        guard let url = Bundle.main.url(
            forResource: name,
            withExtension: "gpx"
        ) else {
            importFailure = .file(.unreadable)
            return
        }
        let outcome = await performImport(from: url)
        await seedRequestedPhotos(for: outcome.hike)
        seedRequestedWalks(for: outcome.hike)
    }

    /// Imports `url`, and hands back the hike it persisted — whether or not
    /// that hike went on to win the selection below. A caller with something
    /// left to do to the new hike needs the hike itself; reading the selection
    /// afterwards would hand it whatever won the race instead.
    ///
    /// Refused only when the file could not become a *kept* hike, which the
    /// alert this raises is already the report of. The failure is carried out
    /// as well as shown, because what a caller may do with the file next
    /// depends on which of the two failures it was — see
    /// ``HikeImportOutcome``.
    private func performImport(from url: URL) async -> HikeImportOutcome {
        let selectionToken = importSelectionGate.token(
            selectedHikeID: selectedHike?.id,
            path: sheet.path
        )
        #if DEBUG
        // Losing this race needs a navigation or selection change to land in
        // the moment a GPX parse takes, which is not something automation can
        // aim at. A scenario that is about the losing side asks for it here
        // instead; see ``AppLaunchEnvironment/losesImportSelection``.
        if AppLaunchEnvironment.losesImportSelection {
            importSelectionGate.invalidate()
        }
        #endif
        let importedHike: Hike
        // Typed, so the catch below can't quietly widen to `any Error` and
        // start swallowing something this screen has no message for.
        do throws(HikeImportFailure) {
            importedHike = try await HikeImport.hike(
                from: url,
                into: modelContext
            )
        } catch {
            importFailure = error
            return .refused(error)
        }

        // The imported row remains persisted when another action won the
        // selection race; only its stale attempt to take over the map and
        // sheet is dropped.
        guard importSelectionGate.permits(
            token: selectionToken,
            selectedHikeID: selectedHike?.id,
            path: sheet.path,
            currentRecordingHikeID: currentRecordingHikeID,
            recordingPresented: sheet.isRecordingPresented
        ) else { return .imported(importedHike) }
        selectedHike = importedHike
        // The selection draws the imported route; expanding reveals it.
        withAnimation { sheet.detent = .medium }
        return .imported(importedHike)
    }
}

// MARK: - Inbound URLs

/// What the system hands the app: a file to import, or a widget tap. Held
/// apart from the view's body for length, and because none of it draws.
private extension OpenHikesView {
    /// Routes a URL the system hands the app.
    ///
    /// Two unrelated things arrive here now that OpenHikes declares the GPX
    /// document type: a file opened from Files, AirDrop or a share sheet, and
    /// a widget tap. A file URL is never a widget link, so the split is on
    /// that rather than on a scheme this app doesn't own.
    private func openInboundURL(_ url: URL) {
        if url.isFileURL {
            openImportedFile(url)
        } else {
            openWidgetLink(url)
        }
    }

    /// Imports a file the system opened the app for, then discards it if it
    /// arrived as a copy. Unlike the document picker's file, this one may be
    /// the app's to clean up — see ``GPXInbox``.
    ///
    /// The copy goes when the file became a hike *and* when it never could:
    /// one that couldn't parse still won't on the next launch, and leaving it
    /// behind only hides it in a directory nothing else reads. The exception
    /// is a save the store refused, where this copy is the only source the app
    /// controls and the file itself was never the problem — see
    /// ``HikeImportOutcome/discardsSourceCopy``.
    private func openImportedFile(_ url: URL) {
        Task {
            let outcome = await performImport(from: url)
            if outcome.discardsSourceCopy {
                await GPXInbox.discardCopy(at: url)
            }
        }
    }

    /// Handles a widget tap, opening either the live recording or a hike.
    ///
    /// A hike whose detail view is already on screen is left alone — coming
    /// back to the app you were already looking at shouldn't reshuffle it.
    /// Otherwise the hike is selected (drawing its route on the map) and
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
                in: &sheet.path
            )
            highlight.move(to: nil)
            withAnimation { sheet.detent = .medium }
        case .hike(let id): openHike(id: id)
        }
    }

    private func openHike(id: UUID) {
        if case let .hike(current)? = sheet.path.last, current.id == id { return }

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
                in: &sheet.path
            )
            highlight.move(to: nil)
            withAnimation { sheet.detent = .medium }
            return
        }

        // Clearing the query drops the search results the sheet would
        // otherwise still be showing over the detail view.
        searchText = ""
        selectedHike = hike
        sheet.path = [.hike(hike)]
        // The compact detent is only tall enough for the search field, so a
        // push there would arrive off-screen.
        withAnimation { sheet.detent = .medium }
    }
}

// MARK: - Launch fixtures

/// The bundled stand-ins a UI-testing launch can ask for, held apart from the
/// view's own body: none of it draws anything, and none of it exists in a
/// shipping build.
private extension OpenHikesView {
    /// Gives the imported hike the photos a walk would have come home with.
    ///
    /// After the import rather than inside it, because the selection race
    /// `performImport` arbitrates is about which hike owns the map — a hike
    /// that lost it still persisted, and is still the one to photograph. Which
    /// is why the hike is passed in: reading the selection here would
    /// photograph whatever won that race, and on a launch where the import
    /// lost it there is nothing selected to photograph at all.
    func seedRequestedPhotos(for hike: Hike?) async {
        #if DEBUG
        let count = AppLaunchEnvironment.seededPhotoCount
        guard count > 0, let hike else { return }
        await SeededPhotoFixture.attach(count: count, to: hike)
        #endif
    }

    /// Gives the imported hike the walks a walker would have come home with,
    /// so the History segment and the summary can be checked in seconds
    /// rather than after a simulated stroll. Mirrors ``seedRequestedPhotos``.
    func seedRequestedWalks(for hike: Hike?) {
        #if DEBUG
        guard let name = AppLaunchEnvironment.seededWalkFixtureName, let hike else { return }
        SeededWalkFixture.attach(named: name, to: hike, in: modelContext)
        #endif
    }

    /// The launch fixtures that belong to no hike: device reports and a
    /// weather reading.
    ///
    /// Separate from the GPX task because neither depends on an import having
    /// happened — Settings and the badge are reachable from a launch with no
    /// hikes at all, and making them wait on a fixture they do not use would
    /// tie two unrelated scenarios together.
    func seedRequestedLaunchFixtures() async {
        #if DEBUG
        if AppLaunchEnvironment.stubsWeather {
            appModel.weatherManager.applyUITestSnapshot()
        }
        await SeededFieldMetricsFixture.seed(
            count: AppLaunchEnvironment.seededMetricsReportCount
        )
        #endif
    }
}

private struct SelectedHikeState: Equatable {
    let id: UUID
    let isRecording: Bool
    let isRecorderOwned: Bool
}

private extension OpenHikesView {
    /// `.alert(isPresented:error:)` wants a `Bool`; the message lives in
    /// ``importFailure``, so dismissal clears that rather than a second flag
    /// the two could disagree on. See `presenceBinding(for:)`.
    var showingImportFailure: Binding<Bool> {
        presenceBinding(for: $importFailure)
    }

    var showingSearchFailure: Binding<Bool> {
        presenceBinding(for: $searchFailure)
    }

    var showingStorageStartupIssue: Binding<Bool> {
        Binding(
            get: { appModel.startupIssue != nil },
            set: { if !$0 { appModel.startupIssue = nil } }
        )
    }

    /// Presents while `error` holds something, and clears it on dismissal, so
    /// there is never a second flag the two could disagree on.
    func presenceBinding<E>(for error: Binding<E?>) -> Binding<Bool> {
        Binding(
            get: { error.wrappedValue != nil },
            set: { if !$0 { error.wrappedValue = nil } }
        )
    }
}

/// Whether an import that was started a moment ago is still allowed to take
/// over the map and the sheet by the time it finishes parsing.
///
/// A navigation move needs no explicit invalidation: a token carries the
/// destination it was taken at, and ``permits(token:selectedHikeID:path:currentRecordingHikeID:recordingPresented:)``
/// compares it against where the sheet is now. ``invalidate()`` is for the
/// things a path can't answer — the selection changing under the import, and a
/// recording claiming it.
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
        // A photo viewer is a hike's own screen one push further in: an
        // import that arrives while it is open is still landing on the hike
        // the user is looking at.
        case .some(.photo(let hike, _)): .hike(hike.id)
        // A walk's summary is its hike's screen two pushes in, on the same
        // terms as the photo viewer.
        case .some(.walk(let walk)): .hike(walk.hikeID)
        }
    }
}

#Preview {
    let container: ModelContainer
    do {
        container = try ModelContainer.openHikes(isStoredInMemoryOnly: true)
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
