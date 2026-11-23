//
//  WalkEndQuestion.swift
//  OpenHikes
//
//  The one question an End asks, whichever End was tapped, and the alert that
//  says so when the store would not let the walk go.
//
//  End is in two places, as a recording's Stop is — see
//  ``RecordingStopQuestion``: the bar of the walked trail's own screen, and
//  the capsule on the map that stands in for that bar on every other screen
//  — see ``MapActivityCapsule``. So the question is this object's, on the
//  model, and it is put up with what the map's controls open — see
//  ``MapControlModals``.
//
//  An alert rather than the dialog it was while End was a button in the
//  screen's scroll view: the capsule is on the map, and a dialog presented
//  from the map sheet's contents has nothing on screen to stand against. The
//  refusal follows it as an alert too, which an alert's button can raise.
//
//  A walk that was kept goes out as an ``ActivityEnding``, so its summary
//  opens wherever the End was tapped.
//

import Foundation
import Observation
import OpenHikesData
import OpenHikesShared
import os
import SwiftUI

@MainActor
@Observable
final class WalkEndQuestion {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    private let session: TrailWalkSession
    private let endings: EventFeed<ActivityEnding>

    /// Whether the question is up.
    var isAsking = false
    /// Whether the store refused the last End. The walk is still under way
    /// and its controls still on screen — this is what says so, rather than
    /// letting a refusal read as a walk too short to keep.
    var isRefused = false
    /// The phase the capsule's Pause or Resume asked for and the store
    /// refused — see ``TrailWalkSession/togglePhase(from:)``. The bar's
    /// button says its own; the capsule has nowhere to put an alert, so it
    /// says it here.
    var refusedPhase: TrailWalkPhase?
    /// The walk the question was asked about, by its trail and its start.
    /// The capsule can ask on another hike's screen, and while the alert is
    /// up a matched fix can end that walk and start one along the trail on
    /// screen. *End* given for the first must not end the second, which would
    /// be dropped as too short.
    @ObservationIgnored private var askedWalk: AskedWalk?

    private struct AskedWalk: Equatable {
        let hikeID: UUID
        let startedAt: Date
    }

    init(session: TrailWalkSession, endings: EventFeed<ActivityEnding>) {
        self.session = session
        self.endings = endings
    }

    /// What End does: asks first.
    func ask() {
        guard session.phase != nil else { return }
        askedWalk = currentWalk
        isAsking = true
    }

    /// The capsule's Pause or Resume.
    func togglePhase() {
        guard let phase = session.phase else { return }
        refusedPhase = session.togglePhase(from: phase)
    }

    /// The hiker said yes: ends the walk, kept as a record when it covered
    /// enough.
    func end() {
        guard askedWalk != nil, currentWalk == askedWalk else {
            // What it was about has ended without it.
            Self.logger.notice("End's answer came after its walk ended; dropped")
            return
        }
        let end = session.end()
        // From the outcome rather than from the phase going absent: kept,
        // dropped and refused are three different pieces of news and the
        // phase carries none of them. See ``WalkHaptics``.
        end.hapticMoment.play()
        switch end {
        case let .kept(walk): endings.send(.walkKept(hikeID: walk.hikeID, walkID: walk.id))
        case .discarded: break
        case .refused: isRefused = true
        }
    }

    private static let logger = Logger(subsystem: "OpenHikes", category: "TrailWalk")

    /// The walk under way, as ``askedWalk`` keeps one.
    private var currentWalk: AskedWalk? {
        session.record.map { AskedWalk(hikeID: $0.hikeID, startedAt: $0.startedAt) }
    }
}

extension View {
    /// Presents the End question, and the refusal that can follow it, from
    /// `presenter` — the map sheet's contents, or a place card over them.
    func walkEndAlerts(
        _ modals: MapControlModals,
        from presenter: MapControlModals.Presenter,
        question: WalkEndQuestion
    ) -> some View {
        modifier(WalkEndAlerts(modals: modals, presenter: presenter, question: question))
    }
}

/// A modifier so that its own body, and nothing above it, reads the question
/// and builds the bindings that read it again — see ``LocationAccessPrompt``.
private struct WalkEndAlerts: ViewModifier {
    let modals: MapControlModals
    let presenter: MapControlModals.Presenter
    @Bindable var question: WalkEndQuestion

    func body(content: Content) -> some View {
        content
            .alert("End this hike?", isPresented: modals.binding($question.isAsking, for: presenter)) {
                Button("End and Save Hike", role: .destructive) { question.end() }
                Button("Cancel", role: .cancel) { /* no-op */ }
            } message: {
                Text("What it covered so far is kept as a record. A hike under 100 m is not.")
            }
            .alert("Could not end this hike", isPresented: modals.binding($question.isRefused, for: presenter)) {
                Button("OK", role: .cancel) { /* no-op */ }
            } message: {
                Text("Its record could not be saved, so the hike is still under way. Try ending it again.")
            }
            .walkPhaseRefusalAlert(refusedPhase)
    }

    /// The capsule's refused Pause or Resume, while `presenter` is the one to
    /// put it up — as ``MapControlModals/binding(_:for:)`` gates a flag.
    private var refusedPhase: Binding<TrailWalkPhase?> {
        Binding(
            get: { modals.isPresenter(presenter) ? question.refusedPhase : nil },
            set: { question.refusedPhase = $0 }
        )
    }
}
