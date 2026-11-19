//
//  SheetOfflineCountriesTests.swift
//  OpenHikesTests
//
//  Where *Offline Maps* lands in the sheet. It is opened from *Map Modes*
//  over whatever the sheet shows, so it is pushed on top of that, with the
//  sheet at its middle so the outlines behind it are in view; and opened
//  again while it is already further down, it is come back to rather than
//  pushed twice. Its search field takes the whole sheet, and what the list
//  holds — the search, the order picked, the countries open — lasts through a
//  turn of the phone and goes with the screen.
//

@testable import OpenHikes
import SwiftUI
import Testing

@MainActor
@Suite("Sheet Offline Maps")
struct SheetOfflineCountriesTests {
    @Test("from the list, Offline Maps is pushed with the map in view")
    func fromTheList() {
        let presentation = SheetPresentation(detent: SheetPresentation.compactDetent)

        presentation.showOfflineCountries()

        #expect(presentation.path == [.offlineCountries])
        #expect(presentation.detent == .medium)
    }

    @Test("over a hike, Offline Maps goes on top of it")
    func overAHike() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, title: "Ridge Line")
        let presentation = SheetPresentation(detent: .large)
        presentation.path = [.hike(hike)]

        presentation.showOfflineCountries()

        #expect(presentation.path == [.hike(hike), .offlineCountries])
        #expect(presentation.detent == .medium)
    }

    @Test("opened again from further in, it is come back to rather than pushed twice")
    func comesBack() {
        let presentation = SheetPresentation(detent: .medium)
        presentation.path = [.offlineCountries, .totals]

        presentation.showOfflineCountries()
        #expect(presentation.path == [.offlineCountries])

        presentation.showOfflineCountries()
        #expect(presentation.path == [.offlineCountries])
    }

    @Test("the list's search field raises the sheet to its full height")
    func searching() {
        let presentation = SheetPresentation(detent: .medium)
        presentation.path = [.offlineCountries]

        presentation.makeRoomToSearch()

        #expect(presentation.detent == .large)
        #expect(presentation.isFullHeight)
    }

    /// A turn moves the list between the sheet and the side panel, which
    /// builds it again; as its own state, the search and the order went.
    @Test("the list's search, order and open countries outlive a turn, and go with the screen")
    func listOutlivesATurn() {
        let presentation = SheetPresentation(detent: .medium)
        presentation.path = [.offlineCountries]
        let list = presentation.offlineCountriesList(for: .offlineCountries)
        list.query = "Bav"
        list.chosenSort = .largest
        list.expanded = ["US"]

        for layout in [SheetLayout.sidePanel, .bottomSheet] {
            presentation.layout = layout
            #expect(presentation.offlineCountriesList(for: .offlineCountries) === list)
            #expect(list.query == "Bav" && list.chosenSort == .largest && list.expanded == ["US"])
        }

        presentation.path.append(.totals)
        #expect(presentation.offlineCountriesList(for: .offlineCountries) === list, "a screen pushed over it keeps it")

        presentation.path = []
        presentation.path = [.offlineCountries]
        let next = presentation.offlineCountriesList(for: .offlineCountries)
        #expect(next !== list, "the next visit opens afresh")
        #expect(next.query.isEmpty && next.chosenSort == nil && next.expanded.isEmpty)
    }
}
