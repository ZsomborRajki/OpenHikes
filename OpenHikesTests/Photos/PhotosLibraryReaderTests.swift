//
//  PhotosLibraryReaderTests.swift
//  OpenHikesTests
//
//  "Photo library reader", split out of PhotoLibraryReaderTests.swift so that
//  a file declares one @Suite. That file's header still holds the context the
//  two share.
//

import Foundation
@testable import OpenHikes
import Photos
import Testing

@Suite("Photo library reader")
@MainActor
struct PhotosLibraryReaderTests {
    private static let thumbnailPixelSize = 64
    /// Shaped like a real one — `UUID/L0/001` — so the fetch is rejected for
    /// not existing rather than for being malformed.
    private static let identifierNoLibraryHas =
        "00000000-0000-0000-0000-0000000000FF/L0/001"

    /// The refusal that makes the limited-access button safe to press from
    /// anywhere. `presentLimitedLibraryPicker(from:)` on a controller that is
    /// not on screen does nothing *and never calls its completion handler*, so
    /// the `await` in the flow above would never return — a button that hangs
    /// its own screen. The guard turns that into an immediate return and a log
    /// line.
    ///
    /// The assertion is that the call finishes at all: if the guard is removed
    /// this test does not fail, it hangs, because the picker's completion
    /// handler is the only thing that would resume it. That is an unpleasant
    /// failure mode to rely on, which is why the same refusal is pinned
    /// deterministically one level down in `LimitedLibraryPresenterTests` —
    /// there the answer is a `nil` that can simply be asserted.
    @Test("the picker is not raised when there is no screen to raise it from")
    func thePickerIsSkippedWithNoScreen() async {
        let reader = PhotosLibraryReader()
        let presenter = LimitedLibraryPresenter()

        #expect(presenter.presentingViewController == nil)
        await reader.presentLimitedLibraryPicker(from: presenter)
    }

    /// The two image requests share a guard, and it is the guard rather than
    /// the request that this app can get wrong: an identifier read back from a
    /// `Hike` can outlive the asset it names — the user deletes the photograph
    /// in Photos — and a fetch that returns nothing has to become `nil` rather
    /// than a request against a missing asset.
    ///
    /// Runs against the host's real library, which is empty, and on a machine
    /// that has never granted access is also unreadable. Neither changes what
    /// is under test: `fetchAssets(withLocalIdentifiers:)` answers with an
    /// empty result rather than prompting when the app has no permission, so
    /// the fetch misses either way and the guard in front of it is what
    /// answers. Prompting in PhotoKit happens only through
    /// `requestAuthorization(for:)`, which this file deliberately never calls —
    /// a test that put a system alert on screen would hang rather than fail.
    @Test("a thumbnail for an identifier the library does not have is nil")
    func aThumbnailForAnUnknownIdentifierIsNil() async {
        let reader = PhotosLibraryReader()

        let image = await reader.thumbnail(
            for: Self.identifierNoLibraryHas,
            maxPixelSize: Self.thumbnailPixelSize
        )

        #expect(image == nil)
    }

    @Test("image data for an identifier the library does not have is nil")
    func imageDataForAnUnknownIdentifierIsNil() async {
        let reader = PhotosLibraryReader()

        let data = await reader.imageData(for: Self.identifierNoLibraryHas)

        #expect(data == nil)
    }

    /// The one call into PhotoKit here that answers without a library at all.
    /// Asserting the value would be asserting the machine's own settings, so
    /// this asserts only that the reduction runs and yields one of the four
    /// answers the app knows how to act on — which is what catches a status
    /// arriving that ``PhotosLibraryReader/access(of:)`` maps to nothing.
    @Test("the current access is one of the answers the app can act on")
    func currentAccessIsAnAnswerTheAppUnderstands() {
        let access = PhotosLibraryReader().currentAccess()

        #expect([.denied, .granted, .limited, .restricted].contains(access))
    }
}
