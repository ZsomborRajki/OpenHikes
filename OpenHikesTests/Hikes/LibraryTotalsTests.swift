//
//  LibraryTotalsTests.swift
//  OpenHikesTests
//
//  What "how far you have walked" counts. Three decisions, each of which is
//  off by a factor for exactly the hiker this screen is for if it goes the
//  other way — see `LibraryTotals.swift`.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Library totals")
struct LibraryTotalsTests {
    private static let calendar: Calendar = {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return utc
    }()

    private static func date(_ year: Int, _ month: Int, _ day: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }

    private static func hike(
        on date: Date,
        meters: Double,
        id: UUID = UUID(),
        title: String = "Walk",
        climb: Double? = 100,
        highest: Double? = 1000,
        clock: Bool = true,
        community: Bool = false
    ) -> LibraryHikeFacts {
        LibraryHikeFacts(
            hikeID: id,
            title: title,
            date: date,
            distanceMeters: meters,
            climbMeters: climb,
            highestMeters: highest,
            movingSeconds: clock ? 3600 : nil,
            clock: clock ? DateInterval(start: date, duration: 3 * 3600) : nil,
            isFromCommunity: community
        )
    }

    private static func walk(
        of hikeID: UUID,
        on date: Date,
        covered: Double,
        of route: Double,
        recordingsOwn: Bool = false
    ) -> LibraryWalkFacts {
        LibraryWalkFacts(
            hikeID: hikeID,
            startedAt: date,
            endedAt: date.addingTimeInterval(1800),
            coveredMeters: covered,
            routeDistanceMeters: route,
            activeSeconds: 1800,
            isRecordingsOwn: recordingsOwn
        )
    }

    private static func totals(_ hikes: [LibraryHikeFacts], _ walks: [LibraryWalkFacts] = []) -> LibraryTotals {
        LibraryTotals(hikes: hikes, walks: walks, year: 2026, calendar: calendar)
    }

    // MARK: What counts as walked

    @Test("a hike with a clock is walked, one without is not")
    func onlyClockedHikesCount() {
        let totals = Self.totals([
            Self.hike(on: Self.date(2026, 5), meters: 10_000),
            Self.hike(on: Self.date(2026, 6), meters: 25_000, clock: false),
        ])
        #expect(totals.allTime.distanceMeters == 10_000)
        #expect(totals.allTime.outings == 1)
    }

    /// Saved from the community and never walked: in the library, not walked.
    @Test("a hike saved from the community is not walked, even with a clock")
    func communityImportsDoNotCount() {
        let totals = Self.totals([Self.hike(on: Self.date(2026, 5), meters: 12_000, community: true)])
        #expect(totals.allTime.outings == 0)
    }

    // MARK: Walks, not trails

    /// A trail walked six times is six walks and one hike — summing the hike
    /// would be off by six.
    @Test("each walk along a saved trail counts what it covered")
    func walksCountTheirCoverage() {
        let trail = UUID()
        let hikes = [Self.hike(on: Self.date(2025, 1), meters: 8000, id: trail, climb: 400, clock: false)]
        let walks = (1...6).map { month in
            Self.walk(of: trail, on: Self.date(2026, month), covered: 4000, of: 8000)
        }
        let totals = Self.totals(hikes, walks)

        #expect(totals.thisYear.distanceMeters == 24_000)
        #expect(totals.thisYear.outings == 6)
        #expect(totals.thisYear.trails == 1)
        #expect(totals.thisYear.climbMeters == 1200, "half the trail's climb, six times")
    }

    /// A recording writes a walk of itself; counting both would count the
    /// recording twice.
    @Test("a recording's own walk is not counted a second time")
    func recordingsOwnWalkIsSkipped() {
        let recorded = UUID()
        let totals = Self.totals(
            [Self.hike(on: Self.date(2026, 3), meters: 9000, id: recorded)],
            [Self.walk(of: recorded, on: Self.date(2026, 3), covered: 9000, of: 9000, recordingsOwn: true)]
        )
        #expect(totals.allTime.distanceMeters == 9000)
        #expect(totals.allTime.outings == 1)
    }

