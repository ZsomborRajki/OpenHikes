//
//  HikeRecorderTests+PlaceName.swift
//  OpenHikesTests
//
//  What a recording no trail named is called: the town it started in, asked
//  about once, at the walk's first fix — see `HikeRecorder+PlaceName.swift`.
//
//  The geocoder is a stub that answers with the town it is given and writes
//  down every coordinate it was asked about, for the reason every transport
//  here is a seam (*Deliberate test seams*). Its answer arrives through a task,
//  as MapKit's does, so a test that needs the answer waits for it to land.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

/// What the recorder asks the name of the town a walk started in, instead of
/// MapKit.
final class StubRecordingPlaceNaming: RecordingPlaceNaming {
    /// What every question is answered with. `nil` is a lookup that failed or
    /// found nothing — the recorder is told the same either way.
    var city: String?
    /// When set, an answer waits for ``releaseAnswers()``: a geocoder still
    /// thinking when the walk ends.
    var holdsAnswers = false
    /// Every coordinate asked about, in order.
    private(set) var askedCoordinates: [CLLocationCoordinate2D] = []
    /// How many answers have been handed back. The recorder takes an answer in
    /// the same turn it arrives in, so once this moves the answer has been
    /// kept or dropped — which is what lets a test prove it was dropped.
    private(set) var answerCount = 0
    private var heldAnswers: [CheckedContinuation<Void, Never>] = []

    init(city: String?) {
        self.city = city
    }

    func cityName(at coordinate: CLLocationCoordinate2D) async -> String? {
        askedCoordinates.append(coordinate)
        if holdsAnswers {
            await withCheckedContinuation { continuation in
                heldAnswers.append(continuation)
            }
        }
        answerCount += 1
        return city
    }

    func releaseAnswers() {
        let held = heldAnswers
        heldAnswers = []
        for continuation in held {
            continuation.resume()
        }
    }
}

extension HikeRecorderTests {
    /// Waits for the town's answer to become the name the walk is offered.
    private func settleStartPlace(of recorder: HikeRecorder) async {
        await settleDelegateHop(until: "the town the walk started in to name it") {
            recorder.suggestedTitle != nil
        }
    }

    /// The placeholder the stop alert shows, and the promise it makes: a hiker
    /// who types nothing gets the town's name, in `title`.
    @Test("a walk no trail named is named for the town it started in")
    func aWalkIsNamedForTheTownItStartedIn() async throws {
        let recorder = makeRecorder(placeNames: StubRecordingPlaceNaming(city: "Budapest"))
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        clock.advance(by: 60)
        source.deliver(fix(latitude: 47.631))
        await settleStartPlace(of: recorder)

        let startedAt = try #require(recorder.sessionStartedAt)
        let townsName = try #require(HikeRecorder.placeTitle(city: "Budapest", for: startedAt))
        #expect(recorder.suggestedTitle == townsName)
        // Held, not written: the draft is renamed when the hike is saved.
        let draft = try #require(recorder.currentHike)
        #expect(draft.title == HikeRecorder.defaultTitle(for: draft.date))

        let hike = try savedHike(from: await recorder.stop())

        #expect(hike.title == townsName)
        #expect(hike.customName == nil, "nobody typed this name")
    }

    /// Today's name with the town where the time of day was, so a list of
    /// walks named either way reads by the same date.
    @Test("the town takes the place of the time of day in the name")
    func theTownTakesTheTimeOfDaysPlace() throws {
        let date = clock.now
        let timeOfDayName = HikeRecorder.defaultTitle(for: date)
        let day = try #require(timeOfDayName.components(separatedBy: " – ").last)

        #expect(HikeRecorder.placeTitle(city: "Budapest", for: date) == "Budapest – \(day)")
        #expect(HikeRecorder.placeTitle(city: " Szentendre\n", for: date) == "Szentendre – \(day)")
        #expect(HikeRecorder.placeTitle(city: "  ", for: date) == nil)
    }

    /// The trail is the more particular name: every walk from the town's
    /// station starts in the town, and this one went along the ridge.
    @Test("the trail a walk followed outranks the town it started in")
    func theTrailOutranksTheTown() async throws {
        let recorder = makeRecorder(placeNames: StubRecordingPlaceNaming(city: "Budapest"))
        await recorder.start()
        walk(recorder, to: 47.63, on: "Ridge Path")
        walk(recorder, to: 47.631, on: "Ridge Path")
        walk(recorder, to: 47.632, on: "Ridge Path")
        await settleDelegateHop(until: "the town to answer") {
            recorder.startPlaceTitle != nil
        }

        #expect(recorder.suggestedTitle == "Ridge Path")
        let hike = try savedHike(from: await recorder.stop())
        #expect(hike.title == "Ridge Path")
    }

    @Test("a name the hiker typed outranks the town's")
    func aTypedNameOutranksTheTown() async throws {
        let recorder = makeRecorder(placeNames: StubRecordingPlaceNaming(city: "Budapest"))
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        clock.advance(by: 60)
        source.deliver(fix(latitude: 47.631))
        await settleStartPlace(of: recorder)

        let hike = try savedHike(from: await recorder.stop(customName: "Sunday Walk"))

        #expect(hike.displayTitle == "Sunday Walk")
        #expect(hike.title == HikeRecorder.placeTitle(city: "Budapest", for: hike.date))
    }

