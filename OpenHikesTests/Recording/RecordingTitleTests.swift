//
//  RecordingTitleTests.swift
//  OpenHikesTests
//
//  The name a recording is offered, part by part: the town, the trail, the
//  word for a loop and the day, in that order, each left out when the walk
//  does not have it — and the word never said beside a name that says it.
//
//  The day is asked of ``RecordingTitle/day(_:calendar:)`` rather than
//  spelled, because it is written in the runner's own locale and time zone.
//  What is spelled is everything around it.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Recording title")
struct RecordingTitleTests {
    private static let date = Date(timeIntervalSinceReferenceDate: 817_000_000)
    private static let day = RecordingTitle.day(date)

    @Test("a walk round a trail is named for its town, the trail as a loop, and the day")
    func everyPartInOrder() {
        let title = RecordingTitle.title(
            city: "Schönau am Königssee",
            trail: "Malerwinkel",
            shape: .loop,
            date: Self.date
        )

        #expect(title == "Schönau am Königssee – Malerwinkel Loop – \(Self.day)")
    }

    @Test(
        "only a loop is said of a trail",
        arguments: [RouteShape.outAndBack, .pointToPoint, nil]
    )
    func otherShapesAreNotSaid(shape: RouteShape?) {
        let title = RecordingTitle.title(city: "Ramsau", trail: "Wimbachklamm", shape: shape, date: Self.date)

        #expect(title == "Ramsau – Wimbachklamm – \(Self.day)")
    }

    @Test("a trail that calls itself a loop is not called one twice")
    func aLoopByNameIsSaidOnce() {
        let title = RecordingTitle.title(
            city: "Schönau am Königssee",
            trail: "Malerwinkel-Rundweg",
            shape: .loop,
            date: Self.date
        )

        #expect(title == "Schönau am Königssee – Malerwinkel-Rundweg – \(Self.day)")
    }

    @Test("a walk with no town to name it is named for its trail and the day")
    func noTownLeavesTheTrail() {
        #expect(
            RecordingTitle.title(city: nil, trail: "Ridge Path", shape: .loop, date: Self.date)
                == "Ridge Path Loop – \(Self.day)"
        )
        #expect(
            RecordingTitle.title(city: "  ", trail: "Ridge Path", shape: nil, date: Self.date)
                == "Ridge Path – \(Self.day)"
        )
    }

    /// The name such a walk had before the trail joined it, and a loop no
    /// trail named stays unsaid: "Budapest Loop" would name a loop for a town.
    @Test("a walk no trail named is named for its town and the day")
    func noTrailLeavesTheTown() {
        #expect(
            RecordingTitle.title(city: "Budapest", trail: nil, shape: .loop, date: Self.date)
                == "Budapest – \(Self.day)"
        )
        #expect(
            RecordingTitle.title(city: " Szentendre\n", trail: " ", shape: nil, date: Self.date)
                == "Szentendre – \(Self.day)"
        )
    }

    /// Which leaves the draft's own name: the time of day and the date.
    @Test("a walk with neither a town nor a trail is offered nothing")
    func nothingToNameItFor() {
        #expect(RecordingTitle.title(city: nil, trail: nil, shape: .loop, date: Self.date) == nil)
        #expect(RecordingTitle.title(city: " ", trail: "\n", shape: nil, date: Self.date) == nil)
    }

    @Test("a trail named for its town says the town once")
    func aTrailNamedForItsTown() {
        let title = RecordingTitle.title(city: "Hallstatt", trail: "HALLSTATT", shape: nil, date: Self.date)

        #expect(title == "HALLSTATT – \(Self.day)")
    }

    /// So a list of walks named either way reads by the same date.
    @Test("the day is the one the time-of-day name ends with")
    func theDayIsTheDefaultNamesDay() {
        let timeOfDayName = HikeRecorder.defaultTitle(for: Self.date)

        #expect(timeOfDayName.hasSuffix(RecordingTitle.separator + Self.day))
    }

    /// A route relation's name is occasionally a paragraph, and it is
    /// somebody else's text arriving over the network.
    @Test("a name is held to a hike title's length")
    func aLongNameIsBounded() throws {
        let paragraph = String(repeating: "Höhenweg ", count: 60)

        let title = try #require(
            RecordingTitle.title(city: "Berchtesgaden", trail: paragraph, shape: nil, date: Self.date)
        )

        #expect(title.count <= HikeTitle.maximumCharacters)
        #expect(title.hasPrefix("Berchtesgaden – Höhenweg"))
    }

    @Test(
        "a name that says it is a loop is heard, in the language it is in",
        arguments: [
            "Emerald Lake Loop", "Kentmere Round", "Coastal Circuit",
            "Malerwinkel-Rundweg", "Seerundweg", "Königssee Rundwanderweg", "Panorama Runde",
            "Boucle du Lac Blanc", "Tour du Mont Blanc",
            "Ruta circular de Peñalara", "Senda del Oso (Circular)", "Anillo Verde",
            "Anello del Monte Baldo", "Giro del lago",
            "Большое Севастопольское кольцо", "Кольцевая тропа", "Тропа вокруг озера",
            "Pętla Karkonoska", "PĘTLA", "Szlak dookoła jeziora",
            "Велике кільце", "Стежка навколо озера",
            "Budai körtúra", "Rondwandeling Veluwe", "Naučný okruh",
        ]
    )
    func loopNamesAreHeard(name: String) {
        #expect(RecordingTitle.saysLoop(name))
    }

    @Test(
        "a name that does not say it is not",
        arguments: [
            "Ridge Path", "AV Weg 444", "Soleleitungsweg", "Wiesengrund",
            "Sentier des Douaniers", "Sentiero degli Dei", "Camino del Rey",
            "Тропа Голицына", "Szlak Orlich Gniazd", "Стежка Довбуша",
        ]
    )
    func otherNamesAreNot(name: String) {
        #expect(!RecordingTitle.saysLoop(name))
    }
}
