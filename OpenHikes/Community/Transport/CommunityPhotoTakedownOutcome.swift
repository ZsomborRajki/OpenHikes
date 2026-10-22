//
//  CommunityPhotoTakedownOutcome.swift
//  OpenHikes
//
//  What a reviewer's takedown of a set of contributed photographs did — which
//  is one of two things that succeeded, and a failure is not among them.
//
//  ## Why a result and not a throw for the second half
//
//  Because taking a set down is two deletes, and the first one is the one a
//  hiker can see. The published record is what puts the photographs on a
//  hike, so once it is gone they are off the hike for everybody, whatever
//  happens to the submission behind it. A throw cannot say that: it reads as
//  *nothing was removed*, which sends the screen away from the one truthful
//  thing it knows — that the photographs it is still drawing are gone — and
//  sends a retry back to a record that is no longer there.
//
//  A failure *before* the first delete is still a throw, for the opposite
//  reason: nothing changed, and nothing about the screen should.
//
//  See ``CommunityTransporting/takeDownPhotos(_:)`` for the order the two
//  deletes are done in and why it is not up for change.
//

import Foundation

/// How far a takedown of contributed photographs got when it did not throw.
nonisolated enum CommunityPhotoTakedownOutcome: Equatable, Sendable {
    /// Both records are gone.
    case complete
    /// The photographs are unlisted — off the hike for everybody — but the
    /// submission behind them could not be deleted.
    ///
    /// What is left is unlisted and unenumerable, readable only by somebody
    /// who already holds its unguessable record name, which is why this is the
    /// side of the two to be wrong on. Taking the same set down again finishes
    /// the job: the published record being already gone is not a reason to
    /// leave the submission behind.
    case unlisted(cleanupFailure: CommunityFailure)
}
