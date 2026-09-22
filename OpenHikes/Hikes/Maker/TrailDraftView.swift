//
//  TrailDraftView.swift
//  OpenHikes
//
//  The maker: the sheet's half of drawing a trail.
//
//  The map above is the canvas and this is everything that is not the canvas —
//  the route so far, what is marked along it, and the two ways out.
//  What the trail is *called* is not among them: it is asked for once, in an
//  alert, at the moment Save is tapped, exactly as a stopped recording is
//  named — see ``RecordingControls``. A field standing open beside the stops
//  asked the question for the whole of the drawing and had to be answered
//  before it could be scrolled past, when the answer is only wanted at the
//  end. It draws no map of its own and never could: the map it is
//  about is the one behind the sheet, which is the whole reason this is a
//  pushed screen rather than a modal over the map.
//
//  ## The route is Apple Maps' directions list
//
//  A start, its numbered stops and a destination, joined by a dotted line, with
//  a grabber on every row and *Add Stop* pinned underneath — see
//  ``TrailStopRowView`` and ``TrailAddStopRow``. Three things follow from that
//  and each is load-bearing rather than styling.
//
//  **The list is in edit mode permanently**, which is what keeps the grabbers
//  on screen, and which is only possible because a `Button` row still answers a
//  tap while it is — the finding the hikes list did *not* make, since what it
//  found was about a `NavigationLink`. `TrailMakerUITests` presses one, because
//  nothing below a simulator can. What edit mode does take away is the swipe:
//  a stop is removed with the red circle on the leading edge now.
//
//  **A row is a field.** Tapping one opens ``TrailStopSearchSheet`` on it, and
//  the place picked there fills that row and takes the camera to it — which is
//  why the *Find a Place* field that used to head this screen is gone rather
//  than kept beside it. Every search still moves the map; it just leaves a stop
//  where it arrives.
//
//  **A stop the hiker only tapped on the map still says where it is.**
//  ``TrailStopNamer`` asks what is at the coordinate a second later. There is
//  an icon-only travel-mode selector above the stops. Follow Paths remains
//  independent: turning it off draws freehand in any mode.
//
//  Every mutation goes through ``TrailDraftController`` rather than through
//  ``TrailDraft`` directly, because the controller is the one that also writes
//  the draft down — see its header.
//
//  No `@Environment(\.dismiss)` here, and none in the toolbar either. Both
//  ways out are callbacks the sheet supplies, because what has to happen is a
//  change to the sheet's navigation stack and the selection beside it, which
//  is ``MapSheet``'s to make — the same arrangement ``RecordingView`` takes
//  its `onSaved` and `onDiscarded` in. See ``DismissButton`` for what
//  declaring the environment value here would have cost.
//

import MapKit
import OpenHikesShared
import SwiftData
import SwiftUI

struct TrailDraftView: View {
    let maker: TrailDraftController
    /// Borrowed for the search sheet a stop row opens. The map feeds it a
    /// settled region, so suggestions are answered near what the hiker is
    /// looking at.
    let completer: SearchCompleter
    /// How a picked place moves the camera.
    let mapController: MapController
    /// The hiker's own position, for *Mark a Place → At My Location*. `nil`
    /// for a launch with no location, which withholds that one entry.
    var locationManager: LocationManager?
    var onCancel: () -> Void
    var onSaved: (Hike) -> Void

    @Environment(\.modelContext)
    private var modelContext

