//
//  GPXMultiTrackPlaceCapTests.swift
//  OpenHikesTests
//
//  A multi-track file's place cap is spent on the places of the tracks the
//  hiker chooses, once they have chosen — never on a waypoint that lies on no
//  track, and never on a track left unticked (#1037).
//
//  The cap used to take the file's first ``GPXImport/maximumPlaces`` places
//  before the split asked which track each lay on, so waypoints on no track
//  used up the slots and a later track could arrive with none of the places
//  lying on it. Spent after the split but before the choice, it still did
//  the same to a ticked day whose places came after an unticked day's.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@Suite("GPX multi-track place cap")
struct GPXMultiTrackPlaceCapTests {
    private func write(_ xml: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "place-cap-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "place-cap.gpx")
        try Data(xml.utf8).write(to: url)
        return url
    }

    /// The import, ticking the tracks at `picks`: each saved hike's places,
    /// by name.
    private func imported(_ xml: String, picking picks: [Int]) async throws -> [Set<String>] {
        let url = try write(xml)
        let directory = url.deletingLastPathComponent()
        let context = ModelContext(
            try ModelContainer.openHikes(
                url: directory.appending(path: "OpenHikes.store"),
                localURL: directory.appending(path: "OpenHikesLocal.store")
            )
        )
        let hikes = try await HikeImport.hikes(from: url, into: context) { _, _ in picks }
        return hikes.map { Set($0.places.map(\.name)) }
    }

    /// About 4.4 m of latitude, so even a few hundred waypoints in a row
    /// stay within a track's 1.1 km.
    private static let step = 0.00004

