//
//  RecordingStopAlerts.swift
//  OpenHikes
//
//  The Stop question, put up: the name alert, and the discard alert that
//  follows it — see ``RecordingStopQuestion``.
//
//  Presented with what the map's controls open — see ``MapControlModals`` —
//  because one of the two Stops is a map control: the capsule standing in
//  for the recording screen's bar. A place card can be up over the map sheet
//  when it is tapped, and an alert put up from under the card takes the card
//  down to come up.
//
//  The discard question is an alert, never a dialog, even where it is asked
//  on its own. It also follows the name alert's *Discard Recording*, and a
//  `confirmationDialog` raised from an alert's button is never presented:
//  measured on iOS 27.2, the button's action runs while the alert is still on
//  its way down, the dialog's flag reads true in the pass after it, and
//  nothing comes up. An alert raised the same way does follow the first.
//

import SwiftUI

extension View {
    /// Presents the Stop question from `presenter` — the map sheet's
    /// contents, or a place card over them.
    func recordingStopAlerts(
        _ modals: MapControlModals,
        from presenter: MapControlModals.Presenter,
        question: RecordingStopQuestion
    ) -> some View {
        modifier(RecordingStopAlerts(modals: modals, presenter: presenter, question: question))
    }
}

/// A modifier so that its own body, and nothing above it, reads the question
/// and builds the bindings that read it again — see ``LocationAccessPrompt``.
private struct RecordingStopAlerts: ViewModifier {
    let modals: MapControlModals
    let presenter: MapControlModals.Presenter
    @Bindable var question: RecordingStopQuestion

    func body(content: Content) -> some View {
        content
            .alert("Name Your Hike", isPresented: modals.binding($question.isAskingName, for: presenter)) {
                // The offered name is the field's text, and under it the
                // field's placeholder: a hiker who clears the field and saves
                // is still shown what the hike will be called. Either way it
                // is the name the save writes rather than one asked for again
                // when the save comes. By then the town may have answered,
                // and the walk gone on under the alert.
                TextField(
                    question.offeredTitle ?? String(localized: "Hike name"),
                    text: $question.nameDraft
                )
                Button("Save") {
                    Task { await question.save() }
                }
                // The other way a recording ends, beside the one that keeps
                // it, so that throwing a walk away does not take a pause
                // first. It still asks.
                Button("Discard Recording", role: .destructive) {
                    question.discardInstead()
                }
                Button("Keep Recording", role: .cancel) { /* no-op */ }
            } message: {
                Text("Save the hike under this name, or type another.")
            }
            .alert(
                "Discard this recording?",
                isPresented: modals.binding($question.isConfirmingDiscard, for: presenter)
            ) {
                Button("Discard Recording", role: .destructive) {
                    Task { await question.discard() }
                }
                Button("Cancel", role: .cancel) { /* no-op */ }
            } message: {
                Text("The recorded track cannot be recovered after it is discarded.")
            }
            // The offered name opens selected, so the first key typed
            // replaces it and a tap in the field keeps it to be edited. Asked
            // of the field itself, because an alert does not hear a
            // `selection:` binding — see ``AlertTextSelection``. Only by the
            // presenter that put the alert up.
            .selectsAlertText(
                question.offeredTitle,
                while: question.isAskingName && modals.isPresenter(presenter)
            )
    }
}
