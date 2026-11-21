//
//  RouteTrimView.swift
//  OpenHikes
//
//  *Edit Route* on a hike that was recorded or imported, pushed from the
//  closing actions of its screen: drag either end of the line inward, take
//  off a stretch that was not walked in one tap, answer for the stretches
//  trail matching left a question on, change a stretch or the whole line,
//  and put the original back.
//
//  ## A walked line is never changed without saying so
//
//  A drawn trail is edited by its stops, in the maker. A line somebody walked
//  has none, and re-routing it replaces ground the hiker covered with a
//  guess, which was the owner's reason for giving it no *Edit Route* at all.
//  Three things answer that. A trim guesses nothing: every point it leaves
//  is the point that was saved — see ``RouteTrim``. A stretch to check is no
//  guess either: each of its answers is a line the recording itself came
//  with — see ``RouteAssembly``. And a stretch drawn along another path,
//  which is one, says so: it is marked inferred and carries no times, only
//  the hiker's own hand makes it, and it is taken back with *Undo* — see
//  ``RouteStep``. The line all of it was done to is kept beside the hike, so
//  *Revert to Original* undoes the whole of it on any of the hiker's devices.
//
//  ## Pushed, not presented
//
//  For the reason *Route Style* is: the sheet keeps its detent and the line
//  being cut stays on the map above it, with a handle on each end — see
//  `MapRouteTrim.swift`. The chart here and the handles there move the same
//  two cuts.
//
//  ## What this body reads
//
//  The hike's line, which changes when an edit lands, and nothing that moves
//  with a drag: the cuts are read by the chart, the figures, the offers and
//  the Save button, each a view of its own. The session is kept by
//  ``SheetPresentation``, so a turn of the phone keeps the cuts.
//

import CoreLocation
import OpenHikesData
import OpenHikesShared
import SwiftData
import SwiftUI

struct RouteTrimView: View {
    let hike: Hike
    /// The hike's line, shared with its own screen — see ``ShownLine``.
    let line: ShownLine
    let session: RouteTrimSession
    /// Where the map reads the cuts from.
    let preview: RouteTrimPreview
    /// What an edit needs to replace the hike's workout, or `nil` on a launch
    /// with no Health.
    var health: RouteEditWorkout.Health?
    /// Who draws a stretch along another path, and who knows where the
    /// junctions are — see ``RouteReroute``.
    var routing: RouteReroute.Services?
    /// Brings the whole line into view above the sheet, the first time this
    /// screen appears.
    var onFirstAppear: () -> Void = { /* no-op default */ }
    /// Brings one stretch into view above the sheet.
    var onShowStretch: ([CLLocationCoordinate2D]) -> Void = { _ in /* no-op default */ }
    /// Leaves the screen, once a save or a revert has landed.
    var onDone: () -> Void = { /* no-op default */ }

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                RouteTrimChart(session: session, tint: hike.tintOpaque)
                RouteTrimFigures(session: session, hikeDistanceMeters: hike.distanceMeters)
                RouteTrimOffers(session: session)
                RouteStepsCard(session: session)
                RouteChecksCard(session: session) { id in
                    onShowStretch(session.line?.coordinates(ofCheck: id) ?? [])
                }
                RouteLooksGoodButton(session: session, confirm: confirm)
                if hike.hasOriginalRoute {
                    PlaceCardList {
                        RouteRevertButton(session: session, revert: revert)
                    }
                }
                Text(
                    """
                    Drag either end of the route to cut it off, or hold the line on the map and pull it onto \
                    another path. The original is kept.
                    """
                )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .softScrollEdgeEffect(for: .top)
        // What the side panel stands as tall as — see ``SidePanelFit``.
        .fitsSidePanel()
        .navigationTitle("Edit Route")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                RouteTrimSaveButton(session: session, save: save)
            }
        }
        // Keyed on the line itself and on what the hike remembers of its
        // edits, so an edit that lands while this screen is up — here, or on
        // the hiker's other device — starts over on it.
        .task(id: RouteTrimLineKey(line, edit: hike.routeEditData)) {
            let drawn = line.current?.route ?? []
            guard drawn.count > 1 else { return }
            session.routing = routing
            await session.load(RouteEditSources.reading(hike, drawn: drawn, in: modelContext.container))
        }
        .onAppear {
            session.show(on: preview)
            onFirstAppear()
        }
        .routeEditRefusal(of: session)
    }

    private var destination: RouteTrimSession.Destination {
        RouteTrimSession.Destination(
            hike: hike,
            context: modelContext,
            health: health,
            settledLine: { [line] in line.isSettled ? line.current?.route ?? [] : [] }
        )
    }

    private func save() {
        let target = destination
        Task {
            if await session.save(to: target) { onDone() }
        }
    }

    private func revert() {
        if session.revert(in: destination) { onDone() }
    }

    private func confirm() {
        let target = destination
        Task {
            if await session.confirmChecks(in: target) { onDone() }
        }
    }
}

/// What ``RouteTrimView``'s loading is keyed on: the line ``ShownLine`` has
/// landed, compared as ``WalkSummaryRouteKey`` compares it and for the same
/// reason.
nonisolated struct RouteTrimLineKey: Equatable, Sendable {
    let route: [RouteCoordinate]
    /// ``Hike/routeEditData``, which names the whole line the hike's is cut
    /// from and the answers it stands under.
    let edit: Data?

    @MainActor
    init(_ line: ShownLine, edit: Data?) {
        route = line.current?.route ?? []
        self.edit = edit
    }
}

/// *Save*, which is there to press once a cut or an answer has moved.
struct RouteTrimSaveButton: View {
    let session: RouteTrimSession
    let save: () -> Void

    var body: some View {
        RoleButton(.confirm, title: "Save", action: save)
            .disabled(!session.hasChanges || session.isSaving || session.isRouting || session.isMakingStep)
            .accessibilityIdentifier("route-trim-save")
    }
}

/// *Revert to Original*, and the question it asks first. Its own view for
/// the reason ``HikeRouteEditButton`` is one: the dialog's state belongs
/// here and nowhere above.
struct RouteRevertButton: View {
    let session: RouteTrimSession
    let revert: () -> Void

    @State private var isConfirming = false

    var body: some View {
        Button {
            isConfirming = true
        } label: {
            PlaceCardActionLabel(
                title: String(localized: "Revert to Original"),
                systemImage: "arrow.uturn.backward"
            )
        }
        .buttonStyle(.plain)
        .disabled(session.isSaving)
        .accessibilityIdentifier("route-trim-revert")
        .confirmationDialog(
            "Revert to the original route?",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("Revert", role: .destructive, action: revert)
            Button("Cancel", role: .cancel) { /* the edit stays */ }
        } message: {
            Text("Everything that was cut off the route comes back.")
        }
    }
}

extension View {
    /// The alert for a save or a revert that did not land. A modifier of its
    /// own so the binding it makes, and the read of the refusal, belong to it
    /// and not to the screen.
    func routeEditRefusal(of session: RouteTrimSession) -> some View {
        modifier(RouteEditRefusalAlert(session: session))
    }
}

private struct RouteEditRefusalAlert: ViewModifier {
    let session: RouteTrimSession

    func body(content: Content) -> some View {
        content.alert(
            session.refusal?.errorDescription ?? "",
            isPresented: Binding(
                get: { session.refusal != nil },
                set: { if !$0 { session.refusal = nil } }
            ),
            presenting: session.refusal
        ) { _ in
            Button("OK", role: .cancel) { /* the alert closes itself */ }
        } message: { refusal in
            Text(refusal.recoverySuggestion ?? "")
        }
    }
}
