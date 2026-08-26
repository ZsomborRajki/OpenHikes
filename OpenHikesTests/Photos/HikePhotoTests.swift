//
//  HikePhotoTests.swift
//  OpenHikesTests
//
//  The metadata side: what a `Hike` does with the photos attached to it, and
//  what the pill's controller does when two screens overlap.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Hike photos")
struct HikePhotoTests {
    private static let baseTimestamp: TimeInterval = 1_750_000_000
    private static let minute: TimeInterval = 60
    private static let latitude: Double = 47.63
    private static let longitude: Double = 12.86

    private static func photo(minutesIn offset: Double) -> HikePhoto {
        HikePhoto(
            capturedAt: Date(timeIntervalSince1970: baseTimestamp + offset * minute)
        )
    }

    @Test("a hike starts with no photos and says so")
    func startsEmpty() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)

        #expect(hike.hasPhotos == false)
        #expect(hike.orderedPhotos.isEmpty)
    }

    @Test("photos read back oldest first regardless of the order they arrived")
    func ordersByCaptureTime() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        // An import hands several assets over at once and in no useful order,
        // which is exactly the case `orderedPhotos` exists for.
        let later = Self.photo(minutesIn: 30)
        let earlier = Self.photo(minutesIn: 5)
        hike.addPhoto(later)
        hike.addPhoto(earlier)

        #expect(hike.orderedPhotos.map(\.id) == [earlier.id, later.id])
    }

    @Test("two photos captured in the same instant still have a stable order")
    func tiesBreakDeterministically() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let first = Self.photo(minutesIn: 0)
        let second = Self.photo(minutesIn: 0)
        hike.addPhoto(first)
        hike.addPhoto(second)

        // Whatever the order is, asking twice has to give the same answer —
        // the viewer's "next" button pages through this array.
        let firstPass = hike.orderedPhotos.map(\.id)
        let secondPass = hike.orderedPhotos.map(\.id)
        #expect(firstPass == secondPass)
        let expected = [first, second]
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map(\.id)
        #expect(hike.orderedPhotos.map(\.id) == expected)
    }

    @Test("adding the same photo twice adds it once")
    func addIsIdempotent() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let photo = Self.photo(minutesIn: 0)

        hike.addPhoto(photo)
        hike.addPhoto(photo)

        #expect(hike.photos.count == 1)
    }

    @Test("removing a photo hands it back so its files can be deleted")
    func removeReturnsThePhoto() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let photo = Self.photo(minutesIn: 0)
        hike.addPhoto(photo)

        let removed = hike.removePhoto(id: photo.id)

        #expect(removed?.id == photo.id)
        #expect(hike.hasPhotos == false)
    }

    @Test("removing a photo that isn't there reports nothing to delete")
    func removeUnknownReturnsNil() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)

        #expect(hike.removePhoto(id: UUID()) == nil)
    }

    @Test("an anchored photo keeps the coordinate it was pinned to")
    func anchorRoundTrips() {
        let coordinate = CLLocationCoordinate2D(
            latitude: Self.latitude,
            longitude: Self.longitude
        )
        let photo = HikePhoto(coordinate: coordinate)

        #expect(photo.isAnchored)
        #expect(photo.coordinate?.latitude == coordinate.latitude)
        #expect(photo.coordinate?.longitude == coordinate.longitude)
    }

    @Test("the file name carries the format the bytes really were")
    func fileNameUsesStoredExtension() {
        let photo = HikePhoto(pathExtension: "heic")

        #expect(photo.fileName == "\(photo.id.uuidString).heic")
        // The thumbnail is re-derivable, so it is always JPEG regardless —
        // under the extension `ImageDataFormat.detect(in:)` gives JPEG bytes,
        // which is `jpeg` rather than `jpg`. The two must not drift: one is
        // what a thumbnail is written as, the other is what it is looked up
        // by.
        #expect(photo.thumbnailFileName == "\(photo.id.uuidString).jpeg")
        #expect(ImageDataFormat.jpeg.pathExtension == "jpeg")
    }
}

@Suite("Photo capture controller")
struct PhotoCaptureControllerTests {
    @Test("no screen attached means no camera pill")
    func startsUnavailable() {
        let controller = PhotoCaptureController()

        #expect(controller.isAvailable == false)
        #expect(controller.currentSubject() == nil)
    }

