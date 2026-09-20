//
//  HapticWalkStateTests.swift
//  OpenHikesSharedTests
//

import Testing

@testable import OpenHikesShared

/// The transition table, which is the half of the haptic work that can
/// actually be got wrong.
///
/// Two of these are the reason the table is written as transitions rather than
/// destinations, and they went red against the obvious wrong version:
/// `savingIsWhatSeparatesKeptFromDiscarded`, because on iOS both a kept walk
/// and a thrown-away one end at `.idle`, and `discardingFromReview`, because
/// Discard sits on the review screen and reaches `.idle` from there.
@Suite("Haptic walk transitions")
struct HapticWalkStateTests {
    @Test("Starting a walk, and then actually recording one")
    func startingAndAcquiringAFix() {
        #expect(HapticMoment.walk(from: .idle, to: .preparing) == .walkBegan)
        #expect(HapticMoment.walk(from: .preparing, to: .running) == .trackingBegan)
    }

    /// A trail walk has no fix to wait for: it begins on a route the app is
    /// already following, so it goes straight to drawing.
    @Test("A walk with nothing to wait for still says it began")
    func startingWithoutPreparing() {
        #expect(HapticMoment.walk(from: .idle, to: .running) == .walkBegan)
    }

    @Test("Pausing and resuming")
    func pausingAndResuming() {
        #expect(HapticMoment.walk(from: .running, to: .paused) == .walkPaused)
        #expect(HapticMoment.walk(from: .paused, to: .running) == .walkResumed)
    }

    /// The case the table's shape exists for. Both walks end at `.idle` and
    /// only the route there tells them apart.
    @Test("Passing through saving is what separates kept from thrown away")
    func savingIsWhatSeparatesKeptFromDiscarded() {
        #expect(HapticMoment.walk(from: .saving, to: .idle) == .walkSaved)
        #expect(HapticMoment.walk(from: .running, to: .idle) == .walkDiscarded)
        #expect(HapticMoment.walk(from: .paused, to: .idle) == .walkDiscarded)
    }

    /// Discard sits beside the review controls, so this reaches `.idle` from
    /// `.reviewing` — which is *also* a state a save passes through, and would
    /// be reported as a save by any table keyed on the destination.
    @Test("Discarding from the review screen is not a save")
    func discardingFromReview() {
        #expect(HapticMoment.walk(from: .reviewing, to: .idle) == .walkDiscarded)
        #expect(HapticMoment.walk(from: .reviewing, to: .saving) == nil)
    }

    /// The watch's shape: it stops on a screen showing the walk rather than
    /// returning to an idle recorder, and acknowledging that screen is not
    /// news.
    @Test("A watch keeps its walk on screen, and dismissing it says nothing")
    func finishingOnTheWatch() {
        #expect(HapticMoment.walk(from: .saving, to: .finished) == .walkSaved)
        #expect(HapticMoment.walk(from: .running, to: .finished) == .walkSaved)
        #expect(HapticMoment.walk(from: .finished, to: .idle) == nil)
    }

    @Test("A failure is reported from wherever it was reached")
    func failingFromAnywhere() {
        for state in HapticWalkState.allCases where state != .failed {
            #expect(
                HapticMoment.walk(from: state, to: .failed) == .walkFailed,
                "a failure reached from \(state.rawValue) went unreported"
            )
        }
    }

    /// Retrying after a failure is asking for the walk again, and dismissing
    /// the failure is not.
    @Test("Retrying after a failure begins a walk; dismissing it does not")
    func retryingAfterAFailure() {
        #expect(HapticMoment.walk(from: .failed, to: .preparing) == .walkBegan)
        #expect(HapticMoment.walk(from: .failed, to: .running) == .walkBegan)
        #expect(HapticMoment.walk(from: .failed, to: .idle) == nil)
    }

    /// Nothing about a recovery was asked for, so nothing is said about it —
    /// except a failure, which is answered ahead of the silence.
    @Test("A recovery is silent in both directions, but its failure is not")
    func recoveryIsSilent() {
        for state in HapticWalkState.allCases where state != .failed {
            #expect(
                HapticMoment.walk(from: .recovering, to: state) == nil,
                "a recovery leaving for \(state.rawValue) should say nothing"
            )
            #expect(
                HapticMoment.walk(from: state, to: .recovering) == nil,
                "\(state.rawValue) entering a recovery should say nothing"
            )
        }
        #expect(HapticMoment.walk(from: .recovering, to: .failed) == .walkFailed)
    }

    /// The projections above are lossy — `waitingForFix` and `recovering` both
    /// land on one state — so equal pairs really do reach the table, and a
    /// redraw is not an event.
    @Test("A state that did not change is never an event")
    func unchangedStateSaysNothing() {
        for state in HapticWalkState.allCases {
            #expect(HapticMoment.walk(from: state, to: state) == nil)
        }
    }

    /// The table's common answer, and the one worth stating: it has an opinion
    /// about nine transitions out of eighty-one and is silent everywhere else.
    @Test("The table answers only the transitions a hiker would name")
    func silenceIsTheCommonAnswer() {
        let all = HapticWalkState.allCases
        let spoken = all.flatMap { old in
            all.compactMap { HapticMoment.walk(from: old, to: $0) }
        }
        #expect(spoken.count < all.count * all.count / 2)
        #expect(!spoken.isEmpty)
    }
}
