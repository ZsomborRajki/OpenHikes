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

    /// *Places Nearby* is the recording's screen one push further in, so an
    /// import finishing under it is landing on the walk.
    @Test("places nearby is the recording's screen")
    @MainActor
    func placesNearbyIsTheRecording() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)

        #expect(ImportSelectionGate().destination(for: [.recording, .placesNearby(hike)]) == .recording)
    }

    /// A tile of a Commons group's grid opens a photograph over it, and an
    /// import finishing after that push must not take the map.
    @Test("a Commons group's grid and a photograph opened over it are different screens")
    func commonsGroupIsItsOwnScreen() {
        let pages = (1...2).compactMap { URL(string: "https://commons.wikimedia.org/wiki/File:\($0).jpg") }
        let photos = pages.map { page in
            CommonsPhoto(
                pin: CommunityPhotoPin(capturedAt: .distantPast, coordinate: nil),
                fileURL: URL(filePath: "/tmp/\(page.lastPathComponent)"),
                credit: CommonsPhotoCredit(
                    author: nil,
                    license: HikePhotoLicense(name: "CC0", url: nil, sourceURL: page)
                )
            )
        }
        let gate = ImportSelectionGate()
        let grid: [SheetRoute] = [.commonsPhotos(photos)]
        let token = gate.token(selectedHikeID: nil, path: grid)

        #expect(gate.destination(for: grid) == .commonsPhotos(pages))
        #expect(
            !gate.permits(
                token: token,
                selectedHikeID: nil,
                path: grid + [.commonsPhoto(photos[0])],
                currentRecordingHikeID: nil,
                recordingPresented: false
            )
        )
    }

    /// The gallery a Commons photograph's screen pushes is that screen one
    /// push further in, as a shared hike's gallery is its preview's: an
    /// import finishing under it still lands on the photograph.
    @Test("a Commons photograph's gallery is the photograph's screen")
    func commonsGalleryIsThePhotograph() throws {
        let page = try #require(URL(string: "https://commons.wikimedia.org/wiki/File:1.jpg"))
        let photo = CommonsPhoto(
            pin: CommunityPhotoPin(capturedAt: .distantPast, coordinate: nil),
            fileURL: URL(filePath: "/tmp/1.jpg"),
            credit: CommonsPhotoCredit(author: nil, license: HikePhotoLicense(name: "CC0", url: nil, sourceURL: page))
        )
        let gate = ImportSelectionGate()
        let screen: [SheetRoute] = [.commonsPhoto(photo)]
        let token = gate.token(selectedHikeID: nil, path: screen)
        let gallery = screen + [.commonsGallery([photo], photo)]

        #expect(gate.destination(for: gallery) == .commonsPhoto(page))
        #expect(
            gate.permits(
                token: token,
                selectedHikeID: nil,
                path: gallery,
                currentRecordingHikeID: nil,
                recordingPresented: false
            )
        )
    }
}
