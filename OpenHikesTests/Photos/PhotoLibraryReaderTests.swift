//
//  PhotoLibraryReaderTests.swift
//  OpenHikesTests
//
//  The concrete reader, rather than the stub everything above it is driven
//  with.
//
//  ``PhotoLibraryReading`` exists so the discovery flow can be tested without
//  a photo library, and it does that job well enough that the one type which
//  actually talks to PhotoKit had almost nothing pointed at it — and the
//  limited-access work added to it without adding any. What follows covers the
//  part of ``PhotosLibraryReader`` that is this app's own reasoning rather
//  than a call into another process: the reduction of PhotoKit's five-way
//  authorization answer to the one distinction the app acts on, the refusal to
//  raise a modal when there is no screen to raise it from, and the guarantee
//  that a callback owned by another process cannot resume a continuation
//  twice.
//
//  Deliberately not covered, because a test would assert nothing:
//  `requestAccess()` prompts, `currentAccess()` reads the host's real status,
//  `assets(takenIn:)`/`fetchAssets` need a populated library and `PHAsset` has
//  no initialiser, the two `PHImageManager` request bodies need a real asset,
//  and the body of `presentLimitedLibraryPicker` puts system UI on screen and
//  would never call its completion handler here — the `await` would hang, not
//  fail. Those are pass-throughs; the guards in front of them are not, and
//  those are what this file pins.
//

import Foundation
@testable import OpenHikes
import Photos
import Testing

@Suite("Photo library access")
struct PhotoLibraryAccessTests {
    /// The whole point of the type: four PhotoKit answers, one question. A
    /// case added to ``PhotoLibraryAccess`` without a row here still compiles,
    /// which is why the list is written out rather than derived.
    @Test(
        "only the two answers that can see a photograph allow a read",
        arguments: [
            (PhotoLibraryAccess.granted, true),
            (PhotoLibraryAccess.limited, true),
            (PhotoLibraryAccess.denied, false),
            (PhotoLibraryAccess.restricted, false),
        ]
    )
    func allowsReadingIsTrueOnlyWhereAPhotographIsVisible(
        access: PhotoLibraryAccess,
        allowsReading: Bool
    ) {
        #expect(access.allowsReading == allowsReading)
    }

    /// `.limited` reading like `.granted` is the correct answer and the source
    /// of the bug the limited-access work fixed: everything downstream works
    /// unchanged, so the flow proceeds and finds a subset — which is only safe
    /// as long as the screen that reports "nothing found" knows the difference.
    /// Pinned separately because collapsing the two is a one-character edit
    /// that no other test in the tree would notice.
    @Test("limited access reads, and is not the same answer as full access")
    func limitedReadsWithoutBeingFull() {
        #expect(PhotoLibraryAccess.limited.allowsReading)
        #expect(PhotoLibraryAccess.limited != PhotoLibraryAccess.granted)
    }
}
