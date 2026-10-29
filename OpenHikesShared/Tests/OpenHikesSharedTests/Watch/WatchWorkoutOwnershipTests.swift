//
//  WatchWorkoutOwnershipTests.swift
//  OpenHikesSharedTests
//
//  Which of HealthKit's late callbacks speak for the watch's recording. Each
//  case walks the recorder's own order — attach at Start, release at Stop —
//  with stand-in objects, since a session is told apart by identity alone and
//  HealthKit's cannot be made on the host.
//

@testable import OpenHikesShared
import Testing

@Suite("Which workout session and builder speak for the watch's recording")
struct WatchWorkoutOwnershipTests {
    final class Session {}
    final class Builder {}

    typealias Ownership = WatchWorkoutOwnership<Session, Builder>

    /// A recording started on `session`, as `WatchRecorder.attach(_:)` makes
    /// one.
    static func recording(on session: Session, builder: Builder = Builder()) -> Ownership {
        var ownership = Ownership()
        ownership.attach(session, builder: builder)
        return ownership
    }

    @Test("the running session's failure ends its recording")
    func currentFailureEnds() {
        let session = Session()
        let ownership = Self.recording(on: session)
        #expect(ownership.failureEnds(session, isRecording: true))
    }

    @Test("an ended session's failure after the next Start leaves the new recording running")
    func oldFailureAfterNewStart() {
        let first = Session()
        var ownership = Self.recording(on: first)
        // Stop, then Start: the recorder lets the first pair go and holds the
        // second.
        #expect(ownership.release()?.session === first)
        let second = Session()
        ownership.attach(second, builder: Builder())
        // Before #1231 the recorder asked only whether something was
        // recording, and this stopped the second walk.
        #expect(!ownership.failureEnds(first, isRecording: true))
        #expect(ownership.failureEnds(second, isRecording: true))
    }

    @Test("a failure overtaken by Stop and a new Start is refused when its stop runs")
    func failureOvertakenBeforeItsStop() {
        let first = Session()
        var ownership = Self.recording(on: first)
        // Heard on arrival: the first session is held and recording.
        #expect(ownership.failureEnds(first, isRecording: true))
        // Before the scheduled stop runs, the hiker stops that walk and starts
        // another.
        _ = ownership.release()
        ownership.attach(Session(), builder: Builder())
        // Asked again when it runs, it no longer speaks for what is recording.
        #expect(!ownership.failureEnds(first, isRecording: true))
    }

    @Test("a failure while nothing is recording stops nothing")
    func failureWithNothingRecording() {
        let session = Session()
        var ownership = Self.recording(on: session)
        // Stopped, or between a Stop and the next Start's permission prompt:
        // nothing is held.
        _ = ownership.release()
        #expect(!ownership.failureEnds(session, isRecording: false))
        #expect(!ownership.failureEnds(session, isRecording: true))
        // Held but not recording is the recorder's own guard, kept here.
        let held = Self.recording(on: session)
        #expect(!held.failureEnds(session, isRecording: false))
    }

    @Test("a recovered session takes over from the one it replaced")
    func recoveredSessionTakesOver() {
        let crashed = Session()
        var ownership = Self.recording(on: crashed)
        let recovered = Session()
        ownership.attach(recovered, builder: Builder())
        #expect(ownership.failureEnds(recovered, isRecording: true))
        #expect(!ownership.failureEnds(crashed, isRecording: true))
    }

    @Test("only the held builder's reading reaches the screen")
    func onlyTheHeldBuilderIsHeard() {
        let firstBuilder = Builder()
        var ownership = Self.recording(on: Session(), builder: firstBuilder)
        #expect(ownership.admitsCollection(from: firstBuilder))
        _ = ownership.release()
        // Discarded at Stop: its late reading belongs to no walk.
        #expect(!ownership.admitsCollection(from: firstBuilder))
        let secondBuilder = Builder()
        ownership.attach(Session(), builder: secondBuilder)
        #expect(!ownership.admitsCollection(from: firstBuilder))
        #expect(ownership.admitsCollection(from: secondBuilder))
    }

    @Test("release hands back the held pair once, and nothing after")
    func releaseHandsBackOnce() {
        let session = Session()
        let builder = Builder()
        var ownership = Self.recording(on: session, builder: builder)
        let released = ownership.release()
        #expect(released?.session === session)
        #expect(released?.builder === builder)
        #expect(ownership.session == nil)
        #expect(ownership.builder == nil)
        // A second Stop ends nothing twice.
        #expect(ownership.release() == nil)
    }
}
