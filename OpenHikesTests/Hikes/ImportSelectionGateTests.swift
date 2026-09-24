//
//  ImportSelectionGateTests.swift
//  OpenHikesTests
//
//  "Import selection gate", split out of SheetRouteTests.swift so that a file
//  declares one @Suite.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@Suite("Import selection gate")
struct ImportSelectionGateTests {
    @Test("an unchanged import may select its persisted hike")
    func currentImportMaySelect() {
        let gate = ImportSelectionGate()
        let token = gate.token(selectedHikeID: nil, path: [])

        #expect(
            gate.permits(
                token: token,
                selectedHikeID: nil,
                path: [],
                currentRecordingHikeID: nil,
                recordingPresented: false
            )
        )
    }

    @Test("a newer selection or navigation action invalidates the import")
    func newerActionWins() {
        var gate = ImportSelectionGate()
        let staleToken = gate.token(selectedHikeID: nil, path: [])

        gate.invalidate()

        #expect(
            !gate.permits(
                token: staleToken,
                selectedHikeID: nil,
                path: [],
                currentRecordingHikeID: nil,
                recordingPresented: false
            )
        )
    }

    @Test("recording ownership prevents an import from stealing selection")
    func recordingWins() {
        let gate = ImportSelectionGate()
        let token = gate.token(selectedHikeID: nil, path: [])

        #expect(
            !gate.permits(
                token: token,
                selectedHikeID: nil,
                path: [],
                currentRecordingHikeID: UUID(),
                recordingPresented: false
            )
        )
        #expect(
            !gate.permits(
                token: token,
                selectedHikeID: nil,
                path: [],
                currentRecordingHikeID: nil,
                recordingPresented: true
            )
        )
    }

    @Test("a directly changed selection is rejected before SwiftUI callbacks run")
    func changedContextWinsImmediately() {
        let gate = ImportSelectionGate()
        let token = gate.token(selectedHikeID: nil, path: [])

        #expect(
            !gate.permits(
                token: token,
                selectedHikeID: UUID(),
                path: [],
                currentRecordingHikeID: nil,
                recordingPresented: false
            )
        )
    }
}
