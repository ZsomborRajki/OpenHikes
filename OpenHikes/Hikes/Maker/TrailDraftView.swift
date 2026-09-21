//
//  TrailDraftView.swift
//  OpenHikes
//
//  The maker: the sheet's half of drawing a trail.
//
//  The map above is the canvas and this is everything that is not the canvas —
//  somewhere to look, what has been put down so far, and the two ways out.
//  What the trail is *called* is not among them: it is asked for once, in an
//  alert, at the moment Save is tapped, exactly as a stopped recording is
//  named — see ``RecordingControls``. A field standing open beside the points
//  asked the question for the whole of the drawing and had to be answered
//  before it could be scrolled past, when the answer is only wanted at the
//  end. It draws no map of its own and never could: the map it is
//  about is the one behind the sheet, which is the whole reason this is a
//  pushed screen rather than a modal over the map.
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

import OpenHikesShared
import SwiftData
import SwiftUI

struct TrailDraftView: View {
    let maker: TrailDraftController
    /// Borrowed for the *Find a Place* field. The map feeds it a settled
    /// region, so suggestions are answered near what the hiker is looking at.
    let completer: SearchCompleter
    /// How the field above moves the camera. It places nothing.
    let mapController: MapController
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
    /// Whether the points are being rearranged.
    ///
    /// A `List` reorders only while this is `.active`, and a long press on a
    /// row does nothing without it — both found the hard way on the hikes
    /// list, and both recorded there. The way out is in the toolbar rather
    /// than in the list, because in edit mode a row's tap belongs to the list.
    @State private var editMode: EditMode = .inactive
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
    /// The *Find a Place* lookup, held here rather than in the field that
    /// starts it — see ``TrailDraftSearchRun``.
    @State private var search = TrailDraftSearchRun()

    private var draft: TrailDraft { maker.draft }

    var body: some View {
        List {
            TrailDraftSearchField(
                completer: completer,
                mapController: mapController,
                search: search
            )

            // Withheld entirely on a launch that has no trail graph to ask —
            // a preview, or UI automation started without a fixture. A switch
            // that cannot change the line is worse than no switch.
            if maker.canSnapToPaths {
                TrailDraftSnapToggle(maker: maker)
            }

            pointsSection
        }
        // Reordering is the operation the list earns its place with, and a
        // `List` offers it only while this is `.active` — a long press and a
        // drag do nothing without it. See ``TrailDraftActionsMenu``.
        .environment(\.editMode, $editMode)
        // On the screen's root, and that is the point of it rather than a
        // placement: a `List` is lazy, so the same pair on the search field's
        // own `Section` runs when that section scrolls out of view — and a
        // hiker scrolling down to their points is not a hiker who left. See
        // ``TrailDraftSearchRun``.
        .onDisappear {
            search.cancel()
            completer.clear()
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
                TrailDraftActionsMenu(maker: maker, editMode: $editMode) {
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
    }

    /// The points, in the order they were put down, with how far along each
    /// one sits.
    ///
    /// The header carries the running length, which is the figure a hiker is
    /// actually watching while they draw — climb joins it once there are
    /// heights to ask for.
    @ViewBuilder private var pointsSection: some View {
        Section {
            if draft.waypoints.isEmpty {
                Text("Tap the map to put down your first point.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("trail-draft-empty")
            } else {
                ForEach(Array(draft.waypoints.enumerated()), id: \.element.id) { index, _ in
                    TrailDraftWaypointRow(
                        number: index + 1,
                        distanceMeters: draft.distanceAlongLine(toWaypointAt: index),
                        // The leg *into* this point, which is why the first
                        // row never has one: nothing arrives at it.
                        legNotice: draft.leg(arrivingAtWaypointAt: index)?.snap.notice
                    )
                    .trailDraftReorderMenu($editMode)
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
                retryRow
            }
        } header: {
            HStack {
                Text("Points")
                Spacer(minLength: 12)
                Text(Self.length(draft.distanceMeters))
                    .monospacedDigit()
                    .accessibilityIdentifier("trail-draft-length")
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                // One line for the whole line, saying the worst thing any leg
                // has to report — see ``TrailDraft/notice``. The per-leg
                // sentence is on the row it belongs to; this is what a hiker
                // who has not scrolled sees.
                if let notice = draft.notice {
                    TrailDraftNoticeLabel(notice: notice)
                }
                // The two gestures on the map that nothing on screen could
                // otherwise announce. Both are discoverable only by being
                // told: a leg looks like a drawing rather than a control, and
                // a pin that answers a press but not a tap advertises
                // nothing. Withheld until there is a line to do either to.
                if !draft.legs.isEmpty {
                    Text(
                        """
                        Tap a leg to add a point in the middle. \
                        Press and hold a point to move it.
                        """
                    )
                }
            }
        }
    }

    /// *Try Again*, offered only when Overpass refused something.
    ///
    /// Not for a leg with nothing mapped under it and not for one the hiker
    /// straightened themselves: asking again about either would spend a
    /// request to be told the same thing. See ``TrailLegSnap/isRetryable``.
    @ViewBuilder private var retryRow: some View {
        if draft.hasRetryableLegs {
            Button("Try Again", systemImage: "arrow.clockwise", action: maker.retryRefusedLegs)
                .accessibilityIdentifier("trail-draft-retry")
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
            madeOn: date
        ) {
        case .saved(let hike):
            maker.discard()
            name.clear()
            onSaved(hike)
        case .refused(let refused):
            refusal = refused
        }
    }

    private static func length(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }
}
