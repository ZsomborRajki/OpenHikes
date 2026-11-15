//
//  MapModesPresentationTests.swift
//  OpenHikesTests
//
//  Which sheet puts *Map Modes* up. The map sheet's contents do, unless a
//  place card is up over them: the map sheet is already presenting the card,
//  so a sheet asked for from under it waits until the card is closed.
//

@testable import OpenHikes
import SwiftUI
import Testing

@MainActor
@Suite("Map Modes presentation")
struct MapModesPresentationTests {
    @Test("nothing is presented until the button asks")
    func startsDown() {
        let presentation = MapModesPresentation()

        #expect(!presentation.isPresented(by: .mapSheet))
        #expect(!presentation.isPresented(by: .card))
    }

    @Test("the map sheet presents it while no card is up")
    func theMapSheetPresents() {
        let presentation = MapModesPresentation()

        presentation.present()
        #expect(presentation.isPresented(by: .mapSheet))

        presentation.dismiss()
        #expect(!presentation.isPresented(by: .mapSheet))
    }

    @Test("a card that is up presents it, and the map sheet stands down")
    func aCardPresentsOverItself() {
        let presentation = MapModesPresentation()
        presentation.cardDidAppear()

        presentation.present()
        #expect(presentation.isPresented(by: .card))
        #expect(!presentation.isPresented(by: .mapSheet), "it would wait, and come up when the card closed")
    }

    @Test("once the card has gone, the map sheet presents again")
    func theMapSheetTakesOverAgain() {
        let presentation = MapModesPresentation()
        presentation.cardDidAppear()
        presentation.cardDidDisappear()

        presentation.present()
        #expect(presentation.isPresented(by: .mapSheet))
    }

    @Test("a card that goes twice is counted once")
    func theCountNeverGoesBelowNone() {
        let presentation = MapModesPresentation()
        presentation.cardDidAppear()
        presentation.cardDidDisappear()
        presentation.cardDidDisappear()
        presentation.cardDidAppear()

        presentation.present()
        #expect(!presentation.isPresented(by: .mapSheet), "one card is up")
    }

    @Test("closing the sheet, from either presenter, lowers the one flag")
    func aBindingWritesTheFlag() {
        let presentation = MapModesPresentation()
        presentation.cardDidAppear()
        presentation.present()

        presentation.binding(for: .card).wrappedValue = false
        #expect(!presentation.isPresented)

        presentation.cardDidDisappear()
        presentation.present()
        presentation.binding(for: .mapSheet).wrappedValue = false
        #expect(!presentation.isPresented)
    }
}
