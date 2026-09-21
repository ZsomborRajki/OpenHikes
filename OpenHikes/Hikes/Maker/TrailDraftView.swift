//
//  TrailDraftView.swift
//  OpenHikes
//
//  The maker: the sheet's half of drawing a trail.
//
//  The map above is the canvas and this is everything that is not the canvas —
//  what it is called, somewhere to look, what has been put down so far, and
//  the two ways out. It draws no map of its own and never could: the map it is
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

    private var draft: TrailDraft { maker.draft }

    var body: some View {
        List {
            Section {
                TrailDraftNameField(maker: maker)
            } footer: {
                Text("Leave it blank and this trail is named after today.")
            }

            TrailDraftSearchField(completer: completer, mapController: mapController)

            pointsSection
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
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
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
                        distanceMeters: draft.distanceAlongLine(toWaypointAt: index)
                    )
                }
            }
        } header: {
            HStack {
                Text("Points")
                Spacer(minLength: 12)
                Text(Self.length(draft.distanceMeters))
                    .monospacedDigit()
                    .accessibilityIdentifier("trail-draft-length")
            }
        }
    }

    private var showingRefusal: Binding<Bool> {
        Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })
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

    /// Writes the trail as an ordinary hike and hands it to the sheet, which
    /// selects it and opens its screen exactly as a saved recording is.
    ///
    /// The draft is cleared only on the way through ``TrailDraftSaveOutcome/saved(_:)``:
    /// a store that refused leaves the drawing exactly where it was, which is
    /// what makes *save it again* the right next thing to try.
    private func save() {
        switch TrailDraftSave.hike(from: draft, into: modelContext) {
        case .saved(let hike):
            maker.discard()
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
