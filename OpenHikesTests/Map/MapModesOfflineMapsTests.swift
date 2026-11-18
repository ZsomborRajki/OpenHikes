//
//  MapModesOfflineMapsTests.swift
//  OpenHikesTests
//
//  *Map Modes*' way to *Offline Maps*. The list is pushed onto the map
//  sheet, and a push made while *Map Modes* is still going down lands
//  behind it, so the push waits for the sheet's dismissal and is made only
//  when the row asked for it.
//

@testable import OpenHikes
import Testing

@MainActor
@Suite("Map Modes: Offline Maps")
struct MapModesOfflineMapsTests {
    @Test("the row closes Map Modes and opens the list once it has gone")
    func opensAfterDismissal() {
        let presentation = MapModesPresentation()
        var opened = 0
        presentation.onOpenOfflineMaps { opened += 1 }
        presentation.present()

        presentation.dismissOpeningOfflineMaps()
        #expect(!presentation.isPresented)
        #expect(opened == 0)

        presentation.didDismiss()
        #expect(opened == 1)
        // A second dismissal, of a later visit closed with its button.
        presentation.present()
        presentation.dismiss()
        presentation.didDismiss()
        #expect(opened == 1)
    }

    @Test("closing Map Modes any other way opens nothing")
    func plainDismissal() {
        let presentation = MapModesPresentation()
        var opened = 0
        presentation.onOpenOfflineMaps { opened += 1 }
        presentation.present()

        presentation.dismiss()
        presentation.didDismiss()

        #expect(opened == 0)
    }
}
