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

@Suite("Photo library authorization")
struct PhotosLibraryReaderAuthorizationTests {
    /// A raw value no shipping SDK defines, used to reach the `@unknown
    /// default` arm.
    private static let rawValueNoSDKDefines = 99

    @Test(
        "every authorization PhotoKit reports reduces to what this app does about it",
        arguments: [
            (PHAuthorizationStatus.authorized, PhotoLibraryAccess.granted),
            (PHAuthorizationStatus.limited, PhotoLibraryAccess.limited),
            (PHAuthorizationStatus.restricted, PhotoLibraryAccess.restricted),
            (PHAuthorizationStatus.denied, PhotoLibraryAccess.denied),
            (PHAuthorizationStatus.notDetermined, PhotoLibraryAccess.denied),
        ]
    )
    func statusMapsToAccess(status: PHAuthorizationStatus, access: PhotoLibraryAccess) {
        #expect(PhotosLibraryReader.access(of: status) == access)
    }

    /// `.notDetermined` is folded into `.denied` rather than given an answer of
    /// its own, and that is a decision rather than an oversight: the flow only
    /// asks for a current status after it has already requested access, so an
    /// undetermined answer at that point means the request produced nothing.
    /// Treating it as `.restricted` would offer a Settings link that fixes
    /// nothing; treating it as readable would run a fetch with no permission.
    @Test("an undetermined answer is not treated as permission")
    func undeterminedIsNotPermission() {
        #expect(!PhotosLibraryReader.access(of: .notDetermined).allowsReading)
    }

    /// `PHAuthorizationStatus` is an Objective-C `NS_ENUM`, which Swift imports
    /// as an open enum: a raw value outside the set this SDK knows about still
    /// constructs. That is the only reason the `@unknown default` arm can be
    /// reached from a test at all, and it is worth reaching — a status added by
    /// a future iOS falling through to "readable" would run a fetch this app
    /// has no permission for.
    @Test("an authorization answer this build has never heard of is not permission")
    func unknownStatusIsNotPermission() throws {
        let fromTheFuture = try #require(
            PHAuthorizationStatus(rawValue: Self.rawValueNoSDKDefines),
            "an NS_ENUM imports as an open enum, so an unlisted raw value still constructs"
        )
        #expect(PhotosLibraryReader.access(of: fromTheFuture) == .denied)
    }
}

@Suite("Continuation resumption")
struct ResumeOnceTests {
    private static let firstValue = 11
    private static let secondValue = 22
    private static let racers = [31, 32, 33, 34, 35, 36, 37, 38]

    /// The failure mode here is a crash rather than a wrong answer, which is
    /// why the guard exists and why this test is worth its length: without it
    /// the second `resume` is `SWIFT TASK CONTINUATION MISUSE`, a fatal error
    /// that takes the whole bundle down rather than failing one test.
    @Test("a callback that arrives twice resumes once, with the first value")
    func theSecondResumeIsDropped() async {
        let value: Int = await withCheckedContinuation { continuation in
            let gate = ResumeOnce(continuation)
            gate.resume(Self.firstValue)
            gate.resume(Self.secondValue)
        }
        #expect(value == Self.firstValue)
    }

    /// PhotoKit's callbacks arrive on a queue this app does not own, so two of
    /// them can be in flight at once. A check-then-set that is not atomic
    /// passes the sequential test above and fails here.
    @Test("callbacks racing each other resume the continuation once")
    func racingResumesResumeOnce() async {
        let value: Int = await withCheckedContinuation { continuation in
            let gate = ResumeOnce(continuation)
            for candidate in Self.racers {
                Task.detached { gate.resume(candidate) }
            }
        }
        #expect(Self.racers.contains(value))
    }

    /// Resuming from off the main actor is the shape the image callbacks
    /// actually have; the sequential test above resumes inline on whatever
    /// actor the test runs on and would not notice isolation being added.
    @Test("a callback delivered off the main actor still resumes")
    func aResumeFromOffTheMainActorArrives() async {
        let expected = Self.firstValue
        let value: Int = await withCheckedContinuation { continuation in
            let gate = ResumeOnce(continuation)
            Task.detached { gate.resume(expected) }
        }
        #expect(value == expected)
    }
}

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
