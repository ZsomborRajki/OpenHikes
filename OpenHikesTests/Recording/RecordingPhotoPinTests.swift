//
//  RecordingPhotoPinTests.swift
//  OpenHikesTests
//
//  Where a photo taken mid-walk shows up: on the map, at once, rather than
//  only once the recording has been saved.
//
//  The anchoring half of this was already settled — ``PhotoTrailAnchor``
//  writes the walker's last accepted fix onto every photo taken from the
//  recording screen — but nothing drew them. Only ``HikePhotoSection``, on a
//  saved hike's detail screen, ever claimed the map's pins, so a picture taken
//  during the walk carried a perfectly good coordinate that nothing pointed
//  at until the hike was stopped and reopened.
//
//  Hosted in a real window rather than reasoned about, for the reason
//  `SheetQueryIsolationTests` is: the claim is made by SwiftUI's own
//  appear/disappear, and a test that called `PhotoMapPinController.attach`
//  itself would be asserting against its own arrangement rather than against
//  the screen's.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import SwiftData
import SwiftUI
import Testing

@MainActor
@Suite("Recording photo pins")
struct RecordingPhotoPinTests {
    private static let bend = CLLocationCoordinate2D(latitude: 47.6301, longitude: 12.8802)
    private static let summit = CLLocationCoordinate2D(latitude: 47.6412, longitude: 12.8955)
    private static let start = Date(timeIntervalSince1970: 1_700_000_000)
    /// The same budget ``settleDelegateHop(until:)`` uses, and generous for
    /// the same reason: it is only ever paid by a test that is about to fail.
    private static let settleBudget = Duration.seconds(5)