    /// A trailhead with no signal, or somewhere MapKit has no name for: the
    /// walk is named as every recording was before the town was asked.
    @Test("a start with no town to name it keeps the time of day")
    func aStartWithNoTownKeepsTheTimeOfDay() async throws {
        let places = StubRecordingPlaceNaming(city: nil)
        let recorder = makeRecorder(placeNames: places)
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        clock.advance(by: 60)
        source.deliver(fix(latitude: 47.631))
        // To prove no name landed, wait for the answer that would have
        // brought one.
        await settleDelegateHop(until: "the geocoder to answer") {
            places.answerCount > 0
        }

        #expect(recorder.suggestedTitle == nil)
        let hike = try savedHike(from: await recorder.stop())
        #expect(hike.title == HikeRecorder.defaultTitle(for: hike.date))
    }

    /// One question per walk, about where it started: not one per fix, and
    /// not another when a pause ends, which starts a leg but not a walk.
    @Test("the town is asked about once, for the walk's first fix")
    func theTownIsAskedAboutOnce() async throws {
        let places = StubRecordingPlaceNaming(city: "Budapest")
        let recorder = makeRecorder(placeNames: places)
        await recorder.start()
        source.deliver(fix(latitude: 47.63, longitude: 19.05))
        clock.advance(by: 60)
        source.deliver(fix(latitude: 47.631, longitude: 19.05))
        recorder.pause()
        clock.advance(by: 300)
        await recorder.resume()
        source.deliver(fix(latitude: 47.6312, longitude: 19.05))
        // A question a later fix asked would have been answered by the time
        // the save that follows it is.
        _ = try savedHike(from: await recorder.stop())

        let asked = try #require(places.askedCoordinates.first)
        #expect(places.askedCoordinates.count == 1)
        #expect(asked.latitude.isApproximatelyEqual(to: 47.63, absoluteTolerance: 1e-7))
        #expect(asked.longitude.isApproximatelyEqual(to: 19.05, absoluteTolerance: 1e-7))
    }

    /// The answer belongs to the walk that asked. One still on its way when
    /// that walk is discarded names nothing — in particular not the next walk,
    /// which started somewhere else and asks for itself.
    @Test("an answer that lands after its walk was discarded names nothing")
    func aLateAnswerNamesNothing() async throws {
        let places = StubRecordingPlaceNaming(city: "Budapest")
        places.holdsAnswers = true
        let recorder = makeRecorder(placeNames: places)
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        await settleDelegateHop(until: "the town to be asked about") {
            places.askedCoordinates.count == 1
        }
        await recorder.discard()

        places.releaseAnswers()
        await settleDelegateHop(until: "the late answer to land") {
            places.answerCount == 1
        }
        #expect(recorder.suggestedTitle == nil)

        places.holdsAnswers = false
        places.city = "Szentendre"
        await recorder.start()
        source.deliver(fix(latitude: 47.67))
        await settleStartPlace(of: recorder)

        let startedAt = try #require(recorder.sessionStartedAt)
        #expect(recorder.suggestedTitle == HikeRecorder.placeTitle(city: "Szentendre", for: startedAt))
        #expect(places.askedCoordinates.count == 2)
    }

    /// A relaunch loses the answer the last launch was holding, so a walk it
    /// recovers asks again — about the point the walk started at, not about
    /// wherever the phone happens to be when it wakes.
    @Test("a recovered walk asks again about the point it started at")
    func aRecoveredWalkAsksAboutItsStart() async throws {
        let journal = TrackJournal(directory: directory, clock: clock.read)
        try await journal.start(sessionID: UUID(), startedAt: clock.now)
        try await journal.append(
            RecordingPoint(latitude: 47.5, longitude: 19.05, timestamp: clock.now, horizontalAccuracy: 8)
        )
        clock.advance(by: 60)
        try await journal.append(
            RecordingPoint(latitude: 47.501, longitude: 19.05, timestamp: clock.now, horizontalAccuracy: 8)
        )
        try await journal.close()

        let places = StubRecordingPlaceNaming(city: "Budapest")
        let recorder = makeRecorder(placeNames: places)
        await recorder.recoverOpenSession()
        await settleStartPlace(of: recorder)

        let asked = try #require(places.askedCoordinates.first)
        #expect(asked.latitude.isApproximatelyEqual(to: 47.5, absoluteTolerance: 1e-7))
        #expect(asked.longitude.isApproximatelyEqual(to: 19.05, absoluteTolerance: 1e-7))

        clock.advance(by: 60)
        source.deliver(fix(latitude: 47.502, longitude: 19.05))
        let hike = try savedHike(from: await recorder.stop())

        #expect(places.askedCoordinates.count == 1, "the fix after a recovered start is not another start")
        #expect(hike.title == HikeRecorder.placeTitle(city: "Budapest", for: hike.date))
    }
}
