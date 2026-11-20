//
//  AlertTextSelectionTests.swift
//  OpenHikesTests
//
//  Which field ``AlertTextSelection`` selects when a field begins editing:
//  every text field in the app says so in the same notification, so the
//  rule is what keeps the selection to the alert's own field, as it opened.
//  That the selection is then made, and that an alert needs it, is
//  `RecordingUITests+Stop.swift`'s to show.
//

@testable import OpenHikes
import Testing

@Suite("Alert text selection")
struct AlertTextSelectionTests {
    private static let offered = "Ramsau – Wimbachklamm – 20 Nov 2026"

    @Test("the alert's field, holding what it opened with, is selected")
    func theOpeningFieldIsSelected() {
        #expect(AlertTextSelection.selects(Self.offered, opening: Self.offered, isPresented: true))
    }

    @Test("a field that begins editing with no alert up is left as it is")
    func aFieldWithNoAlertIsLeft() {
        #expect(!AlertTextSelection.selects(Self.offered, opening: Self.offered, isPresented: false))
    }

    /// The app came back to the front with a name half typed.
    @Test("a field that no longer holds what it opened with is left as it is")
    func anEditedFieldIsLeft() {
        #expect(!AlertTextSelection.selects("Ramsau", opening: Self.offered, isPresented: true))
        #expect(!AlertTextSelection.selects("", opening: Self.offered, isPresented: true))
    }

    @Test("an alert that opened with nothing selects nothing")
    func nothingOfferedSelectsNothing() {
        #expect(!AlertTextSelection.selects(nil, opening: nil, isPresented: true))
        #expect(!AlertTextSelection.selects("", opening: nil, isPresented: true))
    }
}
