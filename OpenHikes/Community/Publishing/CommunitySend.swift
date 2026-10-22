//
//  CommunitySend.swift
//  OpenHikes
//
//  The two things every send to the public database has in common: what one
//  attempt did, and where the form that made it has got to.
//
//  There are two send forms — a hike goes through ``CommunityShareSheet`` and
//  a set of photographs through ``CommunityPhotoShareSheet`` — and they are
//  deliberately different screens, for the reasons their own headers give. But
//  a send is a send: it is accepted or refused, and the form in front of it is
//  being filled in, is in flight, has landed, or has come back with something
//  to say. Both had their own spelling of both, character for character, and a
//  fourth state added to one of them would have been a screen the other could
//  not express.
//
//  **Neither of these says *published*, and that is the whole point of the
//  last state's name.** An accepted send means a record exists and a person
//  has not looked at it yet. Whether they later said yes is asked afterwards
//  and elsewhere — see ``CommunityPublicationCheck`` for a hike and
//  ``CommunityContributionCheck`` for photographs — so `sent` is the only
//  thing true at the moment an upload lands, and it is what both forms say.
//
//  **A send is two writes, and the first can land without the second.** The
//  upload and the notice that puts it in front of a reviewer are separate
//  CloudKit saves — see ``CommunityQueueingFailure``. When only the second
//  fails the upload exists and nobody is going to be told about it, which is
//  neither a refusal (the hiker's route and photographs *are* out there) nor
//  an acceptance (no reviewer will ever see them). Calling it a refusal is
//  what stranded the first copy for good: the hiker, told it had failed, sent
//  it again, and the second upload was queued beside an orphan. So it has a
//  state of its own, and the only thing the form offers from it is to finish
//  — see ``CommunityPublisher/finishQueueing(_:transport:save:)``.
//

import Foundation

/// What one attempt to send something to the public database did.
enum CommunitySendOutcome: Equatable {
    case refused(CommunityFailure)
    /// Accepted. Not the same as published: a person still has to look at it,
    /// and at this point nobody has.
    case submitted
    /// Uploaded, and the review queue has not been told.
    ///
    /// The route and the photographs are in the public database; only the
    /// notice that puts them in front of a reviewer failed. Sending again
    /// would make a second copy beside this one, so the only thing left to do
    /// is send the notice — which uploads nothing.
    case uploadedNotQueued(CommunityFailure)
}

/// Where a send form is in the one-way trip from filling in to finished.
enum CommunitySendPhase: Equatable {
    /// Uploaded and not yet in the review queue, with the reason it is not
    /// when this launch has one.
    ///
    /// `nil` is a form opened on something an *earlier* launch left in this
    /// state: there is nothing to report yet, only the one thing to do.
    case awaitingQueue(CommunityFailure?)
    case editing
    case failed(CommunityFailure)
    /// The notice of an upload that is already there is being sent.
    ///
    /// Its own state rather than ``sending`` because nothing is being
    /// uploaded, and because the fields are not what the form is drawing:
    /// reusing ``sending`` would put the whole editable form back on screen
    /// for the length of one request, under an eligibility answer that
    /// describes a send that already happened.
    case finishing
    case sending
    case sent

    /// Where an outcome leaves the form.
    ///
    /// The mapping lives here rather than in each form's send function
    /// because it is the same mapping and there is only one sensible one: a
    /// refusal is something to say and an acceptance is the end of the trip.
    /// Written twice it was two places for a refusal to be swallowed into a
    /// success.
    init(_ outcome: CommunitySendOutcome) {
        switch outcome {
        case .submitted: self = .sent
        case .refused(let failure): self = .failed(failure)
        case .uploadedNotQueued(let failure): self = .awaitingQueue(failure)
        }
    }

    /// Whether a request is in flight, which is what every control on both
    /// forms disables itself against.
    ///
    /// True while the notice of an earlier upload is being sent as well as
    /// while an upload is: both are a hiker waiting on the network, and a
    /// second tap on either would only queue another request behind the first.
    var isSending: Bool {
        switch self {
        case .finishing, .sending: true
        case .awaitingQueue, .editing, .failed, .sent: false
        }
    }

    /// Whether the form is showing its outcome rather than its fields, which
    /// is what turns *Cancel* into *Done*.
    ///
    /// True for an upload that is waiting on its notice as well: the fields
    /// were sent, so there is nothing left on the form to cancel — only a
    /// notice to send or to leave for later.
    var hasFinished: Bool {
        switch self {
        case .sent, .awaitingQueue: true
        case .editing, .failed, .finishing, .sending: false
        }
    }
}
