//
//  RecordingHapticsTests.swift
//  OpenHikesTests
//

@testable import OpenHikes
import OpenHikesShared
import Testing

/// The phone recorder's half of the haptic agreement.
///
/// The table itself is pinned in the shared package by `HapticWalkStateTests`,
/// on states with names of their own. What is only true *here* is the
/// projection: which of this recorder's eight phases becomes which state, and
/// therefore which of its real transitions a hiker feels. That is what these
/// assert, in terms of `HikeRecorder.Phase` rather than of the shared enum, so
/// a phase renamed or re-pointed fails here rather than silently changing what
/// a walk feels like.
///
/// Both endings run through ``HikeRecorder/resetSession()`` and land on
/// `.idle`, which is the whole reason `savingIsTheOnlyRouteToASave` exists: it
/// is the one thing about this projection that cannot be got right by reading
/// the case names.
@Suite("Recording haptics")
struct RecordingHapticsTests {
    private func moment(
        _ old: HikeRecorder.Phase,
        _ new: HikeRecorder.Phase
    ) -> HapticMoment? {
        HapticMoment.walk(from: old.hapticWalkState, to: new.hapticWalkState)
    }

    @Test("Starting a recording, and then getting a fix")
    func startingAndAcquiringAFix() {
        #expect(moment(.idle, .waitingForFix) == .walkBegan)
        #expect(moment(.waitingForFix, .recording) == .trackingBegan)
    }

    @Test("Pausing and resuming")
    func pausingAndResuming() {
        #expect(moment(.recording, .paused) == .walkPaused)
        #expect(moment(.paused, .recording) == .walkResumed)
    }

    /// `discard()` stops the sensors and resets the session without ever
    /// setting `.saving`; every save sets it first. Nothing else tells the two
    /// apart, because both end on the same phase.
    @Test("Only a walk that passed through saving was saved")
    func savingIsTheOnlyRouteToASave() {
        #expect(moment(.saving, .idle) == .walkSaved)
        #expect(moment(.recording, .idle) == .walkDiscarded)
        #expect(moment(.paused, .idle) == .walkDiscarded)
    }

    /// Discard sits beside the review controls, so a thrown-away walk can
    /// reach `.idle` from `.reviewing` — which a saved one also passes
    /// through on its way to `.saving`.
    @Test("Discarding from the review screen is not a save")
    func discardingFromReview() {
        #expect(moment(.reviewing, .idle) == .walkDiscarded)
        #expect(moment(.reviewing, .saving) == nil)
        #expect(moment(.saving, .reviewing) == nil)
    }

    @Test("Every failure is reported, and retrying one begins a walk")
    func failingAndRetrying() {
        #expect(moment(.recording, .failed(.storageUnavailable)) == .walkFailed)
        #expect(moment(.saving, .failed(.storageUnavailable)) == .walkFailed)
        #expect(moment(.failed(.storageUnavailable), .waitingForFix) == .walkBegan)
        // Dismissing a failure is not starting anything.
        #expect(moment(.failed(.storageUnavailable), .idle) == nil)
    }

    /// A relaunch into a recovered recording is not something the hiker asked
    /// for, and the screen explains it in words. The one exception is a
    /// recovery that failed, which is the hiker's walk not being recorded.
    @Test("A recovery is silent, and its failure is not")
    func recoveryIsSilent() {
        #expect(moment(.idle, .recovering) == nil)
        #expect(moment(.recovering, .waitingForFix) == nil)
        #expect(moment(.recovering, .paused) == nil)
        #expect(moment(.recovering, .failed(.storageUnavailable)) == .walkFailed)
    }

    /// `waitingForFix` and `recovering` are different phases and the same
    /// haptic state, so this really is reachable: the recorder moved and the
    /// table must still say nothing.
    @Test("Two phases that mean one state are not an event between them")
    func lossyProjectionIsNotAnEvent() {
        #expect(HikeRecorder.Phase.waitingForFix.hapticWalkState == .preparing)
        #expect(moment(.recording, .recording) == nil)
    }
}
