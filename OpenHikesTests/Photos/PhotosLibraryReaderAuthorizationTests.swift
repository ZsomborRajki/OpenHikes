//
//  PhotosLibraryReaderAuthorizationTests.swift
//  OpenHikesTests
//
//  "Photo library authorization", split out of PhotoLibraryReaderTests.swift
//  so that a file declares one @Suite. That file's header still holds the
//  context the two share.
//

import Foundation
@testable import OpenHikes
import Photos
import Testing

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