    @Test("the photos already taken on a walk stand on its live track")
    func theDraftsPhotosArePinnedWhileRecording() async throws {
        let scene = try Scene()
        let atBend = Self.photo(at: Self.bend, offset: 0)
        let loose = Self.photo(at: nil, offset: 60)
        let atSummit = Self.photo(at: Self.summit, offset: 120)
        for photo in [atBend, loose, atSummit] { scene.hike.addPhoto(photo) }
        scene.recorder.currentHike = scene.hike

        let window = try scene.host()
        defer { scene.dismiss(window) }
        await scene.settle(window, until: "the draft's photos to reach the map") {
            !scene.photoPins.pins.isEmpty
        }

        #expect(
            scene.photoPins.pins.map(\.id) == [atBend.id, atSummit.id],
            "a photo with no place on the trail has no pin, and does not displace its neighbours"
        )
    }

    /// The bug this file exists for. A picture taken twenty minutes into a
    /// walk is pinned twenty minutes along, and the walker should be able to
    /// see that without stopping the recording first.
    @Test("a photo taken during the walk appears on the map at once")
    func aPhotoTakenMidWalkIsPinnedImmediately() async throws {
        let scene = try Scene()
        let first = Self.photo(at: Self.bend, offset: 0)
        scene.hike.addPhoto(first)
        scene.recorder.currentHike = scene.hike

        let window = try scene.host()
        defer { scene.dismiss(window) }
        await scene.settle(window, until: "the first photo to reach the map") {
            scene.photoPins.pins.count == 1
        }

        let taken = Self.photo(at: Self.summit, offset: 1200)
        scene.hike.addPhoto(taken)
        await scene.settle(window, until: "the new photo to reach the map") {
            scene.photoPins.pins.count == 2
        }

        #expect(scene.photoPins.pins.map(\.id) == [first.id, taken.id])
    }

    /// "The same way it does with finished recordings" includes the way back:
    /// a pin is how the walker gets to the picture.
    @Test("a tapped pin opens the gallery for the draft being recorded")
    func aTappedPinOpensTheDraftsGallery() async throws {
        let scene = try Scene()
        let photo = Self.photo(at: Self.bend, offset: 0)
        scene.hike.addPhoto(photo)
        scene.recorder.currentHike = scene.hike

        let window = try scene.host()
        defer { scene.dismiss(window) }
        await scene.settle(window, until: "the photo to reach the map") {
            !scene.photoPins.pins.isEmpty
        }

        scene.photoPins.open(photo.id)

        let opened = try #require(scene.opened.last)
        #expect(opened.hike.id == scene.hike.id)
        #expect(opened.photo.id == photo.id)
    }

    /// Discarding a recording deletes the draft and its photo files with it,
    /// so a pin left standing would point at a picture that no longer exists.
    @Test("losing the draft takes its pins off the map")
    func clearingTheDraftClearsThePins() async throws {
        let scene = try Scene()
        scene.hike.addPhoto(Self.photo(at: Self.bend, offset: 0))
        scene.recorder.currentHike = scene.hike

        let window = try scene.host()
        defer { scene.dismiss(window) }
        await scene.settle(window, until: "the photo to reach the map") {
            !scene.photoPins.pins.isEmpty
        }

        scene.recorder.currentHike = nil

        await scene.settle(window, until: "the pins to leave the map") {
            scene.photoPins.pins.isEmpty
        }
    }

    /// The screen is reachable before Start is pressed, when there is no draft
    /// at all. The claim that follows is what makes the emptiness above a
    /// decision rather than a hierarchy that had not rendered yet.
    @Test("a recording that has not started yet pins nothing")
    func noDraftPinsNothing() async throws {
        let scene = try Scene()
        scene.hike.addPhoto(Self.photo(at: Self.bend, offset: 0))

        let window = try scene.host()
        defer { scene.dismiss(window) }
        await scene.settle(window, until: "the recording screen to lay out") {
            window.rootViewController?.view.subviews.isEmpty == false
        }
        #expect(scene.photoPins.pins.isEmpty)

        scene.recorder.currentHike = scene.hike
        await scene.settle(window, until: "starting the walk to publish its pins") {
            !scene.photoPins.pins.isEmpty
        }
    }

    private static func photo(
        at coordinate: CLLocationCoordinate2D?,
        offset: TimeInterval
    ) -> HikePhoto {
        HikePhoto(
            capturedAt: start.addingTimeInterval(offset),
            coordinate: coordinate
        )
    }

    /// One recording screen, its recorder, and the map's pin controller.
    ///
    /// A class so the `onOpenPhoto` closure handed to the view can record what
    /// it was given — the view is a value type SwiftUI copies freely, and the
    /// callback has to outlive every one of those copies.
    @MainActor
    private final class Scene {
        let container: ModelContainer
        let hike: Hike
        let recorder: HikeRecorder
        let photoPins = PhotoMapPinController()
        private(set) var opened: [(hike: Hike, photo: HikePhoto)] = []

        init() throws {
            container = try Fixture.modelContainer()
            hike = Fixture.hike(in: container.mainContext) { draft in
                draft.isRecording = true
            }
            recorder = HikeRecorder(container: container, automaticallyRecovers: false)
        }

        /// The window is built from the host app's own scene — both unit
        /// bundles are app-hosted, so there is always one — because
        /// `UIWindow(frame:)` is deprecated and a scene-less window never lays
        /// out.
        func host() throws -> UIWindow {
            let scene = try #require(
                UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first,
                "app-hosted tests run inside the app, which has a scene"
            )
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.rootViewController = UIHostingController(
                rootView: RecordingView(
                    recorder: recorder,
                    mapController: MapController(),
                    photoPins: photoPins,
                    onSaved: { _ in /* unused */ },
                    onDiscarded: { _ in /* unused */ },
                    onOpenPhoto: { [weak self] hike, photo in
                        self?.opened.append((hike, photo))
                    }
                )
                    .modelContainer(container)
            )
            window.isHidden = false
            window.layoutIfNeeded()
            return window
        }

        /// Pumps SwiftUI until `condition` holds.
        ///
        /// Both halves are needed and neither is enough on its own: a yield
        /// never makes a hosted hierarchy lay out, and `layoutIfNeeded()`
        /// never lets the main actor run the work a body scheduled. Waiting on
        /// a named effect rather than a fixed number of passes is the same
        /// argument ``settleDelegateHop(until:)`` makes — a pass count buys an
        /// amount of progress that depends on how loaded the machine is.
        func settle(
            _ window: UIWindow,
            until description: Comment,
            sourceLocation: SourceLocation = #_sourceLocation,
            condition: @MainActor () -> Bool
        ) async {
            let deadline = ContinuousClock.now + RecordingPhotoPinTests.settleBudget
            while ContinuousClock.now < deadline {
                await Task.yield()
                window.rootViewController?.view.setNeedsLayout()
                window.layoutIfNeeded()
                if condition() { return }
                guard await settlePollTick() else { break }
            }
            Issue.record(
                Comment(rawValue: "Timed out waiting for \(description.rawValue)."),
                sourceLocation: sourceLocation
            )
        }

        /// Teardown, for the same reason `MapCoordinatorTests` detaches its
        /// map: a hosted window left behind keeps a live hierarchy — and, here,
        /// a live claim on the map's pins — alive across the rest of the run.
        func dismiss(_ window: UIWindow) {
            window.isHidden = true
            window.rootViewController = nil
        }
    }
}
