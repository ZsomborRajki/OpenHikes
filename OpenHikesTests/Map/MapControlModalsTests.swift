//
//  MapControlModalsTests.swift
//  OpenHikesTests
//
//  Which sheet puts up what the map's own controls open: *Map Modes*, the
//  refused location button's alert and the forecast. The map sheet's contents
//  do, unless a place card is up over them. The map sheet is already
//  presenting the card, so a sheet asked for from under it waited until the
//  card was closed, and the alert took the card down (#1403).
//
//  Which view really presents is resolved only by a running app, so the cards
//  themselves are `MapModesUITests`' and `MapScreenAlertUITests`'. What is
//  tested here is the decision they follow.
//

@testable import OpenHikes
import SwiftUI
import Testing

@MainActor
@Suite("Map control modals")
struct MapControlModalsTests {
    @Test("nothing is presented until a control asks")
    func startsDown() {
        let modals = MapControlModals()

        for control in Control.all(of: modals) {
            #expect(!modals.binding(control.flag, for: .mapSheet).wrappedValue, "\(control.name)")
            #expect(!modals.binding(control.flag, for: .card).wrappedValue, "\(control.name)")
        }
    }

    @Test("the map sheet presents each of them while no card is up")
    func theMapSheetPresents() {
        let modals = MapControlModals()

        for control in Control.all(of: modals) {
            control.raise()
            #expect(modals.binding(control.flag, for: .mapSheet).wrappedValue, "\(control.name)")
        }
    }

    @Test("a card that is up presents each of them, and the map sheet stands down")
    func aCardPresentsOverItself() {
        let modals = MapControlModals()
        modals.cardDidAppear()

        for control in Control.all(of: modals) {
            control.raise()
            #expect(modals.binding(control.flag, for: .card).wrappedValue, "\(control.name)")
            #expect(
                !modals.binding(control.flag, for: .mapSheet).wrappedValue,
                "\(control.name): a sheet would wait for the card to close, and an alert would take it down"
            )
        }
    }

    @Test("once the card has gone, the map sheet presents again")
    func theMapSheetTakesOverAgain() {
        let modals = MapControlModals()
        modals.cardDidAppear()
        modals.cardDidDisappear()

        modals.locationAccess.show()
        #expect(modals.isPresenter(.mapSheet))
        #expect(modals.binding(modals.locationAccess.isShowingBinding, for: .mapSheet).wrappedValue)
    }

    @Test("a card that goes twice is counted once")
    func theCountNeverGoesBelowNone() {
        let modals = MapControlModals()
        modals.cardDidAppear()
        modals.cardDidDisappear()
        modals.cardDidDisappear()
        modals.cardDidAppear()

        #expect(!modals.isPresenter(.mapSheet), "one card is up")
    }

    @Test("over a card, Offline Maps closes the card and opens once it has gone")
    func offlineMapsOverACard() {
        let modals = MapControlModals()
        var opened = 0
        modals.mapModes.onOpenOfflineMaps { opened += 1 }
        modals.cardDidAppear()
        modals.mapModes.present()

        modals.mapModes.dismissOpeningOfflineMaps()
        modals.mapModesDidDismiss()
        #expect(modals.isClosingCard)
        #expect(opened == 0, "a push under the card lands behind it")

        modals.cardDidDisappear()
        #expect(opened == 1)
        #expect(!modals.isClosingCard)
    }

    @Test("Map Modes closed any other way over a card leaves the card up")
    func closingMapModesOverACard() {
        let modals = MapControlModals()
        var opened = 0
        modals.mapModes.onOpenOfflineMaps { opened += 1 }
        modals.cardDidAppear()
        modals.mapModes.present()

        modals.mapModes.dismiss()
        modals.mapModesDidDismiss()
        #expect(!modals.isClosingCard)

        modals.cardDidDisappear()
        #expect(opened == 0)
    }

    @Test("with no card up, Offline Maps opens as Map Modes goes")
    func offlineMapsWithNoCard() {
        let modals = MapControlModals()
        var opened = 0
        modals.mapModes.onOpenOfflineMaps { opened += 1 }
        modals.mapModes.present()

        modals.mapModes.dismissOpeningOfflineMaps()
        modals.mapModesDidDismiss()

        #expect(opened == 1)
        #expect(!modals.isClosingCard)
    }

    @Test("closing one, from either presenter, lowers its flag and no other")
    func aBindingWritesItsFlag() {
        let modals = MapControlModals()
        modals.cardDidAppear()
        modals.mapModes.present()
        modals.locationAccess.show()

        modals.binding(modals.locationAccess.isShowingBinding, for: .card).wrappedValue = false
        #expect(!modals.locationAccess.isShowing)
        #expect(modals.mapModes.isPresented, "closing the alert leaves Map Modes asked for")

        modals.cardDidDisappear()
        modals.binding(modals.mapModes.isPresentedBinding, for: .mapSheet).wrappedValue = false
        #expect(!modals.mapModes.isPresented)
    }
}

/// One of what the map's controls open: what its control does to raise it,
/// and the flag that raises.
private struct Control {
    let name: String
    let raise: () -> Void
    let flag: Binding<Bool>

    static func all(of modals: MapControlModals) -> [Self] {
        [
            Self(name: "Map Modes", raise: modals.mapModes.present, flag: modals.mapModes.isPresentedBinding),
            Self(
                name: "the location alert",
                raise: modals.locationAccess.show,
                flag: modals.locationAccess.isShowingBinding
            ),
            Self(
                name: "the forecast",
                raise: modals.weatherDetail.present,
                flag: modals.weatherDetail.isPresentedBinding
            ),
        ]
    }
}
