//
//  RouteEditSaveTests+Unreadable.swift
//  OpenHikesTests
//
//  An edit record that does not read is not a hike never edited: neither a
//  save nor the editor takes it for one, so the original is never written
//  over by the edited line. And a record holding a figure that is not a
//  number is still written, rather than dropped with the original beside it.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

extension RouteEditSaveTests {
    private enum Unreadable {
        static let startSeconds: TimeInterval = 1_750_000_000
        static let start = Date(timeIntervalSince1970: startSeconds)
        static let latitude = 47.63
        static let longitude = 12.86
        static let spacing = 0.001
        static let secondsPerPoint: TimeInterval = 60
        static let pointCount = 5
        /// The part of ``line`` the hike has now: it was edited once.
        static let edited = 0...3
        /// The cut the next edit makes on it.
        static let kept = 0...2
        /// What a later build's record is to this one.
        static let record = Data("a record this build cannot read".utf8)

        static let line: [RouteCoordinate] = (0..<pointCount).map { index in
            RouteCoordinate(
                latitude: latitude + Double(index) * spacing,
                longitude: longitude,
                timestamp: start.addingTimeInterval(Double(index) * secondsPerPoint)
            )
        }
    }

    /// A hike edited by a build that writes a record this one cannot read.
    private func editedElsewhere(in context: ModelContext) throws -> Hike {
        let hike = Fixture.hike(in: context, route: Array(Unreadable.line[Unreadable.edited]))
        hike.originalRoute = Unreadable.line
        hike.routeEditData = Unreadable.record
        try context.save()
        return hike
    }

    @Test("a save does not take a record it cannot read for a hike never edited")
    func anUnreadableRecordIsNotWrittenOver() throws {
        let context = try Fixture.modelContext()
        let hike = try editedElsewhere(in: context)
        let line = hike.route
        let distances = RouteTrim.distances(along: line)
        let cut = distances[Unreadable.kept.lowerBound]...distances[Unreadable.kept.upperBound]
        let edited = try #require(EditedLine(
            whole: line,
            distances: distances,
            cuts: EditedLine.Cuts(range: cut),
            replacing: line
        ))

        let outcome = RouteEditSave.write(edited, to: hike, replacing: line, in: context)

        #expect(outcome == .refused(.notHereYet))
        #expect(hike.originalRoute == Unreadable.line, "the original is not the edited line")
        #expect(hike.routeEditData == Unreadable.record)
        #expect(hike.route == line)
    }

    @Test("the editor does not open a hike whose record it cannot read")
    func theEditorRefusesAnUnreadableRecord() async throws {
        let context = try Fixture.modelContext()
        let hike = try editedElsewhere(in: context)

        let sources = await RouteEditSources.reading(hike, drawn: hike.route, in: context.container)
        let session = RouteTrimSession()
        await session.load(sources)

        #expect(sources.isUnreadable)
        #expect(session.line == nil)
        #expect(session.refusal == .notHereYet)
    }

    @Test("a record holding a figure that is not a number is still written")
    func aNonFiniteFigureIsKept() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: Unreadable.line)
        var edit = RouteEdit()
        edit.original = RouteEdit.Original(
            distanceMeters: .nan,
            date: hike.date,
            recordedWalk: nil,
            notOnFoot: nil
        )

        hike.routeEdit = edit

        #expect(hike.routeEditData != nil)
        #expect(hike.routeEdit?.original?.distanceMeters.isNaN == true)
        #expect(!hike.hasUnreadableRouteEdit)
    }
}
