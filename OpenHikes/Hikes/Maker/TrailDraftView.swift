//
//  TrailDraftView.swift
//  OpenHikes
//
//  The maker: the sheet's half of drawing a trail.
//
//  The map above is the canvas and this is everything that is not the canvas:
//  the travel mode, the route so far, and the two ways out. What the trail is
//  *called* is not among them: it is asked for once, in an alert, at the
//  moment Save is tapped, exactly as a stopped recording is named — see
//  ``RecordingControls``. It draws no map of its own and never could: the map
//  it is about is the one behind the sheet, which is the whole reason this is a
//  pushed screen rather than a modal over the map.
//
//  ## The route is Apple Maps' directions list
//
//  It opens with two empty fields, *start* and *destination*, and a start, its
//  numbered stops and a destination joined by a dotted line once they are
//  filled, with *Add Stop* underneath — see ``TrailStopRowView`` and
//  ``TrailAddStopRow``. Three things follow from that and each is load-bearing
//  rather than styling.
//
//  **Every stop can be moved and deleted at any time, as in Apple Maps.** A
//  press and hold lifts a filled row to drag it, and a trailing swipe deletes
//  it; there is no Edit/Done mode to enter first and no leading delete
//  circles. That is `onMove` on the stops' `ForEach` outside edit mode, which
//  on iOS 27 drags on a press and hold and keeps the swipe. iOS 27's own
//  `reorderable()` was tried first and measured in a standalone prototype: it
//  dropped a stop moved one row up at the *end* of the list and ignored one
//  moved one row down, in a sheet or out of one, where `onMove` placed all
//  three test drags correctly.
//
//  **A row is a field.** Tapping one opens ``TrailStopSearchSheet`` on it, and
//  the place picked there fills that row and takes the camera to it. Every
//  search moves the map; it just leaves a stop where it arrives.
//
//  **The map is the other way in.** A press and hold drops a pin and opens
//  ``TrailPlaceSheet`` — Apple Maps' place card — on it, and a tap opens the
//  card of a stop, one of the trail's places or one of the map's own labels.
//  The card's *Add Stop* is what puts a point down. The places themselves live
//  on the map and on their cards, not in this list.
//
//  Every mutation goes through ``TrailDraftController`` rather than through
//  ``TrailDraft`` directly, because the controller is the one that also writes
//  the draft down — see its header.
//
//  No `@Environment(\.dismiss)` here, and none in the toolbar either. The
//  native back button changes the sheet's navigation path directly; the
//  explicit close and save actions are callbacks the sheet supplies because
//  they also change state beside that path. This is the same arrangement
//  ``RecordingView`` takes for `onSaved` and `onDiscarded`. See
//  ``DismissButton`` for what declaring the environment value here would
//  have cost.
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
    /// The hiker's own position, for the search sheet's *My Location* row.
    /// `nil` for a launch with no location, which withholds that one row.
    var locationManager: LocationManager?
    var onClose: () -> Void
    var onSaved: (Hike) -> Void

    @Environment(\.modelContext)
    private var modelContext

    /// The one refusal a hiker can reach from the Save button — the store said
    /// no. ``TrailDraftRefusal/tooShort`` is unreachable from here because the
    /// button is disabled, and it exists because
    /// ``TrailDraftSave`` is asked by more than a button.
    @State private var refusal: TrailDraftRefusal?
    /// Whether the ✕ is asking what to do with the drawing — see ``close()``.
    @State private var isConfirmingClose = false
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
    /// ``TrailStopSearchRun/target``: the target is what the sheet is *about*
    /// and this is whether it is on screen, and a hiker who swipes it away has
    /// changed the second without changing the first.
    @State private var isSearchingStop = false
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

            // Withheld with the pill it explains — a launch with no place
            // source, which is a preview or a UI-test run.
            if maker.finder.isAvailable {
                TrailPlaceFilterSection(maker: maker)
            }
        }
        // The mode bar sits right under the title, as it does in Apple Maps'
        // directions card. A grouped list's own top margin left a blank row's
        // height above it — a row the medium detent, which is where the map
        // and this list share the screen, cannot spare.
        .contentMargins(.top, Self.topMargin, for: .scrollContent)
        // The sheet's glass shows through, as it does behind the sheet's other
        // lists. A grouped list otherwise paints its own opaque grey over it;
        // the rows keep their own cards either way.
        .scrollContentBackground(.hidden)
        // EXPERIMENT: the container the stops' `reorderable()` hands a drop
        // to. See `TrailStopReordering.swift`.
        .trailStopReorderContainer { moveStops($0, before: $1) }
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
        .navigationTitle("New Trail")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // The system back button stays on the leading edge. It pops this
        // screen immediately and leaves the persisted draft untouched, so it
        // asks no question. The explicit ✕ on the trailing edge is where a
        // hiker can choose to discard instead — see ``close()``.
        .toolbar {
            // Save and close share one glass pill on the trailing edge, the ✕
            // outermost, where Apple Maps puts its own.
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Save", systemImage: "checkmark", action: startNaming)
                    .disabled(!draft.canBeSaved)
                    .accessibilityIdentifier("trail-draft-save")
                Button("Close", systemImage: "xmark", action: close)
                    .accessibilityIdentifier("trail-draft-close")
            }
        }
        // Inside this screen, which is itself inside the sheet's contents —
        // the rule the repository instructions state under *Present modals
        // from inside the sheet's contents*, and which ``RecordingView``'s own
        // alerts already follow.
        .confirmationDialog(
            "Close this trail?",
            isPresented: $isConfirmingClose,
            titleVisibility: .visible
        ) {
            Button("Discard Trail", role: .destructive) {
                maker.discard()
                onClose()
            }
            // The explicit keep choice mirrors Back: the drawing stays on
            // disk and comes back the next time the maker opens.
            Button("Keep for Later", action: onClose)
            Button("Keep Drawing", role: .cancel) { /* stays */ }
        } message: {
            Text("Keep it for later and it will be here the next time you make a trail.")
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
        // Inside this screen, like the dialogs and alerts above, and it cannot
        // be a push: a push would take the canvas down under it, and the camera
        // this sheet moves is the one behind it.
        .sheet(isPresented: $isSearchingStop, onDismiss: search.end) {
            TrailStopSearchSheet(
                completer: completer,
                run: search,
                locationManager: locationManager,
                recents: maker.recents,
                onPick: place(_:),
                onClose: { isSearchingStop = false }
            )
        }
        // What a tap on the map opens — see ``TrailPlaceSheet``.
        .modifier(TrailPlaceSheetPresenter(maker: maker))
    }

    /// The route: where it starts, what it passes through, where it ends, and
    /// the row that adds another.
    ///
    /// The header carries the running length, the time and the climb, and it
    /// is its own `View` for the last of those — see ``TrailDraftLineHeader``.
    @ViewBuilder private var routeSection: some View {
        Section {
            // The rows are handed the draft rather than values read off it, and
            // the footer and the retry row are their own views for the same
            // reason: every leg that lands rewrites `legs`, and reading it here
            // would rebuild this whole screen once per answer. See
            // ``TrailStopRowView``. The same goes for the points themselves —
            // a name landing or a stop being dragged rewrites them — which is
            // why the only thing read here is ``TrailDraft/slots``, which
            // changes when a row comes or goes and at no other time.
            //
            // Three `ForEach`es so that only the stops can be picked up: an
            // open field sits before them or after them and has no place in
            // their order, and the stops' offsets are then the waypoints' own.
            let slots = draft.slots
            let fieldsBefore = Array(slots.prefix { $0.waypointIndex == nil })
            let stops = slots.filter { $0.waypointIndex != nil }
            ForEach(fieldsBefore) { openFieldRow($0, in: slots) }
                .listRowInsets(TrailStopRowView.rowInsets)
                .listRowSeparator(.hidden)
            ForEach(stops) { stopRow($0, in: slots) }
                .trailStopsReorderable()
                .listRowInsets(TrailStopRowView.rowInsets)
                .listRowSeparator(.hidden)
            ForEach(Array(slots.dropFirst(fieldsBefore.count + stops.count))) { openFieldRow($0, in: slots) }
                .listRowInsets(TrailStopRowView.rowInsets)
                .listRowSeparator(.hidden)
            if draft.canBeSaved {
                TrailAddStopRow { searchForStop(.newStop) }
            }
            TrailDraftRetryRow(maker: maker)
        } header: {
            TrailDraftLineHeader(draft: draft, elevation: maker.elevation)
        } footer: {
            TrailDraftLineFooter(draft: draft)
        }
    }

    /// A start or destination field still waiting for a place.
    private func openFieldRow(_ slot: TrailStopSlot, in slots: [TrailStopSlot]) -> some View {
        TrailStopRowView(draft: draft, position: slots.firstIndex(of: slot) ?? 0) {
            searchForStop(target(for: slot))
        }
    }

    /// A filled stop, with the two gestures it has at all times: the press and
    /// hold that drags it and a trailing swipe that deletes it.
    ///
    /// One view whatever the slot, with no `if` around it. Every slot here is a
    /// stop, so the optional identity is only ever there to unwrap — and a
    /// `ForEach` of conditional rows is where iOS 27's list reordering was
    /// seen to move a row on screen and never report the move.
    private func stopRow(_ slot: TrailStopSlot, in slots: [TrailStopSlot]) -> some View {
        let id = slot.stopID
        return TrailStopRowView(
            draft: draft,
            position: slots.firstIndex(of: slot) ?? 0,
            onStep: id.map { id in { adjustWaypoint(id, direction: $0) } },
            onSearch: { searchForStop(target(for: slot)) }
        )
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) {
                if let id { maker.removeStop(id: id) }
            }
        }
    }

    /// A drop from the stops' drag: each dragged row's stop, moved in front of
    /// the stop `target` names, or to the end for `nil`.
    private func moveStops(_ sources: [String], before target: String?) {
        let stop = { (id: String) in draft.slots.first { $0.id == id }?.stopID }
        let before = target.flatMap(stop)
        for source in sources.compactMap(stop) {
            reorderWaypoint(source, before: before)
        }
    }

    /// What a row's search fills: the stop it already holds, or its open field.
    private func target(for slot: TrailStopSlot) -> TrailStopSearchTarget {
        switch slot {
        case .open(let role): .open(role)
        case let .point(index, id): .existing(id: id, role: draft.role(ofWaypointAt: index))
        }
    }

    /// VoiceOver's *Move Up* and *Move Down* step through the same ordering
    /// one row at a time: decrement is earlier, increment is later.
    private func adjustWaypoint(_ sourceID: UUID, direction: AccessibilityAdjustmentDirection) {
        let waypoints = draft.waypoints
        guard let sourceIndex = waypoints.firstIndex(where: { $0.id == sourceID }) else { return }

        switch direction {
        case .decrement:
            guard sourceIndex > waypoints.startIndex else { return }
            reorderWaypoint(sourceID, before: waypoints[sourceIndex - 1].id)
        case .increment:
            guard sourceIndex < waypoints.index(before: waypoints.endIndex) else { return }
            let afterNextIndex = sourceIndex + 2
            let targetID = waypoints.indices.contains(afterNextIndex) ? waypoints[afterNextIndex].id : nil
            reorderWaypoint(sourceID, before: targetID)
        @unknown default:
            return
        }
    }

    /// Moves a stop immediately before `targetID`, or to the end for `nil`.
    /// Where a drag's drop and a VoiceOver step both land.
    private func reorderWaypoint(_ sourceID: UUID, before targetID: UUID?) {
        guard
            let sourceIndex = draft.waypoints.firstIndex(where: { $0.id == sourceID })
        else { return }

        let destinationIndex: Int
        if let targetID {
            guard let index = draft.waypoints.firstIndex(where: { $0.id == targetID }) else {
                return
            }
            destinationIndex = index
        } else {
            destinationIndex = draft.waypoints.endIndex
        }

        // A move offset names the insertion point before the source is
        // removed. Both of these shapes therefore leave the row in place.
        guard sourceIndex != destinationIndex, sourceIndex + 1 != destinationIndex else {
            return
        }

        HapticMoment.rowMoved.play()
        maker.reorderWaypoints(
            fromOffsets: IndexSet(integer: sourceIndex),
            toOffset: destinationIndex
        )
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

    /// Between the title and the mode bar — see the `contentMargins` in the
    /// body.
    private static let topMargin: CGFloat = 4

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

    /// Opens the search sheet on a row. The place sheet goes first: two
    /// sheets from one screen is a presentation SwiftUI refuses.
    private func searchForStop(_ target: TrailStopSearchTarget) {
        maker.select(nil)
        search.begin(target, prefill: prefill(for: target))
        isSearchingStop = true
    }

    /// What the search field opens holding: the name or address of the stop
    /// already in the row, and nothing for a row that is waiting to be filled
    /// or a stop nothing has named — "Stop 2" is not a place to search for.
    private func prefill(for target: TrailStopSearchTarget) -> String {
        guard case .existing(let id, _) = target,
              let index = draft.waypoints.firstIndex(where: { $0.id == id }) else { return "" }
        return draft.name(ofWaypointAt: index)
    }

    /// Puts the place the sheet found into the row it was opened from, and
    /// takes the camera there — or, when it put down an end of a line, to the
    /// whole line.
    ///
    /// A hiker who searches for a valley ends up looking at it, with a stop
    /// already down they can drag, change by searching again, or delete. A
    /// hiker who picks the destination is looking at the route it drew, which
    /// is the thing they picked it to see; see
    /// ``TrailStopSearchTarget/landsOnAnEnd``.
    ///
    /// The target is read off the run rather than captured when the row was
    /// tapped, so a sheet swiped away and reopened on another row cannot
    /// deliver into the first one.
    private func place(_ pick: TrailStopSearchPick) {
        let target = search.target
        switch target {
        case .existing(let id, _):
            maker.placeWaypoint(id, at: pick.clCoordinate, named: pick.name)
        case .newStop:
            maker.appendWaypoint(at: pick.clCoordinate, named: pick.name)
        case .open(let role):
            maker.fill(role, at: pick.clCoordinate, named: pick.name)
        case nil:
            // The sheet was already on its way out. Nothing is put down for a
            // row nobody is looking at.
            return
        }
        // Remembered only once it has been put down — a pick delivered to a
        // sheet on its way out is not a place the hiker used. A *My Location*
        // pick names nothing and is not kept; see ``TrailStopRecents``.
        maker.recents.record(pick)
        HapticMoment.targetHit.play()
        if target?.landsOnAnEnd == true, draft.coordinates.count > 1 {
            // The waypoints rather than the resolved shape, for the reason
            // `frameTheDrawing()` gives: the legs are still being routed, and
            // they bend inside a frame that already holds both of their ends.
            mapController.showDrawnLine(draft.coordinates)
        } else {
            mapController.show(
                MKCoordinateRegion(
                    center: pick.clCoordinate,
                    latitudinalMeters: Self.pickedStopSpanMeters,
                    longitudinalMeters: Self.pickedStopSpanMeters
                )
            )
        }
        isSearchingStop = false
    }

    /// The ✕: closes the maker, asking first what to do with the drawing —
    /// but only when there is one. A dialog over an empty draft is a question
    /// with one answer.
    private func close() {
        guard !draft.isEmpty else {
            maker.discard()
            onClose()
            return
        }
        isConfirmingClose = true
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
