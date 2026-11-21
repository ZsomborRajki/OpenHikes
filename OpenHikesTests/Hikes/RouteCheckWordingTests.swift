//
//  RouteCheckWordingTests.swift
//  OpenHikesTests
//
//  What a section to check and its answers are called, and what the hike's
//  own screen says there is to look at. The words are all a hiker without
//  sight has to tell two answers apart by, and the count is what tells them
//  the hike is asking.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Route check wording")
struct RouteCheckWordingTests {
    private static let assembly = RouteAssembly(
        pieces: [.check(1)],
        checks: [
            RouteCheck(
                id: 1,
                kind: .snapped,
                savedChoice: .matched,
                savedRange: 0...1,
                rawRange: 0...1,
                trailName: "Ridge Path"
            ),
        ]
    )

    /// A drive off the end of a walk, as ``RouteCarriedEnds`` reports one.
    private static let carriedEnds = RouteCarriedEnds(
        trailing: RouteCarriedEnds.Stretch(range: 1000...9000, carriedMeters: 8000)
    )

    @Test("the hike's screen counts the sections and says how far was not on foot")
    func theNoticeSaysWhatThereIsToLookAt() throws {
        let ends = try #require(RouteEdit.NotOnFoot(Self.carriedEnds))
        let both = RouteEdit(assembly: Self.assembly, notOnFoot: ends)
        let stretches = RouteEdit(assembly: Self.assembly)
        let ride = RouteEdit(notOnFoot: ends)

        #expect(RouteCheckWording.noticeLines(for: both).count == 2)
        #expect(RouteCheckWording.noticeLines(for: stretches) == ["1 section to check"])
        #expect(RouteCheckWording.noticeLines(for: ride).count == 1)
        #expect(RouteCheckWording.noticeLines(for: ride).first?.hasSuffix("not on foot") == true)
        #expect(RouteCheckWording.noticeLines(for: both.looked).isEmpty)
        #expect(RouteCheckWording.noticeLines(for: RouteEdit()).isEmpty)
    }

    @Test("each answer says what it follows and how long the section is under it")
    func theAnswersAreToldApart() {
        let snapped = Self.assembly.checks[0]
        var unnamed = snapped
        unnamed.trailName = nil
        let gap = RouteCheck(
            id: 2,
            kind: .gap,
            savedChoice: .gps,
            savedRange: 0...1,
            rawRange: 0...1,
            unobservedSeconds: 900,
            isBridged: false
        )
        let fork = RouteCheck(
            id: 3,
            kind: .ambiguous,
            savedChoice: .gps,
            savedRange: 0...1,
            rawRange: 0...1,
            alternatives: [
                RouteCheck.Alternative(id: 0, points: [], trailNames: ["North Fork", "Fork Trail"]),
                RouteCheck.Alternative(id: 1, points: []),
            ]
        )

        #expect(RouteCheckWording.title(for: .matched, in: snapped) == "Use Ridge Path")
        #expect(RouteCheckWording.title(for: .matched, in: unnamed) == "Use the mapped trail")
        #expect(RouteCheckWording.title(for: .gps, in: snapped) == "Use GPS only")
        #expect(RouteCheckWording.title(for: .gps, in: gap) == "Draw a straight line")
        #expect(RouteCheckWording.title(for: .alternative(1), in: fork) == "Option B")
        #expect(RouteCheckWording.optionLabel(26) == "27", "past Z the options are numbered")

        func subtitle(_ choice: RouteCheck.Choice, in check: RouteCheck) -> String {
            RouteCheckWording.subtitle(for: choice, in: check, meters: 400)
        }
        #expect(subtitle(.matched, in: snapped).hasPrefix("Snapped to the trail · "))
        #expect(subtitle(.gps, in: snapped).hasPrefix("Keep the recorded line · "))
        #expect(subtitle(.gps, in: gap).hasPrefix("Straight across the gap · "))
        #expect(subtitle(.alternative(0), in: fork).hasPrefix("North Fork, Fork Trail · "))
        #expect(subtitle(.alternative(1), in: fork).hasPrefix("Unnamed trail · "))

        #expect(RouteCheckWording.prompt(for: snapped) == "The highlighted section was moved onto a mapped trail.")
        #expect(RouteCheckWording.prompt(for: gap).hasPrefix("No position was recorded for "))
        #expect(RouteCheckWording.prompt(for: gap).hasSuffix("so the line is drawn straight across it."))
        #expect(RouteCheckWording.prompt(for: fork) == "The highlighted section has more than one plausible route.")

        #expect(RouteCheckWording.identifier(for: .matched) == "review-choice-trail")
        #expect(RouteCheckWording.identifier(for: .gps) == "review-choice-gps")
        #expect(RouteCheckWording.identifier(for: .alternative(2)) == "review-choice-alternative-2")
    }
}
