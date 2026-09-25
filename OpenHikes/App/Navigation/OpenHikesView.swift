//
//  OpenHikesView.swift
//  OpenHikes
//
//  Single full-screen tiled map — OpenStreetMap by default, whichever
//  provider Settings selected otherwise — that zooms to the user's first fix.
//

import OpenHikesData
import OpenHikesShared
import PhotosUI
import SwiftData
import SwiftUI

struct OpenHikesView: View {
    /// Internal, like the state at the foot of this list, so the map's pin and
    /// line taps can be claimed from `OpenHikesView+MapTaps.swift` —
    /// `private` is file-scoped in Swift, and this file is at its length
    /// limit.
    @Environment(OpenHikesModel.self)
    var appModel
    @Environment(\.modelContext)
    var modelContext

    @State private var showSheet = true
    @State private var highlight = RouteHighlight()
    /// The stretches of the drawn route a finished walk covered, observed
    /// directly by the map — see ``WalkHighlight``.
    @State private var walkHighlight = WalkHighlight()
    @State private var searchFailure: SearchFailure?
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

    // swiftlint:disable private_swiftui_state
    /// The hike whose route the map draws, and whose screen the sheet opens
    /// to when it is tapped there.
    @State var selectedHike: Hike?
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
    @State var sheet = SheetPresentation()
    /// Where a tap on the drawn route goes. Owned here for the reason
    /// ``photoPins`` is: the line is drawn by MapKit and the screen it opens
    /// is a push into the stack this view owns. See ``DrawnRouteTap``.
    @State var drawnRouteTap = DrawnRouteTap()
    /// Raised by the map's refused "my location" button, presented by
    /// ``MapScreenAlerts`` on the sheet's contents. Owned here because the map
    /// raising it and the alert presenting it are on opposite sides of this
    /// view, and nothing between them can hold state.
    @State var locationAccessPrompt = LocationAccessPrompt()
    /// Which screen a photo would be filed under. Owned here because the map's
    /// camera pill and the screens that offer it live on opposite sides of the
    /// sheet; see ``PhotoCaptureController``.
    ///
    /// Internal rather than private, along with everything else in this block
    /// and the two environment values above, so the actions split out into
    /// `OpenHikesView+Photos.swift` and `OpenHikesView+MapTaps.swift` can
    /// reach them — `private` is file-scoped in Swift, and those actions are
    /// long enough to have pushed this file past its length limit.
    @State var photoCapture = PhotoCaptureController()
    /// Camera and library presentation, driven by the pill's request tokens.
    /// Owned here because the pill and the screens that offer it sit on
    /// opposite sides of the sheet, but *presented* from inside `MapSheet` —
    /// a modal attached beside a sheet that is never dismissed is never
    /// presented at all. See the `.photoCapturePickers` call below.
    @State var photoPresentation = PhotoCaptureState()
    /// The question a multi-track GPX file asks before it becomes hikes —
    /// see ``GPXTrackChoice``. Presented from inside `MapSheet`, like the
    /// pickers above.
    @State var gpxTrackChoice = GPXTrackChoice()
    /// Set when a picked file couldn't become a hike; drives the alert that
    /// says so. `nil` the rest of the time.
    ///
    /// Wider than the parser's own failure, because a file that read perfectly
    /// and a store that refused to keep it are different sentences and only
    /// one of them is about the hiker's file. See ``HikeImportFailure``.
    @State var importFailure: HikeImportFailure?
    /// Invalidates an import's permission to replace the current selection
    /// when recording or navigation moves on while GPX parsing is off-main.
    @State var importSelectionGate = ImportSelectionGate()
    @State var didProcessLaunchFixture = false
    // swiftlint:enable private_swiftui_state

    /// Whether the sheet's contents belong in ``MapSidePanel`` rather than in
    /// the sheet: iPhone landscape, where the system ignores
    /// `.presentationDetents` and would present the sheet — the one this view
    /// keeps up permanently — over the whole map. See ``SheetLayout``.
    ///
    /// The flag, not the environment. `verticalSizeClass` is read in
    /// ``SheetLayoutReader`` and reaches this body as a coarse published
    /// property, which changes when the device is turned over and at no other
    /// time. Reading the environment here instead re-ran this body on every
    /// scene transition, and the measurement that says so is in that file.
    private var usesSidePanel: Bool { sheet.layout == .sidePanel }

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

    var currentRecordingHikeID: UUID? {
        appModel.hikeRecorder.currentHike?.id
    }

