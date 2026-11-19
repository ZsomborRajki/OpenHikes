//
//  SheetOfflineCountriesTests.swift
//  OpenHikesTests
//
//  Where *Offline Maps* lands in the sheet. It is opened from *Map Modes*
//  over whatever the sheet shows, so it is pushed on top of that, with the
//  sheet at its middle so the outlines behind it are in view; and opened
//  again while it is already further down, it is come back to rather than
//  pushed twice. Its search field takes the whole sheet.
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
}
