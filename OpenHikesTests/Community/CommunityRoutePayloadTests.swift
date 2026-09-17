//
//  CommunityRoutePayloadTests.swift
//  OpenHikesTests
//
//  What a published route has to survive before it is drawn or saved.
//
//  The asset behind a listing is a file any client with an Apple Account can
//  write, and until this existed the app read the whole of it, decoded it and
//  handed the result to the map and to the library without asking it anything.
//  These pin the three questions it is now asked — how big the file is, how
//  many points it holds, and whether a point is somewhere on earth — and,
//  just as importantly, pin what it is *not* asked: an ordinary walk with a
//  single bad sample in it is still a walk.
//
//  At the bytes rather than through CloudKit, which is the point of the seam:
//  a suite must never reach the real transport, and every case here is a
//  `Data` or a file in a temporary directory.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Community route payload")
struct CommunityRoutePayloadTests {
    private static let tight = CommunityRoutePayload.Limits(
        maximumAssetBytes: 512,
        maximumPointCount: 4
    )

    private func json(_ body: String) -> Data {
        Data(body.utf8)
    }

    private func route(_ count: Int) -> [RouteCoordinate] {
        (0..<count).map { step in
            RouteCoordinate(
                latitude: 47.6 + Double(step) / 10_000,
                longitude: 12.8,
                elevation: 800
            )
        }
    }

    private func encoded(_ route: [RouteCoordinate]) throws -> Data {
        try JSONEncoder().encode(CommunityRouteDocument(route: route))
    }

    // MARK: - What a real hike gets

    /// The case everything else is measured against: a route this app wrote,
    /// read back whole. Nothing here is a hostile file, and a check that cost
    /// an ordinary walk its points would be worse than no check.
    @Test("an ordinary published route comes back unchanged")
    func anOrdinaryRouteSurvives() throws {
        let published = Fixture.ridgeRoute
        let read = CommunityRoutePayload.route(from: try encoded(published))
        #expect(read == published)
    }

    /// A long walk is a long walk. The shipping budget exists to refuse an
    /// absurd file, and a real day out must not come anywhere near it.
    @Test("a day's worth of points is well inside the shipping budget")
    func aFullDayIsNotOverBudget() {
        // Roughly a 1 Hz recording of a six-hour walk.
        let day = route(21_600)
        #expect(CommunityRoutePayload.usable(day).count == day.count)
    }

