//
//  GPXSingleTrackPlaceCapTests.swift
//  OpenHikesTests
//
//  A one-track file's place cap is spent by the import, as a multi-track
//  file's is, and what it cuts is counted for the hiker (#1076).
//
//  The parse used to take the file's first ``GPXImport/maximumPlaces``
//  places itself, so the import never saw the rest: the hike arrived looking
//  complete, nothing said a marked place was gone, and an inbox copy — the
//  one source the app could have tried again from — was discarded as a
//  success. A one-track file asks nothing before it imports, so the count
//  has to come out of the import itself.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@Suite("GPX single-track place cap")
struct GPXSingleTrackPlaceCapTests {
    private func write(_ xml: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "single-place-cap-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "single-place-cap.gpx")
        try Data(xml.utf8).write(to: url)
        return url
    }

    /// The import, through the same call the map screen makes. A one-track
    /// file never asks which tracks, so a question is a failure.
    private func imported(_ xml: String) async throws -> HikeImport.Imported {
        let url = try write(xml)
        let directory = url.deletingLastPathComponent()
        let context = ModelContext(
            try ModelContainer.openHikes(
                url: directory.appending(path: "OpenHikes.store"),
                localURL: directory.appending(path: "OpenHikesLocal.store")
            )
        )
        return try await HikeImport.hikes(from: url, into: context) { _, _ in
            Issue.record("a one-track file should never ask which tracks")
            return []
        }
    }

    /// One two-point track about 1.1 km long, with `places` named waypoints
    /// along it, "P 0", "P 1"… about 4.4 m apart — the issue's own file.
    private static func file(places: Int) -> String {
        var waypoints = ""
        for index in 0..<places {
            waypoints += #"<wpt lat="\#(47 + 0.00004 * Double(index))" lon="12"><name>P \#(index)</name></wpt>"#
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="OpenHikesTests" xmlns="http://www.topografix.com/GPX/1/1">
        \(waypoints)
        <trk><name>Ridge</name><trkseg>
            <trkpt lat="47.0000" lon="12.0000"/><trkpt lat="47.0100" lon="12.0000"/>
        </trkseg></trk>
        </gpx>
        """
    }

    private static func names(_ range: Range<Int>) -> Set<String> {
        Set(range.map { "P \($0)" })
    }

    // MARK: The parse

    /// The parse keeps them all, numbered in the file's order, so the import
    /// is what cuts and can count what it cut.
    @Test("the parse keeps every place of a lone track, past the cap too")
    func parseKeepsEveryPlace() throws {
        let limit = GPXImport.maximumPlaces
        let contents = try GPXImport.loadAll(from: try write(Self.file(places: limit + 1)))

        try #require(contents.tracks.count == 1)
        #expect(contents.tracks[0].places.count == limit + 1)
        #expect(contents.tracks[0].placeOffsets == Array(0...limit))
        #expect(GPXImport.placesKept(of: contents.tracks) == [limit])
    }

    // MARK: The import

    @Test("exactly the cap imports every place and reports none cut")
    func exactlyTheCap() async throws {
        let limit = GPXImport.maximumPlaces
        let result = try await imported(Self.file(places: limit))

        try #require(result.hikes.count == 1)
        #expect(Set(result.hikes[0].places.map(\.name)) == Self.names(0..<limit))
        #expect(result.unannouncedPlacesPastLimit == 0)
    }

    /// The issue's reproduction: 201 places on the one track.
    @Test("one past the cap keeps the file's first places and reports the one it cut")
    func onePastTheCap() async throws {
        let limit = GPXImport.maximumPlaces
        let result = try await imported(Self.file(places: limit + 1))

        try #require(result.hikes.count == 1)
        #expect(Set(result.hikes[0].places.map(\.name)) == Self.names(0..<limit))
        #expect(result.unannouncedPlacesPastLimit == 1)
    }

    /// A lone track keeps every place near it or not, so a far waypoint is
    /// still one of the places the cap is counted against.
    @Test("well past the cap, every cut place is counted")
    func wellPastTheCap() async throws {
        let limit = GPXImport.maximumPlaces
        let result = try await imported(Self.file(places: limit + 37))

        #expect(result.hikes.first?.places.count == limit)
        #expect(result.unannouncedPlacesPastLimit == 37)
    }

    // MARK: The source copy

    /// The places the cap cut are cut from this file on every attempt, so an
    /// inbox copy kept for a retry would offer nothing a retry could use.
    @Test("a hike imported without all its places still lets an inbox copy go")
    func cutPlacesStillDiscardTheCopy() async throws {
        let result = try await imported(Self.file(places: GPXImport.maximumPlaces + 1))
        let hike = try #require(result.hikes.first)

        #expect(HikeImportOutcome.imported(hike, placesPastLimit: 1).discardsSourceCopy)
        #expect(HikeImportOutcome.imported(hike, placesPastLimit: 1).placesPastLimit == 1)
    }
}
