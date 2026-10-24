//
//  CommunitySharePhotoLookupTests.swift
//  OpenHikesTests
//
//  The disk lookup both send forms keep their count from,
//  ``SwiftUI/View/findsPhotosOnThisDevice(among:store:into:)``, hosted in a
//  window and driven the way a form drives it.
//
//  A form asks the disk which of its photographs have their files here, then
//  works the count, the cap and the tiles out from that one answer as the
//  hiker strikes pictures off. Asked only when the form appeared, the answer
//  never learned of a picture that landed while the form was open, as one
//  from a library import still running does. The tally then said 0, the
//  contribution form held its Send button and the footnote put the new
//  picture on another device, while the send took it. The lookup is keyed on
//  the photographs offered, so a new one is asked about.
//
//  The modifier is body code, and its file is on the coverage exclusions, so
//  this suite hosts it rather than calling it.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftUI
import Testing

@MainActor
@Suite("Community share photo lookup")
struct CommunitySharePhotoLookupTests {
    @Test("a photograph that lands while the form is open is asked about")
    func aPhotoThatLandsWhileTheFormIsOpenIsCounted() async throws {
        let context = try Fixture.modelContext()
        let sandbox = PhotoStoreSandbox()
        let hike = Fixture.hike(in: context)
        let first = try #require(await Self.storedPhoto(at: 0, in: sandbox))
        hike.photos.append(first)
        let state = LookupState()
        let window = try Self.host(LookupProbe(hike: hike, store: sandbox.store, state: state))
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        await settleDelegateHop(until: "the disk answered for the photograph the form opened with") {
            state.files == .answered([first.id])
        }
        // Struck off on the strip: the choice moves, and the photographs
        // offered do not.
        state.excluded = [first.id]

        // In the order an import lands a picture: its file, then its row.
        let landed = try #require(await Self.storedPhoto(at: 1, in: sandbox))
        hike.photos.append(landed)

        await settleDelegateHop(until: "the disk answered for the photograph that landed") {
            state.files == .answered([first.id, landed.id])
        }
        let tally = CommunitySharePhotoTally(
            offered: CommunityPublisher.shareablePhotos(of: hike),
            excluding: state.excluded,
            files: state.files
        )
        let sent = await CommunityPublisher.sendablePhotos(
            of: hike,
            excluding: state.excluded,
            store: sandbox.store
        )
        #expect(sent.map(\.id) == [landed.id])
        #expect(tally.count == sent.count, "the number under the strip is the number that goes")
        #expect(tally.unsendableCount == 0, "and the picture that landed is not put on another device")
    }

    /// A photograph whose file is on this device, written the way an import
    /// writes one: before any row points at it.
    private static func storedPhoto(at index: Int, in sandbox: PhotoStoreSandbox) async -> HikePhoto? {
        let data = PhotoDiscoveryFixture.sampleImageData()
        let store = sandbox.store
        let captured = Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60)
        return await Task.detached(priority: .userInitiated) {
            store.store(
                data,
                capturedAt: captured,
                coordinate: CLLocationCoordinate2D(latitude: 47.6, longitude: 12.8)
            )
        }.value
    }

    private static func host(_ view: some View) throws -> UIWindow {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }
}

/// What a form holds in its `@State` for this: the choice, and the disk's
/// answer.
@Observable
private final class LookupState {
    var excluded: Set<UUID> = []
    var files: CommunityPhotoFiles = .unasked
}

/// A send form cut down to what the lookup sees: the strip's list read once a
/// pass and handed down, in a body that runs again when the choice moves.
private struct LookupProbe: View {
    let hike: Hike
    let store: HikePhotoStore
    @Bindable var state: LookupState

    var body: some View {
        let offered = CommunityPublisher.shareablePhotos(of: hike)
        Text(verbatim: "\(offered.count) offered, \(state.excluded.count) struck off")
            .findsPhotosOnThisDevice(among: offered, store: store, into: $state.files)
    }
}