    /// The cap this app publishes against. `CommunityPublisher` uploads a
    /// hike's route whole, and the largest route the library can hold is one
    /// imported from a GPX — so anything below that number here would be a
    /// hike this app published and then refused to open.
    @Test("the point budget is not tighter than what this app can publish")
    func theBudgetAllowsAnythingThisAppCanPublish() {
        #expect(
            CommunityRoutePayload.Limits.standard.maximumPointCount
                >= GPXImport.Limits.standard.maximumPointCount
        )
    }

    // MARK: - Positions

    /// The reported probe, exactly as it was written: a latitude of 999 beside
    /// one real point. Core Location calls the first invalid, and before this
    /// the pair was accepted, drawn and importable.
    ///
    /// Refused rather than cleaned, because cleaning leaves one point and one
    /// point is not a line.
    @Test("a route that is one real point and one impossible one is refused")
    func theReportedProbeIsRefused() {
        let probe = json(
            #"{"route":[{"latitude":999,"longitude":12},{"latitude":47,"longitude":12}]}"#
        )
        #expect(CommunityRoutePayload.route(from: probe).isEmpty)
    }

    /// The same bad point in the middle of a real walk, which is the case that
    /// must *not* cost the hiker the hike. The neighbours join, exactly as
    /// they do across a lost fix.
    @Test("an impossible point is dropped and the walk is kept")
    func anImpossiblePointIsDroppedFromARealWalk() throws {
        var published = route(4)
        published[2].latitude = 999

        let read = CommunityRoutePayload.route(from: try encoded(published))

        #expect(read.count == 3)
        #expect(!read.contains { $0.latitude == 999 })
        #expect(read.first == published.first)
        #expect(read.last == published.last)
    }

    /// Past Web Mercator's limit but inside Core Location's, which is the gap
    /// between the two checks. A track claiming to pass within 5° of a pole is
    /// bad data rather than something to quietly move onto the map's edge —
    /// the same call `GPXImport` makes about a waypoint.
    @Test("a point outside Web Mercator is dropped even though Core Location allows it")
    func aPolarPointIsDropped() {
        var published = route(4)
        published[1].latitude = 89
        #expect(CLLocationCoordinate2DIsValid(published[1].clCoordinate))

        let read = CommunityRoutePayload.usable(published)

        #expect(read.count == 3)
        #expect(!read.contains { $0.latitude == 89 })
    }

    /// A non-finite position, which is the shape a number no JSON writer
    /// should have produced arrives in. A range does not contain a `NaN`, so
    /// the same check settles it.
    @Test("a point with no real position is dropped")
    func aNonFinitePointIsDropped() {
        var published = route(4)
        published[1].latitude = .nan
        published[2].longitude = .infinity

        #expect(CommunityRoutePayload.usable(published).count == 2)
    }

    /// Every point unusable is a route with nothing in it, whatever the file
    /// claimed to be.
    @Test("a route with no usable position at all is refused")
    func aRouteOfImpossiblePointsIsRefused() {
        let published = (0..<8).map { _ in RouteCoordinate(latitude: 999, longitude: 999) }
        #expect(CommunityRoutePayload.usable(published).isEmpty)
    }

    // MARK: - Heights and times

    /// The height is emptied rather than costing the point, which is
    /// `GPXImport`'s distinction: a position is what the line is made of, and
    /// an elevation is a field the route can do without.
    ///
    /// It has to go somewhere, because a `NaN` loses every comparison it is in
    /// and therefore survives `min` and `max` as the answer — so one of these
    /// in a stranger's file is every elevation figure the hiker reads about
    /// that hike afterwards, and the saved hike keeps it.
    @Test("an impossible height is emptied and its point is kept")
    func aNonFiniteElevationIsEmptied() {
        var published = route(3)
        published[1].elevation = .nan
        published[2].elevation = .infinity

        let read = CommunityRoutePayload.usable(published)

        #expect(read.count == 3)
        #expect(read[1].elevation == nil)
        #expect(read[2].elevation == nil)
        #expect(read[0].elevation == published[0].elevation)
    }

    /// The same for a timestamp, which decodes from a number the same way and
    /// poisons a duration the same way.
    @Test("an impossible time is emptied and its point is kept")
    func aNonFiniteTimestampIsEmptied() {
        var published = route(3)
        published[0].timestamp = Date(timeIntervalSinceReferenceDate: 800_000_000)
        published[1].timestamp = Date(timeIntervalSinceReferenceDate: .nan)

        let read = CommunityRoutePayload.usable(published)

        #expect(read.count == 3)
        #expect(read[0].timestamp == published[0].timestamp)
        #expect(read[1].timestamp == nil)
    }

    // MARK: - Budgets

    /// Refused rather than cut down to size, for the reason the outline's
    /// budget refuses: a route truncated to fit is a trail that stops in the
    /// middle of nowhere and claims to be somebody's walk.
    @Test("a route past the point budget is refused rather than truncated")
    func anOverlongRouteIsRefused() {
        #expect(CommunityRoutePayload.usable(route(5), limits: Self.tight).isEmpty)
        #expect(CommunityRoutePayload.usable(route(4), limits: Self.tight).count == 4)
    }

    /// The budget is spent on the count that arrived, not on what is left
    /// after cleaning. A file of a million impossible points is over budget,
    /// and discarding them is not what brings it under.
    @Test("the point budget is spent before the impossible points are dropped")
    func theBudgetIsSpentOnWhatArrived() {
        var published = route(5)
        for index in published.indices.dropFirst(2) { published[index].latitude = 999 }
        #expect(CommunityRoutePayload.usable(published, limits: Self.tight).isEmpty)
    }

    /// The bytes, which is the cap that bounds memory rather than use:
    /// `JSONDecoder` does not stream, so what stands in front of the decode is
    /// the length of the data handed to it.
    @Test("an oversized payload is refused before it is decoded")
    func anOversizedPayloadIsRefused() throws {
        let published = try encoded(route(64))
        #expect(published.count > Self.tight.maximumAssetBytes)
        #expect(CommunityRoutePayload.route(from: published, limits: Self.tight).isEmpty)
    }

    /// The same asked of the file system, which is where the check has to
    /// happen for it to be worth anything: `Data(contentsOf:)` brings the
    /// whole file in as one allocation, so a size measured afterwards has
    /// already been paid for.
    @Test("an oversized asset is refused without being read")
    func anOversizedAssetIsRefused() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommunityRouteTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("route.json")
        try encoded(route(64)).write(to: file)

        #expect(CommunityRoutePayload.route(atAssetURL: file, limits: Self.tight).isEmpty)
        // The same file, under a budget that allows it: what is being tested
        // above is the size and not the reading.
        #expect(CommunityRoutePayload.route(atAssetURL: file).count == 64)
    }

    /// A file that is not there at all, which is an ordinary outcome for a
    /// `CKAsset` URL pointing into a cache CloudKit may have emptied.
    @Test("an asset that cannot be read is refused")
    func anUnreadableAssetIsRefused() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommunityRouteTest-\(UUID().uuidString).json")
        #expect(CommunityRoutePayload.route(atAssetURL: missing).isEmpty)
    }

    // MARK: - Files that are not routes

    @Test("a payload that is not a route document is refused")
    func malformedJSONIsRefused() {
        #expect(CommunityRoutePayload.route(from: json("")).isEmpty)
        #expect(CommunityRoutePayload.route(from: json("not json at all")).isEmpty)
        #expect(CommunityRoutePayload.route(from: json(#"{"route":"a ridge walk"}"#)).isEmpty)
        #expect(CommunityRoutePayload.route(from: json(#"{"trail":[]}"#)).isEmpty)
    }

    /// One point is enough for a pin and is not a line — the same call
    /// `GPXImport` makes about a one-point file, and the same one
    /// `CommunityImport` already made after the fact.
    @Test("a route with fewer than two points is refused")
    func aRouteTooShortToDrawIsRefused() throws {
        #expect(CommunityRoutePayload.route(from: json(#"{"route":[]}"#)).isEmpty)
        #expect(CommunityRoutePayload.route(from: try encoded(route(1))).isEmpty)
        #expect(CommunityRoutePayload.route(from: try encoded(route(2))).count == 2)
    }
}