    /// The one refusal a hiker can reach from the Save button — the store said
    /// no. ``TrailDraftRefusal/tooShort`` is unreachable from here because the
    /// button is disabled, and it exists because
    /// ``TrailDraftSave`` is asked by more than a button.
    @State private var refusal: TrailDraftRefusal?
    @State private var isConfirmingCancel = false
    /// *Clear* is the one edit that asks first — see ``TrailDraftActionsMenu``
    /// for why it is the only one.
    @State private var isConfirmingClear = false
    /// When the hiker asked to save, and `nil` whenever they have not.
    ///
    /// A date rather than a flag because it is also *the* date: the trail is
    /// written as made at this instant, so the name the placeholder promises
    /// for a blank field and the name a blank field actually writes are the
    /// same string rather than two readings of the clock a few keystrokes
    /// apart.
    @State private var namingStartedAt: Date?
    /// What is being typed into that alert. A reference type, so a keystroke
    /// does not rebuild the list of points underneath it — see
    /// ``TrailDraftName``.
    @State private var name = TrailDraftName()
    /// The stop search, held here rather than in the sheet that runs it — see
    /// ``TrailStopSearchRun``.
    @State private var search = TrailStopSearchRun()
    /// Whether the search sheet is up.
    ///
    /// A flag beside the run above rather than an `item:` presentation off
    /// ``TrailStopSearchRun/target``, for the reason ``isEditingPlace`` is one:
    /// the target is what the sheet is *about* and this is whether it is on
    /// screen, and a hiker who swipes it away has changed the second without
    /// changing the first.
    @State private var isSearchingStop = false
    /// What is being typed into the place editor. Held here rather than in the
    /// sheet, so it survives the sheet being torn down while the write it
    /// carries is going through — see ``TrailPlaceEdit``.
    @State private var placeEdit = TrailPlaceEdit()
    /// Whether that sheet is up.
    ///
    /// A flag beside the edit above rather than an `item:` presentation off
    /// ``TrailDraftController/placeEditorRequest``, because the request is a
    /// one-shot token the map raises and this is a presentation the screen
    /// owns: the hiker can close the sheet, and the token that opened it does
    /// not change when they do.
    @State private var isEditingPlace = false
    /// Whether the camera has already been taken to the drawing this screen was
    /// opened on.
    ///
    /// Once per push, which is exactly the rule wanted: a hiker who leaves a
    /// half-drawn trail, opens somebody else's walk and comes back finds the
    /// map where their points are, while one who opens the search sheet and
    /// closes it again keeps the camera the sheet moved. `@State` is what
    /// counts pushes here — a new one is a new screen and a fresh `false`.
    @State private var hasFramedTheDrawing = false

    private var draft: TrailDraft { maker.draft }