    /// Tracks running north along the 12° meridian, each about 1.1 km long
    /// and 5.5 km from the next, with `places[n]` waypoints lying on track
    /// `n` named "n 0", "n 1"… In the file, the `offTrack` huts some 38 km
    /// east of them all come first, then each track's places in turn.
    private static func file(places: [Int], offTrack: Int = 0) -> String {
        var waypoints = ""
        for index in 0..<offTrack {
            waypoints += #"<wpt lat="\#(47 + 0.0001 * Double(index))" lon="12.5"><name>Hut \#(index)</name></wpt>"#
        }
        var tracks = ""
        for (track, count) in places.enumerated() {
            let south = 47 + 0.05 * Double(track)
            for index in 0..<count {
                let latitude = south + Self.step * Double(index)
                waypoints += #"<wpt lat="\#(latitude)" lon="12"><name>\#(track) \#(index)</name></wpt>"#
            }
            tracks += #"<trk><name>Day \#(track + 1)</name><trkseg><trkpt lat="\#(south)" lon="12"/>"#
                + #"<trkpt lat="\#(south + 0.01)" lon="12"/></trkseg></trk>"#
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="OpenHikesTests" xmlns="http://www.topografix.com/GPX/1/1">
        \(waypoints)
        \(tracks)
        </gpx>
        """
    }

    /// The names of track `track`'s places from `range`.
    private static func names(_ track: Int, _ range: Range<Int>) -> Set<String> {
        Set(range.map { "\(track) \($0)" })
    }

    // MARK: The parse

    /// The issue's own file: 180 huts on neither track come first, then 20
    /// on the first track and 50 on the second.
    @Test("waypoints on no track spend nothing, and every track keeps every place it takes")
    func offTrackWaypointsSpendNothing() async throws {
        let xml = Self.file(places: [20, 50], offTrack: 180)
        let contents = try GPXImport.loadAll(from: try write(xml))

        #expect(contents.tracks.map(\.places.count) == [20, 50])
        #expect(contents.tracks[1].places.first?.name == "1 0")
        #expect(contents.unplacedWaypoints == 180)
        #expect(try await imported(xml, picking: [0, 1]) == [Self.names(0, 0..<20), Self.names(1, 0..<50)])
    }

    /// The split keeps a track's places past the cap, so that a choice of
    /// fewer tracks still has them to give. Each knows where it stands among
    /// the file's places, the three huts on no track ahead of them included.
    @Test("the split keeps every place past the cap, with where each stands in the file")
    func splitKeepsWhatTheCapWouldCut() throws {
        let limit = GPXImport.maximumPlaces
        let contents = try GPXImport.loadAll(from: try write(Self.file(places: [limit, 50], offTrack: 3)))

        #expect(contents.tracks.map(\.places.count) == [limit, 50])
        #expect(contents.tracks[0].placeOffsets == Array(3..<(limit + 3)))
        #expect(contents.tracks[1].placeOffsets == Array((limit + 3)..<(limit + 53)))
        #expect(contents.unplacedWaypoints == 3)
    }

    // MARK: The import

    /// The review's case: 200 places on Day 1 come first, then 50 on Day 2.
    /// Spent before the choice, the cap went to Day 1's and Day 2 arrived
    /// with none of its own, though the import wrote no place at all.
    @Test("a track left unticked spends none of the cap")
    func untickedTrackSpendsNothing() async throws {
        let xml = Self.file(places: [GPXImport.maximumPlaces, 50])

        #expect(try await imported(xml, picking: [1]) == [Self.names(1, 0..<50)])
    }

    /// A region's download of forty walks, six places on each: the file's
    /// first 200 places lie on the first 34 walks, and a walk past them is the
    /// one picked.
    @Test("a walk picked from a large download keeps its places")
    func pickedWalkKeepsItsPlaces() async throws {
        let xml = Self.file(places: Array(repeating: 6, count: 40))

        #expect(try await imported(xml, picking: [39]) == [Self.names(39, 0..<6)])
        #expect(try await imported(xml, picking: [2, 39]) == [Self.names(2, 0..<6), Self.names(39, 0..<6)])
    }

    /// Past the cap across the tracks ticked, the file's first places among
    /// them are kept, wherever the off-track ones fall.
    @Test("past the cap, the file's first places on the ticked tracks are kept")
    func pastTheCapTheFirstAreKept() async throws {
        let limit = GPXImport.maximumPlaces
        let xml = Self.file(places: [limit - 20, 70], offTrack: 30)

        #expect(try await imported(xml, picking: [0, 1]) == [Self.names(0, 0..<(limit - 20)), Self.names(1, 0..<20)])
    }

    /// One track alone over the cap keeps the start of its list.
    @Test("one track past the cap on its own is cut to its first places")
    func oneTrackPastTheCap() async throws {
        let limit = GPXImport.maximumPlaces
        let xml = Self.file(places: [limit + 5, 0])

        #expect(try await imported(xml, picking: [0]) == [Self.names(0, 0..<limit)])
    }

    // MARK: The cut

    private static func track(at offsets: [Int]) -> GPXImport.Track {
        GPXImport.Track(
            name: nil,
            trackDescription: nil,
            author: nil,
            keywords: nil,
            startTime: nil,
            segments: [],
            places: offsets.map { (offset: $0, element: TrailPlace(latitude: 47, longitude: 12)) }
        )
    }

    /// What the file lists first is kept, wherever it went: here the two
    /// tracks' places alternate in the file.
    @Test("the cut follows the file's order across the tracks, not the tracks' order")
    func cutFollowsTheFile() {
        let limit = GPXImport.maximumPlaces
        let odd = Self.track(at: Array(stride(from: 1, to: 2 * limit, by: 2)))
        let even = Self.track(at: Array(stride(from: 0, to: 2 * limit, by: 2)))

        #expect(GPXImport.placesKept(of: [odd, even]) == [limit / 2, limit / 2])
        #expect(GPXImport.placesKept(of: [odd]) == [limit])
        #expect(GPXImport.placesKept(of: [Self.track(at: [5, 9]), Self.track(at: [])]) == [2, 0])
        #expect(GPXImport.placesKept(of: []).isEmpty)
    }
}