    /// What the weather badge should be about when nothing outranks the
    /// selection. `nil` when nothing is selected, or when the selection has no
    /// geometry to be about yet.
    private var selectedTrailSubject: WeatherSubject? {
        guard let hike = selectedHike, let route = displayedRoute else { return nil }
        return .trail(id: hike.id, name: hike.title, along: route.coordinates)
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
        // Every observable read here re-runs this whole body. The inputs that
        // move are `appModel.weatherManager.state` (a focus change, or ~15
        // min), `appModel.hikeRecorder.currentHike` (start/stop) and
        // `appModel.hikeRecorder.isActive`, which reads the recorder's phase
        // and so moves a handful of times per session — everything
        // high-frequency is passed by reference and read inside MapKit
        // instead. `locationManager.coordinate` in particular is deliberately
        // *not* an input, so this body re-running at the ~1 Hz fix rate means
        // something upstream has started reading it, and neither is
        // `weatherFocus.subject`: the badge's subject reaches this body only
        // through the state above, which is written once per focus rather than
        // once per significant-change delivery.
        //
        // The landscape shape of the app's primary surface, beside the map
        // rather than over it — see ``MapSidePanel``. Nothing about it is
        // modal: the map keeps taking touches, and there is nothing to dismiss.
        //
        // A `ZStack` rather than one more overlay on the map, because an
        // overlay inherits the `.ignoresSafeArea()` below and would put the
        // panel under the Dynamic Island — which in landscape sits on the very
        // edge the panel is against. Here the map ignores the safe area on its
        // own and the panel is laid out inside it.
        ZStack(alignment: .leading) {
            mapSurface
            if usesSidePanel {
                MapSidePanel { mapSheet() }
            }
        }
            .overlay(alignment: .topLeading) {
                if appModel.weatherManager.state != .idle {
                    WeatherBadge(state: appModel.weatherManager.state) {
                        weatherDetail.present()
                    }
                        // Beside the panel in landscape, for the same reason
                        // the map's own controls are moved off that edge —
                        // this overlay is drawn under it otherwise, and a
                        // badge that cannot be tapped is a forecast withheld.
                        .padding(
                            .leading,
                            WeatherBadge.leadingPadding
                                + (usesSidePanel ? MapSidePanelLayout.mapInset : 0)
                        )
                        // And at the top of the map in landscape rather than a
                        // Dynamic Island's height down it.
                        //
                        // ``WeatherBadge/topPadding`` is measured from the
                        // screen's own edge and is what clears the island in
                        // *portrait*, where the island is at the top. Turned
                        // sideways the island is on a side edge, the status bar
                        // is gone, and 98 points is a quarter of the height the
                        // badge is supposed to be at the top of — so the reading
                        // ended up floating in the middle of the map.
                        //
                        // So landscape stays inside the safe area and takes
                        // ``MapSidePanel``'s own margin, which is what puts the
                        // badge's top edge level with the panel's rather than at
                        // a number of its own. Portrait keeps measuring from the
                        // screen edge, which is what `topPadding` is for.
                        .padding(
                            .top,
                            usesSidePanel ? MapSidePanelLayout.margin : WeatherBadge.topPadding
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .ignoresSafeArea(.container, edges: usesSidePanel ? [] : .vertical)
                }
            }
            // Handed the session and never reading it — see ``WalkStartedPill``.
            .overlay {
                WalkStartedPill(session: appModel.walkSession, usesSidePanel: usesSidePanel) { openHike(id: $0) }
            }
            // Draws nothing. It is where the vertical size class is read —
            // out of this body, deliberately and at a measured cost if it
            // moves back in. See ``SheetLayoutReader``.
            .background {
                SheetLayoutReader(presentation: sheet, metrics: sheetMetrics)
            }
    }

    /// The map, and everything presented over it.
    ///
    /// A computed property rather than a second `View` type, which changes
    /// nothing about what this body depends on: a `var` is inlined into the
    /// body that reads it, so the inputs are the same ones they were when this
    /// was written out in place. See *Render isolation, in practice*.
    private var mapSurface: some View {
        MapView(
            locationManager: appModel.locationManager,
            route: displayedRoute,
            routeStyle: routeStyle,
            highlight: highlight,
            walkHighlight: walkHighlight,
            recordingTrace: appModel.hikeRecorder.trace,
            sheetMetrics: sheetMetrics,
            tileSource: activeTileSource,
            mapController: mapController,
            drawnRouteTap: drawnRouteTap,
            locationAccessPrompt: locationAccessPrompt,
            photoCapture: photoCapture,
            photoPins: photoPins,
            placePins: appModel.placePins,
            trailMaker: appModel.trailMaker,
            recordingEntry: appModel.recordingEntry,
            community: appModel.community,
            searchCompleter: appModel.searchCompleter,
            // Keeps the credit line and the camera pill beside the landscape
            // panel instead of behind it.
            sidePanelInset: usesSidePanel ? MapSidePanelLayout.mapInset : 0
        )
            .equatable()
            .accessibilityIdentifier("trail-map")
            // The map fills the window. The weather
            // overlay belongs to the safe-area container above so its leading
            // edge agrees with the panel and the map's attribution guide.
            .ignoresSafeArea()
            .onAppear {
                restoreLastSelectedHike()
                claimMapTaps()
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
            // Last night's reading, put back after the first frame rather
            // than during app composition. It used to happen inside
            // ``WeatherManager``'s initializer, which put a JSON decode on the
            // main thread before anything was on screen — for a badge that has
            // nothing to draw against until a location fix arrives. See
            // ``WeatherManager/restoreLastReading()`` for why it is eager here
            // rather than lazy on the first focus.
            //
            // Unguarded by the test flags below it, because this is the launch
            // path working rather than a fixture: whichever of these tasks
            // runs first, the restore only claims a badge nothing else has.
            .task { appModel.weatherManager.restoreLastReading() }
            .task {
                if !AppLaunchEnvironment.isRunningTests {
                    await appModel.pollWeather()
                }
            }
            .task { await importRequestedGPXFixture() }
            .task { await seedRequestedLaunchFixtures() }
            .sheet(isPresented: $showSheet) {
                mapSheet(
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
                    // Keep the system's adaptive sheet glass rather than
                    // replacing it with a separate clear-glass surface.
                    #if os(visionOS)
                    .presentationBackground(Color.clear)
                    #endif
                    .presentationDragIndicator(.visible)
                    .interactiveDismissDisabled()
            }
            // The sheet is the app's primary surface in portrait and must always
            // stay up there. The GPX document picker (a UIKit controller
            // presented from within a detented sheet) tears the sheet down on
            // dismissal — a known SwiftUI issue — so if it ever goes away, bring
            // it right back. Landscape is the one dismissal that is meant, and
            // the condition below is what tells the two apart.
            .onChange(of: showSheet) { _, shown in
                if !shown, !usesSidePanel { showSheet = true }
            }
            // Rotation takes the sheet down and puts it back up: in landscape
            // the contents are in ``MapSidePanel`` and there is no sheet.
            //
            // Written into the flag rather than filtered through a `Binding`
            // built here, because such a binding is a new one on every pass of
            // this body and re-runs the sheet's content with it — measured as
            // one or two extra evaluations of `MapSheet`'s body per run. No
            // `initial:` for the same reason: a portrait launch, which is
            // nearly all of them, then writes nothing at all. A launch
            // straight into landscape is a real change of
            // ``SheetPresentation/layout`` and arrives here as one.
            .onChange(of: usesSidePanel) { _, isPanel in
                showSheet = !isPanel
            }
            .onOpenURL { url in openInboundURL(url) }
            // An intent asked for a hike, from outside the view tree. Handed
            // to the same router the widget's taps go through rather than a
            // second way in — see ``HikeOpenRequests``.
            .onChange(of: appModel.hikeOpenRequests.request) { _, _ in
                guard let url = appModel.hikeOpenRequests.link else { return }
                openInboundURL(url)
            }
            // The pill posts a token; flipping the presentation flags is this
            // view's job because it owns `photoPresentation`. The pickers and
            // the alerts that report what they couldn't do both hang off
            // `mapSheet()` above — a modal attached beside a sheet that is
            // never dismissed is never presented at all.
            .onChange(of: photoCapture.cameraRequest) { _, _ in
                Task { await presentCamera() }
            }
            .onChange(of: photoCapture.libraryRequest) { _, _ in
                photoPresentation.pickedPhotos = []
                photoPresentation.showLibraryPicker = true
            }
            .onChange(of: photoCapture.placeRequest) { _, _ in openPlaceAdder() }
            // The same shape, for the pill that shares that slot: the map
            // posts a token and the push belongs here, because this view owns
            // the sheet's navigation stack. Assigned rather than appended —
            // the maker is only ever offered when nothing is pushed, so there
            // is nothing to push it onto, and an assignment cannot stack a
            // second copy behind a double tap.
            .onChange(of: appModel.trailMaker.openRequest) { _, _ in
                sheet.path = [.trailDraft]
                // The map is the maker's canvas, and a hike left selected
                // would still be drawn across it. Let go of it rather than
                // hide it: a new trail is not about the old one, and a saved
                // drawing selects itself anyway — see `showSavedHike`.
                selectedHike = nil
                // The compact detent is only tall enough for the search field,
                // and `.large` covers the map the maker is drawn on. See
                // ``SheetPresentation/makeRoomForTheMap()``.
                sheet.makeRoomForTheMap()
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
            // Which place the weather badge is about — see ``WeatherFocus``.
            // In a modifier so the recorder's phase and the route's geometry
            // are read there rather than here.
            .weatherFocus(
                appModel.weatherFocus,
                trail: selectedTrailSubject,
                isRecording: appModel.hikeRecorder.isActive,
                hiker: {
                    appModel.locationManager.coordinate
                        ?? appModel.significantLocations.coordinate
                }
            )
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
            sheet.makeRoomForTheMap()
            return
        }
        guard selectedHike == nil else { return }
        selectedHike = appModel.restoreLastSelectedHike(in: modelContext)
        // A restored selection draws its route, and drawing a route frames it
        // against the map that is not behind the sheet — which is only the
        // right framing if the sheet is where the framing assumes. Launch is
        // the one place those two could disagree: the sheet starts at its
        // compact detent, so a route fitted for a middle-detent sheet would
        // land in the top of the screen with the bottom half empty. Every
        // other route this app draws is drawn by something that has already
        // asked for the same room. See ``SheetPresentation/makeRoomForTheMap()``.
        if selectedHike != nil { sheet.makeRoomForTheMap() }
    }
}

// MARK: - The primary surface

/// The sheet's contents and everything presented over them, kept out of the
/// view's own body so `type_body_length` measures the screen rather than the
/// plumbing — the same move the import helpers below made. Same file, so
/// these still reach the view's `private` state.
extension OpenHikesView {
    /// The app's primary surface, built once for both shapes it is drawn in.
    ///
    /// The two callbacks are the whole difference: a side panel does not move,
    /// rests at no detent, and has nothing to report to ``SheetMetrics``.
    ///
    /// The camera, the library picker and the weather detail are attached here
    /// rather than beside the presentation, for the reason the repository
    /// instructions give under *Present modals from inside the sheet's
    /// contents*: a view
    /// can only have one modal up at a time, and in portrait this sheet is
    /// never taken down, so a picker attached alongside it is never presented
    /// at all. In landscape there is no sheet and the panel is an ordinary
    /// overlay — attaching them to the contents is what keeps one answer right
    /// in both shapes. Same reason the GPX importer hangs off ``MapSheet``.
    private func mapSheet(
        onSheetTopChange: @escaping (CGFloat) -> Void = { _ in /* no-op default */ },
        onSheetDetentCommitted: @escaping (Bool) -> Void = { _ in /* no-op default */ }
    ) -> some View {
        MapSheet(
            selectedHike: $selectedHike,
            presentation: sheet,
            highlight: highlight,
            walkHighlight: walkHighlight,
            mapController: mapController,
            photoCapture: photoCapture,
            photoPins: photoPins,
            placePins: appModel.placePins,
            trailMaker: appModel.trailMaker,
            onImportGPX: importGPX,
            onImportFailed: { importFailure = .file(.unreadable) },
            onSearchFailed: { failure in searchFailure = failure },
            onSheetTopChange: onSheetTopChange,
            onSheetDetentCommitted: onSheetDetentCommitted
        )
            .photoCapturePickers(
                $photoPresentation,
                onCaptured: attachCapturedPhoto,
                onPicked: attachPickedPhotos
            )
            .weatherDetailSheet(weatherDetail, weather: appModel.weatherManager)
            .gpxTrackChoice(gpxTrackChoice)
            .mapScreenAlerts(
                importFailure: $importFailure,
                searchFailure: $searchFailure,
                startupIssue: showingStorageStartupIssue,
                locationAccess: locationAccessPrompt.isShowingBinding,
                photoCapture: $photoPresentation
            )
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
            guard appModel.hikeRecorder.hasScreenToShow else { return }
            sheet.searchText = ""
            SheetRoute.openRecording(
                hike: appModel.hikeRecorder.currentHike,
                selectedHike: &selectedHike,
                in: &sheet.path
            )
            highlight.move(to: nil)
            sheet.makeRoomForTheMap()
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
            sheet.searchText = ""
            SheetRoute.openRecording(
                hike: hike,
                selectedHike: &selectedHike,
                in: &sheet.path
            )
            highlight.move(to: nil)
            sheet.makeRoomForTheMap()
            return
        }

        // Clearing the query drops the search results the sheet would
        // otherwise still be showing over the detail view.
        sheet.searchText = ""
        selectedHike = hike
        sheet.path = [.hike(hike)]
        // The compact detent is only tall enough for the search field, so a
        // push there would arrive off-screen.
        sheet.makeRoomForTheMap()
    }
}

// MARK: - Launch fixtures

/// The bundled stand-ins a UI-testing launch can ask for, held apart from the
/// view's own body: none of it draws anything, and none of it exists in a
/// shipping build. Internal rather than private so the import in
/// `OpenHikesView+GPXImport.swift` can hand its hike to them.
extension OpenHikesView {
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

    /// Gives the imported hike the walks a hiker would have come home with,
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
        // First, so a scenario that also imports a GPX gets the imported hike
        // *above* these: it is the newest, and the list is newest-first.
        SeededLibraryFixture.seed(
            count: AppLaunchEnvironment.seededLibraryHikeCount,
            in: modelContext
        )
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
    /// Whether this launch is on temporary storage. The alert's dismissal
    /// clears the model's own issue rather than a second flag the two could
    /// disagree on — the same arrangement ``MapScreenAlerts`` uses for the
    /// two failures it owns a value for.
    var showingStorageStartupIssue: Binding<Bool> {
        Binding(
            get: { appModel.startupIssue != nil },
            set: { if !$0 { appModel.startupIssue = nil } }
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
        /// The trail maker. Its own case rather than folded into ``root`` for
        /// the reason ``communityHike(_:)`` has one: a hiker part way through
        /// drawing a line must not have the map's selection — and the route
        /// drawn on it — replaced by a GPX arriving from Files.
        case trailDraft
        /// The library's totals. Its own case so an import finishing while
        /// they are open does not pull the screen out from under them.
        case totals
        case hike(UUID)
        /// A published hike's preview, keyed by its listing.
        ///
        /// Its own case rather than folded into ``root``, because an import
        /// that finishes while one is open must not take the map: the hiker
        /// is looking at somebody else's trail and deciding whether to keep
        /// it, and a GPX arriving from Files is a different hike entirely.
        /// Folding it into `.root` would make the gate say the screen never
        /// changed.
        case communityHike(String)
        /// A submission being reviewed, keyed by its queue entry.
        ///
        /// Its own case for the reason above, sharpened: a reviewer is part
        /// way through deciding whether a stranger's hike goes in front of
        /// everybody, and an arriving GPX must not pull the screen out from
        /// under that. Distinct from ``communityHike(_:)`` because the two
        /// names come from different record types and mean different things,
        /// even though no two of them would ever collide.
        case pendingSubmission(String)
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
        // Inert for the reason the location source below is dormant: a
        // preview must not reach anything outside itself — here, the App
        // Group the hiker's own widget reads.
        weatherManager: WeatherManager(widgetPublisher: .inert),
        // Dormant: a preview must not arm significant-change monitoring.
        significantLocations: SignificantLocationFeed(monitor: DormantLocationSource())
    )
    return OpenHikesView()
        .environment(model)
        .modelContainer(container)
}

// MARK: - Add Place

// In this file rather than beside the photo handlers, because the map's
// controller is private to it.
private extension OpenHikesView {
    /// Opens *Add Place* at the spot the pill resolved, with a pin standing
    /// there and the map on it.
    ///
    /// The spot is read at the tap, as a photograph's is at the shutter: the
    /// live match while auto-follow has one, otherwise wherever the elevation
    /// graph's tracker is — see
    /// ``PhotoTrailAnchor/placeCoordinate(profile:live:scrubbed:)``. The
    /// sheet goes to its middle detent before the camera moves, because
    /// that is the height the move frames its target above — see
    /// ``SheetPresentation/restAtMiddleWhenFullHeightScreenPops()``.
    func openPlaceAdder() {
        guard let spot = photoCapture.placeSpot() else { return }
        sheet.path.append(.newPlace(spot.hike, HikePlaceSpot(spot.coordinate)))
        sheet.makeRoomForTheMap()
        mapController.showPhotoSpot(spot.coordinate)
    }
}