    var body: some View {
        List {
            TrailTravelModePicker(maker: maker)
            routeSection

            // Withheld when this launch has no provider for the chosen mode.
            // A switch that cannot change the line is worse than no switch.
            if maker.canSnapToPaths {
                TrailDraftSnapToggle(maker: maker)
            }

            TrailDraftPlaceSection(
                maker: maker,
                completer: completer,
                locationManager: locationManager,
                search: search,
                onEdit: editPlace
            )
            // Under the places the hiker has marked, because that is what it
            // is: the same kind of row, not yet taken. Absent entirely until a
            // search has answered — see ``TrailDraftNearbySection``.
            TrailDraftNearbySection(maker: maker, onEdit: editPlace)
        }
        // **Always on, and that is the redesign rather than an oversight.**
        // A `List` shows its reorder grabbers and offers its drag only while
        // edit mode is `.active`, and this screen's rows are now Apple Maps'
        // directions rows — a start, its stops and its destination, each with a
        // handle, rearrangeable at any moment without first asking to be. A
        // mode the hiker had to enter was what Phase 6 had; it was reached from
        // a menu and from a long press, and both were things to be discovered.
        //
        // A constant rather than a `@State` binding, because nothing turns it
        // off: there is no Done, no *Reorder Points* entry, and no state to
        // keep. See ``TrailDraftActionsMenu``, which lost that entry, its Done
        // control and the context menu it carried, all to this one line.
        .environment(\.editMode, .constant(.active))
        // **The camera goes to the drawing that is already there.** A draft
        // outlives the screen it is drawn on — it is on disk between launches —
        // so a hiker who backs out, looks at another trail and comes back would
        // otherwise find their points somewhere off the edge of a map showing
        // wherever they had panned to, with nothing on screen to say the
        // drawing still exists.
        //
        // `onAppear` rather than a token raised by
        // ``TrailDraftController/setEditing(_:)``, and the ordering is what
        // makes it safe: `MapSheet` drives `setEditing` from its own
        // `onChange(of:initial:)` on the navigation path, which runs while this
        // screen is being built — so the restore from disk has already happened
        // by the time this fires, and there is a line here to frame.
        .onAppear(perform: frameTheDrawing)
        // On the screen's root, and that is the point of it rather than a
        // placement: a `List` is lazy, so this pair on a `Section` of its own
        // would run when that section scrolled out of view — and a hiker
        // scrolling down to their stops is not a hiker who left. See
        // ``TrailStopSearchRun``.
        .onDisappear {
            search.end()
            completer.clear()
        }
        // The map asks and this screen presents: a callout's *Edit* and the
        // *Mark a Place* that follows a tap both land on the controller, which
        // is the one thing the map and this screen can both see. See
        // ``TrailDraftController/placeEditorRequest``.
        .onChange(of: maker.placeEditorRequest) { _, request in
            guard let request else { return }
            editPlace(request.placeID)
        }
        .navigationTitle("New Trail")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel, action: cancel)
                    .accessibilityIdentifier("trail-draft-cancel")
            }
            ToolbarItem(placement: .primaryAction) {
                TrailDraftActionsMenu(maker: maker) {
                    isConfirmingClear = true
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: startNaming)
                    .disabled(!draft.canBeSaved)
                    .accessibilityIdentifier("trail-draft-save")
            }
        }
        // Inside this screen, which is itself inside the sheet's contents —
        // the rule the repository instructions state under *Present modals
        // from inside the sheet's contents*, and which ``RecordingView``'s own
        // alerts already follow.
        .confirmationDialog(
            "Discard this trail?",
            isPresented: $isConfirmingCancel,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) {
                maker.discard()
                onCancel()
            }
            Button("Keep Drawing", role: .cancel) { /* stays */ }
        } message: {
            Text("The points you've put down will be deleted.")
        }
        // The one edit that asks. Inside this screen for the same reason the
        // dialog above is — see ``TrailDraftActionsMenu`` for why *Clear* is
        // the only one of the seven that gets a question.
        .confirmationDialog(
            "Clear this trail?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive, action: maker.clearDrawing)
            Button("Keep Drawing", role: .cancel) { /* stays */ }
        } message: {
            Text("The points will be removed. You can undo this.")
        }
        .alert(
            "Name Your Trail",
            isPresented: showingNamePrompt,
            // The date comes through the presentation rather than off the
            // state above, because dismissing an alert clears its `isPresented`
            // binding *before* the button's action runs — so a Save that read
            // `namingStartedAt` would find it already `nil`.
            presenting: namingStartedAt
        ) { madeOn in
            TrailDraftNameField(
                name: name,
                placeholder: HikeTitle.drawn(name: nil, madeOn: madeOn)
            )
            // A turn later, deliberately. Everything the save leads to is
            // itself a presentation — a push onto the sheet's stack, or the
            // refusal alert below — and asking for one while the alert that
            // asked the question is still dismissing is how the second one
            // gets dropped. ``RecordingControls``'s Stop alert saves from a
            // `Task` too, for the reason its own work is asynchronous.
            Button("Save") { Task { save(madeOn: madeOn) } }
            Button("Cancel", role: .cancel) { /* the drawing stays */ }
        } message: { _ in
            Text("Give this trail a name, or leave it blank to keep the default.")
        }
        .alert(isPresented: showingRefusal, error: refusal) {
            Button("OK", role: .cancel) { /* dismisses */ }
        }
        // Inside this screen, like the two dialogs and the alert above, and
        // for the reason ``TrailPlaceEditor``'s own header gives: it cannot be
        // a push, because a push would take the canvas down under it.
        .sheet(isPresented: $isEditingPlace, onDismiss: commitPlaceEdit) {
            TrailPlaceEditor(maker: maker, edit: placeEdit) {
                isEditingPlace = false
            }
        }
        // Inside this screen for the reason the place editor is, and it cannot
        // be a push for the same one: a push would take the canvas down under
        // it, and the camera this sheet moves is the one behind it. See
        // ``TrailPlaceEditor``'s header.
        .sheet(isPresented: $isSearchingStop, onDismiss: search.end) {
            TrailStopSearchSheet(
                completer: completer,
                run: search,
                locationManager: locationManager,
                onPick: place(_:),
                onClose: { isSearchingStop = false }
            )
        }
    }

    /// The route: where it starts, what it passes through, where it ends, and
    /// the row that adds another.
    ///
    /// The header carries the running length and the climb, and it is its own
    /// `View` for the second of those — see ``TrailDraftLineHeader``.
    ///
    /// **``TrailAddStopRow`` is outside the `ForEach` and always present**,
    /// including over an empty draft, where it is the only way to start a route
    /// that is not a tap on the map. That is the Apple Maps arrangement and it
    /// is the reason this reads as a route being built: the way to add to it
    /// does not come and go with what is already there.
    @ViewBuilder private var routeSection: some View {
        Section {
            // The rows are handed the draft rather than values read off it, and
            // the footer and the retry row are their own views for the same
            // reason: every leg that lands rewrites `legs`, and reading it here
            // would rebuild this whole screen once per answer. See
            // ``TrailStopRowView``.
            ForEach(Array(draft.waypoints.enumerated()), id: \.element.id) { index, waypoint in
                TrailStopRowView(draft: draft, index: index) {
                    searchForStop(.existing(
                        id: waypoint.id,
                        role: draft.role(ofWaypointAt: index)
                    ))
                }
            }
            // The two gestures a list already has a meaning for, and both
            // of them go through the controller — the drawing has to be
            // written down and the legs either side of what moved have to
            // be asked about again.
            .onMove { offsets, destination in
                HapticMoment.rowMoved.play()
                maker.reorderWaypoints(fromOffsets: offsets, toOffset: destination)
            }
            .onDelete { offsets in
                maker.removeWaypoints(atOffsets: offsets)
            }
            TrailAddStopRow(draft: draft) { searchForStop(.newStop) }
            TrailDraftRetryRow(maker: maker)
        } header: {
            TrailDraftLineHeader(draft: draft, elevation: maker.elevation)
        } footer: {
            TrailDraftLineFooter(draft: draft)
        }
    }

    private var showingRefusal: Binding<Bool> {
        Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })
    }

    private var showingNamePrompt: Binding<Bool> {
        Binding(
            get: { namingStartedAt != nil },
            set: { if !$0 { namingStartedAt = nil } }
        )
    }

    /// How close the camera is brought to a place the hiker picked.
    ///
    /// Wide enough to show the ground around it rather than the building on it,
    /// because what a hiker does next is decide where the line goes from there.
    /// The same kind of number ``MapController/showPhotoSpot(_:)`` holds, and a
    /// different one, because the two answer different questions.
    private static let pickedStopSpanMeters: CLLocationDistance = 1000

    /// Takes the camera to whatever is already drawn, once per opening.
    ///
    /// The **waypoints** rather than ``TrailDraft/routeCoordinates``, and the
    /// difference is not only cost: a draft has just been restored when this
    /// runs, so its legs are the straight lines they are rebuilt as and the
    /// resolved shapes are still being asked for. Framing the points frames
    /// what is on screen, and a leg that snaps a moment later bends inside a
    /// frame that already holds both of its ends.
    private func frameTheDrawing() {
        guard !hasFramedTheDrawing else { return }
        hasFramedTheDrawing = true
        mapController.showDrawnLine(draft.coordinates)
    }

    /// Opens the search sheet on a row.
    private func searchForStop(_ target: TrailStopSearchTarget) {
        search.begin(target)
        isSearchingStop = true
    }

    /// Puts the place the sheet found into the row it was opened from, and
    /// takes the camera there.
    ///
    /// **The camera move is what the *Find a Place* field used to be for**, and
    /// keeping it is the whole reason that field could be removed rather than
    /// merely replaced: a hiker who searches for a valley still ends up looking
    /// at it. What has changed is that they arrive with a stop already down,
    /// which they can drag, rename by searching again, or swipe away.
    ///
    /// The target is read off the run rather than captured when the row was
    /// tapped, so a sheet swiped away and reopened on another row cannot
    /// deliver into the first one.
    private func place(_ pick: TrailStopSearchPick) {
        switch search.target {
        case .existing(let id, _):
            maker.placeWaypoint(id, at: pick.clCoordinate, named: pick.name)
        case .newStop:
            maker.appendWaypoint(at: pick.clCoordinate, named: pick.name)
        case nil:
            // The sheet was already on its way out. Nothing is put down for a
            // row nobody is looking at.
            return
        }
        HapticMoment.targetHit.play()
        mapController.show(
            MKCoordinateRegion(
                center: pick.clCoordinate,
                latitudinalMeters: Self.pickedStopSpanMeters,
                longitudinalMeters: Self.pickedStopSpanMeters
            )
        )
        isSearchingStop = false
    }

    /// Opens the editor on a place, or does nothing for one that has gone —
    /// a callout can outlive the place it is about by an undo.
    private func editPlace(_ id: UUID) {
        guard let place = draft.place(id: id) else { return }
        placeEdit.begin(place)
        isEditingPlace = true
    }

    /// Writes what was typed, on the way out.
    ///
    /// On `onDismiss` rather than on the Done button, so a sheet swiped away
    /// keeps the name as surely as one dismissed by the button — see
    /// ``TrailPlaceEditor`` for why there is no third answer.
    private func commitPlaceEdit() {
        guard let edited = placeEdit.edited else { return }
        maker.updatePlace(edited)
        placeEdit.begin(nil)
    }

    /// Cancel throws a drawing away, so it asks first — but only when there is
    /// something to lose. A dialog over an empty draft is a question with one
    /// answer.
    private func cancel() {
        guard !draft.isEmpty else {
            maker.discard()
            onCancel()
            return
        }
        isConfirmingCancel = true
    }

    /// Asks what to call it, with the field blank.
    ///
    /// Blank rather than pre-filled with the default, which is the trap
    /// ``RecordingControls``'s Stop button records: the placeholder is already
    /// showing what a blank field writes, and filling the field with the same
    /// string makes *blank* impossible to choose without deleting it first.
    private func startNaming() {
        name.clear()
        namingStartedAt = .now
    }

    /// Writes the trail as an ordinary hike and hands it to the sheet, which
    /// selects it and opens its screen exactly as a saved recording is.
    ///
    /// The draft is cleared only on the way through ``TrailDraftSaveOutcome/saved(_:)``:
    /// a store that refused leaves the drawing exactly where it was, which is
    /// what makes *save it again* the right next thing to try. The typed name
    /// goes with it, so the alert that comes back is about the save that is
    /// about to happen rather than the one that didn't.
    private func save(madeOn date: Date) {
        switch TrailDraftSave.hike(
            from: draft,
            named: name.text,
            into: modelContext,
            madeOn: date,
            // Whatever the heights were last read for, applied only if they
            // are still about this line — nothing here waits for an answer
            // that has not landed. See ``TrailDraftElevation``.
            heights: maker.elevation.samples
        ) {
        case .saved(let hike):
            // The one tier of ``HapticMoment`` this screen did not already
            // speak. A tap on the map, a point picked up and a row dropped are
            // all *texture* and all already here; this is the outcome the
            // hiker asked for, waited on, and is about to be shown — the same
            // moment a published hike and an imported one each play.
            //
            // Not the walk tier: a drawn trail has not been walked, and those
            // seven patterns are for a phone in a pocket.
            HapticMoment.outcomeSucceeded.play()
            maker.discard()
            name.clear()
            onSaved(hike)
        case .refused(let refused):
            HapticMoment.outcomeFailed.play()
            refusal = refused
        }
    }

}