    @Test("an attached screen offers the pill and its anchor")
    func attachOffersSubject() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let controller = PhotoCaptureController()
        let coordinate = CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86)

        controller.attach(to: hike) { coordinate }

        #expect(controller.isAvailable)
        let subject = try #require(controller.currentSubject())
        #expect(subject.hike.id == hike.id)
        #expect(subject.coordinate?.latitude == coordinate.latitude)
    }

    @Test("the anchor is read at the shutter, not at attach time")
    func anchorIsResolvedLate() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let controller = PhotoCaptureController()
        // Stands in for the walker moving between opening the camera and
        // taking the picture.
        let position = Position()
        controller.attach(to: hike) { position.coordinate }

        #expect(controller.currentSubject()?.coordinate == nil)
        position.coordinate = CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86)

        #expect(controller.currentSubject()?.coordinate != nil)
    }

    @Test("an outgoing screen cannot cancel the one that replaced it")
    func staleDetachIsIgnored() throws {
        let context = try Fixture.modelContext()
        let outgoing = Fixture.hike(in: context, title: "Recording")
        let incoming = Fixture.hike(in: context, title: "Saved")
        let controller = PhotoCaptureController()

        // SwiftUI's real ordering: the new screen appears, then the old one
        // disappears. Stopping a recording lands on that recording's own
        // detail screen, so the two can even be the same hike.
        let firstToken = controller.attach(to: outgoing) { nil }
        controller.attach(to: incoming) { nil }
        controller.detach(token: firstToken)

        #expect(controller.isAvailable)
        #expect(controller.currentSubject()?.hike.id == incoming.id)
    }

    @Test("the last screen to leave takes the pill with it")
    func matchingDetachWithdrawsPill() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let controller = PhotoCaptureController()

        let token = controller.attach(to: hike) { nil }
        controller.detach(token: token)

        #expect(controller.isAvailable == false)
        #expect(controller.currentSubject() == nil)
    }

    @Test("each tap is a distinct request")
    func requestsAdvanceTokens() throws {
        let context = try Fixture.modelContext()
        let controller = PhotoCaptureController()
        controller.attach(to: Fixture.hike(in: context)) { nil }
        let camera = controller.cameraRequest
        let library = controller.libraryRequest

        controller.requestCamera()
        controller.requestLibrary()

        #expect(controller.cameraRequest != camera)
        #expect(controller.libraryRequest != library)
    }

    /// The last line of the defence the two tests below describe.
    ///
    /// A tap can only land on a pill that is on screen, but it can land on the
    /// same frame the pill is withdrawn in — and a picker opened by one has
    /// nothing to file into by the time the user has chosen a photo, which is
    /// a modal that appears and then does nothing at all.
    @Test("a tap with no screen behind it raises no request")
    func requestsAreRefusedWithoutASubject() {
        let controller = PhotoCaptureController()
        let camera = controller.cameraRequest
        let library = controller.libraryRequest

        controller.requestCamera()
        controller.requestLibrary()

        #expect(controller.cameraRequest == camera)
        #expect(controller.libraryRequest == library)
    }

    /// The bug this rule exists for: SwiftUI runs the pop animation first and
    /// calls the leaving screen's `onDisappear` after it, so the claim alone
    /// leaves the pill over the map — opaque and tappable — for the whole of a
    /// back navigation out of a hike.
    @Test("emptying the sheet's stack withdraws the pill before the claim does")
    func anEmptyStackWithdrawsThePill() throws {
        let context = try Fixture.modelContext()
        let controller = PhotoCaptureController()
        controller.attach(to: Fixture.hike(in: context)) { nil }

        controller.setHostScreenPresent(false)

        #expect(controller.isAvailable == false, "the pop has started; the pill goes now")
        controller.requestLibrary()
        #expect(controller.libraryRequest == 0, "and it cannot be tapped on the way out")
    }

    /// Which is why the sheet reports the *state* of its path rather than the
    /// pop as an event: a back-swipe the user changes their mind about never
    /// disappears the screen, so an event would withdraw the pill for good.
    @Test("a back-swipe that is abandoned brings the pill back")
    func anAbandonedPopRestoresThePill() throws {
        let context = try Fixture.modelContext()
        let controller = PhotoCaptureController()
        controller.attach(to: Fixture.hike(in: context)) { nil }

        controller.setHostScreenPresent(false)
        controller.setHostScreenPresent(true)

        #expect(controller.isAvailable)
        #expect(controller.currentSubject() != nil)
    }

    @Test("a screen that arrives while the stack is reported empty stays hidden")
    func aClaimCannotOverrideAnEmptyStack() throws {
        let context = try Fixture.modelContext()
        let controller = PhotoCaptureController()

        controller.setHostScreenPresent(false)
        controller.attach(to: Fixture.hike(in: context)) { nil }

        #expect(controller.isAvailable == false)
    }
}

/// A coordinate a test can move after handing out the closure that reads it.
@MainActor
private final class Position {
    var coordinate: CLLocationCoordinate2D?
}