    /// Following and recording run side by side, so one afternoon can leave
    /// both a recording and a walk along the trail it followed.
    @Test("a walk followed during a recording is not counted a second time")
    func walkDuringRecordingIsSkipped() {
        let trail = UUID()
        let afternoon = Self.date(2026, 7).addingTimeInterval(13 * 3600)
        let totals = Self.totals(
            [
                Self.hike(on: Self.date(2025, 1), meters: 8000, id: trail, clock: false),
                Self.hike(on: afternoon, meters: 11_000),
            ],
            [
                Self.walk(of: trail, on: afternoon.addingTimeInterval(1200), covered: 6000, of: 8000),
                Self.walk(of: trail, on: afternoon.addingTimeInterval(-86_400), covered: 8000, of: 8000),
            ]
        )
        #expect(totals.allTime.distanceMeters == 19_000, "the recording, and the walk of the day before")
        #expect(totals.allTime.outings == 2)
    }

    @Test("a trail saved from the community and walked counts its walk")
    func walkedCommunityTrailCounts() {
        let saved = UUID()
        let totals = Self.totals(
            [Self.hike(on: Self.date(2024, 1), meters: 5000, id: saved, community: true)],
            [Self.walk(of: saved, on: Self.date(2026, 8), covered: 5000, of: 5000)]
        )
        #expect(totals.thisYear.distanceMeters == 5000)
    }

    // MARK: Which year

    @Test("this year, last year and all time are separate sums, by the walk's own date")
    func yearsAreTheWalksOwn() {
        let totals = Self.totals([
            Self.hike(on: Self.date(2026, 2), meters: 1000),
            Self.hike(on: Self.date(2025, 2), meters: 2000),
            Self.hike(on: Self.date(2019, 7), meters: 4000),
        ])
        #expect(totals.thisYear.distanceMeters == 1000)
        #expect(totals.lastYear.distanceMeters == 2000)
        #expect(totals.allTime.distanceMeters == 7000)
    }

    @Test("months are summed into their own bar")
    func monthsAreSummed() {
        let totals = Self.totals([
            Self.hike(on: Self.date(2026, 3, 1), meters: 1000),
            Self.hike(on: Self.date(2026, 3, 20), meters: 500),
            Self.hike(on: Self.date(2025, 12), meters: 700),
        ])
        #expect(totals.monthsThisYear[2] == 1500)
        #expect(totals.monthsThisYear.reduce(0, +) == 1500)
        #expect(totals.monthsLastYear[11] == 700)
    }

    // MARK: Records

    @Test("the records are chosen among walked hikes")
    func recordsAreWalkedHikes() {
        let totals = Self.totals([
            Self.hike(on: Self.date(2026, 1), meters: 30_000, title: "Long", climb: 600, highest: 1500),
            Self.hike(on: Self.date(2026, 2), meters: 10_000, title: "High", climb: 900, highest: 2900),
            Self.hike(on: Self.date(2026, 3), meters: 3000, title: "Steep", climb: 1000, highest: 2000),
            Self.hike(
                on: Self.date(2026, 4), meters: 90_000, title: "Unwalked", climb: 5000, highest: 4000, clock: false
            ),
        ])
        #expect(totals.longest?.title == "Long")
        #expect(totals.highest?.title == "High")
        #expect(totals.steepest?.title == "Steep")
    }

    /// A record is how far one outing went, not how long the trail it was on
    /// is.
    @Test("a trail walked part of the way is a record of the part")
    func recordsAreOutings() {
        let trail = UUID()
        let totals = Self.totals(
            [
                Self.hike(on: Self.date(2025, 1), meters: 30_000, id: trail, title: "Trail", clock: false),
                Self.hike(on: Self.date(2026, 2), meters: 10_000, title: "Recorded"),
            ],
            [Self.walk(of: trail, on: Self.date(2026, 3), covered: 2000, of: 30_000)]
        )
        #expect(totals.longest?.title == "Recorded")
        #expect(totals.longest?.distanceMeters == 10_000)
    }

    /// A few hundred steep metres is a driveway, not a record.
    @Test("a very short hike is never the steepest")
    func steepestNeedsLength() {
        let totals = Self.totals([
            Self.hike(on: Self.date(2026, 1), meters: 300, title: "Ramp", climb: 150),
            Self.hike(on: Self.date(2026, 2), meters: 5000, title: "Climb", climb: 800),
        ])
        #expect(totals.steepest?.title == "Climb")
    }

    @Test("an empty library has nothing to say")
    func emptyLibrary() {
        let totals = Self.totals([])
        #expect(totals.allTime.outings == 0)
        #expect(totals.longest == nil)
        #expect(totals.monthsThisYear == Array(repeating: 0, count: 12))
    }
}
