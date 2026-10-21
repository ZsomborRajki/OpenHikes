//
//  HikePlaceAdderSessionTests.swift
//  OpenHikesTests
//
//  What *Add Place*'s form holds, kept apart from the view a turn of the
//  phone replaces: a frame off the camera waits in it until *Add*, can be
//  taken back out, and reaches the form whichever host is drawing it.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Suite("Add Place's held form")
struct HikePlaceAdderSessionTests {
    /// A frame the way the camera hands one over, landscape like the one in
    /// the report. `nil` off UIKit, where there is no camera path to test.
    nonisolated private static func frame() -> CapturedFrame? {
        #if canImport(UIKit)
        let size = CGSize(width: 64, height: 48)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return CapturedFrame(image: image)
        #else
        return nil
        #endif
    }

    @Test("a frame off the camera is held with its thumbnail, and Add waits while it is read")
    func capturedFrameIsHeld() async throws {
        let frame = try #require(Self.frame())
        let session = HikePlaceAdderSession()

        let staging = session.stage(frame)
        #expect(session.stagingCount == 1, "Add waits for a frame still being read")
        await staging.value

        #expect(session.stagingCount == 0)
        #expect(session.photos.count == 1)
        let held = try #require(session.photos.first)
        #expect(held.thumbnail != nil)
        guard case .captured = held.source else {
            Issue.record("a frame off the camera is held as a capture, to be filed as one")
            return
        }
    }

    @Test("a held photograph is taken back out, and the rest keep their order")
    func heldPhotographIsRemoved() async throws {
        let frame = try #require(Self.frame())
        let session = HikePlaceAdderSession()
        for _ in 0..<3 {
            await session.stage(frame).value
        }
        let held = session.photos.map(\.id)

        session.remove(held[1])

        #expect(session.photos.map(\.id) == [held[0], held[2]])
    }

    /// A turn replaces the form while the camera it presented is up. Whatever
    /// that camera hands back reaches the form the new host draws, because
    /// both forms are handed the same session — and the new form presents
    /// the camera again.
    @Test("a picture from a camera opened before a turn reaches the form the new host draws")
    func pictureOutlivesTheFormThatOpenedTheCamera() async throws {
        let frame = try #require(Self.frame())
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let route = SheetRoute.newPlace(hike, HikePlaceSpot(CLLocationCoordinate2D(latitude: 47.6, longitude: 12.9)))
        let presentation = SheetPresentation()
        presentation.path = [.recording, route]
        let opener = presentation.placeAdder(for: route)
        opener.draft.name = "Lookout"
        opener.capture.showCamera = true

        presentation.layout = .sidePanel
        let shown = presentation.placeAdder(for: route)
        #expect(shown.capture.showCamera, "the new form presents the camera again")
        await opener.stage(frame).value

        #expect(shown.photos.count == 1, "the picture is in the strip the new form draws")
        #expect(shown.draft.name == "Lookout")
    }
}
