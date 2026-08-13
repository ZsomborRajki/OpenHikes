//
//  SheetRouteTests.swift
//  OpenTrailsTests
//

import Foundation
@testable import OpenTrails
import Testing

@Suite("Sheet route")
struct SheetRouteTests {
    @Test("reopening recording pops anything pushed above it")
    func reopensExistingRecording() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        var path: [SheetRoute] = [.recording, .hike(hike)]

        SheetRoute.reopenRecording(in: &path)

        #expect(path == [.recording])
    }

    @Test("opening recording replaces finished-trail navigation")
    func recordingReplacesFinishedTrail() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        var path: [SheetRoute] = [.hike(hike)]

        SheetRoute.reopenRecording(in: &path)

        #expect(path == [.recording])
    }

    @Test("opening recording selects its durable hike entry")
    func recordingSelectsItsHike() throws {
        let context = try Fixture.modelContext()
        let previous = Fixture.hike(in: context, title: "Imported")
        let recording = Fixture.hike(in: context, title: "Morning Hike", route: []) { hike in
            hike.isRecording = true
        }
        var selectedHike: Hike? = previous
        var path: [SheetRoute] = [.hike(previous)]

        SheetRoute.openRecording(
            hike: recording,
            selectedHike: &selectedHike,
            in: &path
        )

        #expect(selectedHike?.id == recording.id)
        #expect(path == [.recording])
    }
}

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
