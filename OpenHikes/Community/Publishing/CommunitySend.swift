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

import Foundation
import OpenHikesData

/// What one attempt to send something to the public database did.
enum CommunitySendOutcome: Equatable {
    case refused(CommunityFailure)
    /// Accepted. Not the same as published: a person still has to look at it,
    /// and at this point nobody has.
    case submitted
}

/// Where a send form is in the one-way trip from filling in to finished.
enum CommunitySendPhase: Equatable {
    case editing
    case failed(CommunityFailure)
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
        }
    }

    /// Whether the send is in flight, which is what every control on both
    /// forms disables itself against.
    var isSending: Bool { self == .sending }

    /// Whether the form is showing its outcome rather than its fields, which
    /// is what turns *Cancel* into *Done*.
    var hasFinished: Bool { self == .sent }
}
