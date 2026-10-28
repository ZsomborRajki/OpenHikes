//
//  CommonsAuthorBudgetTests.swift
//  OpenHikesTests
//
//  The per-photographer rule both Commons selectors share: a named
//  photographer's first few compete first, the rest wait, and a file that
//  names nobody is never held back. The selectors' own suites cover what each
//  then does with the two halves.
//

@testable import OpenHikes
import Testing

@Suite("Commons author budget")
struct CommonsAuthorBudgetTests {
    private static func partition(
        _ ordered: [Int],
        authors: [Int: String]
    ) -> (preferred: [Int], heldBack: [Int]) {
        CommonsAuthorBudget.partition(ordered) { authors[$0] }
    }

    @Test("a photographer's fourth picture is held back, and their first three are not")
    func theFourthIsHeldBack() {
        let run = Array(1...5)
        let authors = Dictionary(uniqueKeysWithValues: run.map { ($0, "Road") })

        let split = Self.partition(run, authors: authors)

        #expect(CommonsTrailPhotos.perAuthorLimit == 3, "the cases below are written for a limit of three")
        #expect(split.preferred == [1, 2, 3])
        #expect(split.heldBack == [4, 5])
    }

    @Test("a file whose page names nobody is never held back, and charges nobody")
    func anonymousFilesAreNeverCharged() {
        let ordered = [1, 2, 3, 4, 5, 6, 7]
        let authors = [2: "Road", 4: "Road", 6: "Road", 7: "Road"]

        let split = Self.partition(ordered, authors: authors)

        #expect(split.preferred == [1, 2, 3, 4, 5, 6], "the unnamed 1, 3 and 5 left Road's three places alone")
        #expect(split.heldBack == [7])
    }

    @Test("each photographer is counted on their own, and both halves keep the order given")
    func orderIsKeptPerPhotographer() {
        let ordered = [9, 3, 7, 1, 8, 2, 6, 4, 5]
        let authors = [9: "Anna", 3: "Bence", 7: "Anna", 1: "Anna", 8: "Bence", 2: "Anna", 6: "Bence", 4: "Bence"]

        let split = Self.partition(ordered, authors: authors)

        #expect(split.preferred == [9, 3, 7, 1, 8, 6, 5])
        #expect(split.heldBack == [2, 4])
    }

    @Test("nothing in, nothing out")
    func emptyInput() {
        let split = Self.partition([], authors: [:])

        #expect(split.preferred.isEmpty)
        #expect(split.heldBack.isEmpty)
    }
}
