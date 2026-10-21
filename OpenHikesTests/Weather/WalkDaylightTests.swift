//
//  WalkDaylightTests.swift
//  OpenHikesTests
//
//  Which readings may tell a walk when its light goes.
//
//  The badge follows what the hiker is looking at, and the walk does not:
//  browsing another trail leaves the walk running on its own. So the dusk an
//  after-dark warning is measured against has to be asked of the walk —
//  which hike, and where on it — rather than taken from whatever the badge
//  shows. See ``WeatherSubject/isAbout(walkOn:at:)``.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Walk daylight")
struct WalkDaylightTests {
    private static let walkedID = UUID()
    private static let browsedID = UUID()
    private static let budapest = CLLocationCoordinate2D(latitude: 47.4979, longitude: 19.0402)
    /// About 3 km from ``budapest`` — inside the follow radius.
    private static let nearBudapest = CLLocationCoordinate2D(latitude: 47.5250, longitude: 19.0402)
    /// About 215 km from ``budapest`` — far outside it.
    private static let vienna = CLLocationCoordinate2D(latitude: 48.2082, longitude: 16.3738)

    // MARK: About this walk

    /// The walked trail's own reading stays pinned to its anchor until the
    /// hiker is inside the follow radius, so it can be far from them and
    /// still be the walk's.
    @Test("the walked trail's own reading counts wherever it was taken")
    func theWalkedTrailCounts() {
        let subject = WeatherSubject.trail(Self.vienna, hikeID: Self.walkedID, name: "Ridge Loop")

        #expect(subject.isAbout(walkOn: Self.walkedID, at: Self.budapest))
        #expect(subject.isAbout(walkOn: Self.walkedID, at: nil))
    }

    @Test("a reading about the hiker counts where the walk is")
    func theHikerNearbyCounts() {
        #expect(WeatherSubject.me(Self.nearBudapest).isAbout(walkOn: Self.walkedID, at: Self.budapest))
    }

    /// Another trail on the same hillside has the walk's sky, so its dusk is
    /// the walk's dusk to any precision a reminder needs.
    @Test("another trail near the walk counts")
    func aNearbyTrailCounts() {
        let subject = WeatherSubject.trail(Self.nearBudapest, hikeID: Self.browsedID, name: "Pilis Loop")

        #expect(subject.isAbout(walkOn: Self.walkedID, at: Self.budapest))
    }

    // MARK: About somewhere else

    /// The bug behind #874: a walk on one trail, the badge on another a
    /// country away, and the warning measured against the other one's dusk.
    @Test("a distant trail being browsed mid-walk does not count")
    func aDistantBrowsedTrailDoesNotCount() {
        let subject = WeatherSubject.trail(Self.vienna, hikeID: Self.browsedID, name: "Wienerwald")

        #expect(!subject.isAbout(walkOn: Self.walkedID, at: Self.budapest))
    }

    @Test("a reading about the hiker somewhere far from the walk does not count")
    func aDistantHikerReadingDoesNotCount() {
        #expect(!WeatherSubject.me(Self.vienna).isAbout(walkOn: Self.walkedID, at: Self.budapest))
    }

    /// Without a position, nothing but the walked trail is known to be about
    /// the walk — not even "here", which may have been read anywhere.
    @Test("with no position for the walk, only its own trail counts")
    func noPositionOnlyItsOwnTrail() {
        let other = WeatherSubject.trail(Self.budapest, hikeID: Self.browsedID, name: "Pilis Loop")

        #expect(!other.isAbout(walkOn: Self.walkedID, at: nil))
        #expect(!WeatherSubject.me(Self.budapest).isAbout(walkOn: Self.walkedID, at: nil))
    }

    /// The hiker asked about the city, not about where they stand.
    @Test("a searched place never counts, however near")
    func aSearchedPlaceNeverCounts() {
        let subject = WeatherSubject.place(Self.budapest, name: "Budapest")

        #expect(!subject.isAbout(walkOn: Self.walkedID, at: Self.budapest))
    }
}
