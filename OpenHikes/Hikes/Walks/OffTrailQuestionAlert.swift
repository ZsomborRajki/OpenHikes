//
//  OffTrailQuestionAlert.swift
//  OpenHikes
//
//  The alert that asks a hiker who has left the trail they are walking
//  whether to go on following it or to record instead — see
//  ``OffTrailQuestion`` for when it is asked.
//
//  Titled as the banner beside it is, so the two read as the one event they
//  are. *Keep Following* is the answer that changes nothing, and so the
//  cancel: the walk goes on, the trail stays selected, and this departure is
//  not asked about again. *Record Instead* is ``RecordingEntry/recordInsteadOfWalk()``.
//
//  Only an answer puts the question away. It is raised with the phone in a
//  pocket as often as in a hand, and has to be there when the app is next
//  looked at: measured on a `--ui-testing` launch, one raised under the
//  system's location prompt was put up once the prompt was answered. SwiftUI
//  lowers the flag whenever the alert comes down, and a button is not the
//  only thing that could bring one down — the place card presenting it can
//  be closed from under it — which would not be the hiker saying *Keep
//  Following*. So the flag's setter does nothing, each button puts the
//  question away itself, and a question left standing is still there for
//  whichever presenter is in front.
//
//  Presented with what the map's controls open — see ``MapControlModals`` —
//  although no control opens it: a fix raises it, at any moment, and a place
//  card can be up over the map sheet at that moment as easily as when a
//  control is tapped. Attached to the map sheet's contents alone it would
//  take the card down to come up.
//

import SwiftUI

extension View {
    /// Presents the walk's off-trail question from `presenter` — the map
    /// sheet's contents, or a place card over them.
    func offTrailQuestionAlert(
        _ modals: MapControlModals,
        from presenter: MapControlModals.Presenter,
        model: OpenHikesModel
    ) -> some View {
        modifier(
            OffTrailQuestionAlert(
                modals: modals,
                presenter: presenter,
                session: model.walkSession,
                entry: model.recordingEntry
            )
        )
    }
}

/// A modifier so that its own body, and nothing above it, reads the question
/// and builds the binding that reads it again — see ``LocationAccessPrompt``.
private struct OffTrailQuestionAlert: ViewModifier {
    let modals: MapControlModals
    let presenter: MapControlModals.Presenter
    let session: TrailWalkSession
    let entry: RecordingEntry

    /// Up while the question stands. The setter does nothing: each button
    /// puts the question away itself, and nothing else may — see the file
    /// header.
    private var isAsked: Binding<Bool> {
        Binding(
            get: { session.offTrailQuestion != nil },
            set: { _ in /* only an answer puts the question away */ }
        )
    }

    func body(content: Content) -> some View {
        content.alert(
            "Off the trail",
            isPresented: modals.binding(isAsked, for: presenter),
            presenting: session.offTrailQuestion
        ) { _ in
            Button("Record Instead") {
                // Answered now, before the walk has been handed over: the
                // hand-off reads the walk's line first, and the question
                // must not be standing while it does.
                session.withdrawOffTrailQuestion()
                entry.recordInsteadOfWalk()
            }
            Button("Keep Following", role: .cancel) { session.keepFollowing() }
        } message: { question in
            Text(
                """
                You’ve left \(question.trailTitle). Keep following it, or record your own hike instead? A recording \
                starts with what you’ve hiked so far.
                """
            )
        }
    }
}
