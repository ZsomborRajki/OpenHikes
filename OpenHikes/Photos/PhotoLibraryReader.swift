//
//  PhotoLibraryReader.swift
//  OpenHikes
//
//  The one place this app reads the system photo library, and the one place it
//  asks to.
//
//  Everything else about photos here is built to need no read permission at
//  all: the camera writes into the app's own store, `PhotosPicker` runs out of
//  process and hands back only what the user picked, and ``PhotoLibraryWriter``
//  asks for add-only so it can file a copy without gaining the ability to look
//  at anything. That arrangement is worth stating because this file breaks it,
//  and should be understood as the exception it is.
//
//  It breaks it for the one thing that cannot be done any other way. Finding
//  the pictures somebody took *of a walk*, with the system camera, while
//  OpenHikes was closed, means asking the library which assets were created
//  between two moments — and a picker cannot answer that, because the whole
//  point is that the user does not want to identify them by hand.
//
//  So the request is made at the moment the user taps the button that needs
//  it, never at launch, and the fetch is narrowed to the walk's own time
//  window before it is made rather than filtered afterwards. Limited access is
//  a first-class answer rather than a degraded one: it means the user chose
//  which photos this app may see, which is exactly the right shape for a
//  feature that only wants a handful of them.
//

import CoreLocation
import Foundation
import os
import Photos
import Synchronization

/// What the library will let this app do, reduced to the only distinction that
/// matters here: can it be read or not.
nonisolated enum PhotoLibraryAccess: Sendable {
    case denied
    case granted
    /// The user picked a subset of their library to share. Everything below
    /// works unchanged; the fetch simply sees only what was shared.
    case limited
    /// Refused by policy — a managed device or Screen Time — so there is
    /// nothing the user can do in Settings and nothing to offer them.
    case restricted

    var allowsReading: Bool {
        switch self {
        case .granted, .limited: true
        case .denied, .restricted: false
        }
    }
}

/// Reading the photo library, as the discovery flow needs it.
///
/// A protocol so the flow can be driven without one. A `PHAsset` cannot be
/// constructed, the authorization prompt cannot be answered from a test, and
/// the Simulator's library contains whatever the last person to use it left
/// there — three good reasons why the matching rules and the state machine
/// above them are exercised against a stub instead.
protocol PhotoLibraryReading: Sendable {
    /// Asks for read access, prompting if this is the first time.
    func requestAccess() async -> PhotoLibraryAccess

    /// Every photo created inside `window`, oldest first.
    func assets(takenIn window: ClosedRange<Date>) async -> [PhotoLibraryAsset]

    /// A square-ish image for the review grid, no larger than it draws.
    func thumbnail(
        for localIdentifier: String,
        maxPixelSize: Int
    ) async -> LoadedPhotoImage?

    /// The asset's own bytes, for the copy that is written into the hike.
    ///
    /// The original rather than a re-encode: whatever the camera produced is
    /// what ``HikePhotoStore`` should store, down to the EXIF inside it.
    func imageData(for localIdentifier: String) async -> Data?
}

/// The shipping implementation, on top of PhotoKit.
nonisolated struct PhotosLibraryReader: PhotoLibraryReading {
    static let logger = Logger(
        subsystem: "OpenHikes",
        category: "PhotoLibraryRead"
    )

    /// Only what the user's own devices put there. A shared album or an
    /// iTunes-synced folder can hold photographs of somebody else's walk taken
    /// during this one, and neither is something this feature should be
    /// rummaging through.
    private static let sourceTypes: PHAssetSourceType = [.typeUserLibrary]

    func requestAccess() async -> PhotoLibraryAccess {
        Self.access(
            of: await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        )
    }

    func assets(takenIn window: ClosedRange<Date>) async -> [PhotoLibraryAsset] {
        await Self.fetchAssets(takenIn: window)
    }

    func thumbnail(
        for localIdentifier: String,
        maxPixelSize: Int
    ) async -> LoadedPhotoImage? {
        guard let asset = Self.asset(localIdentifier) else { return nil }
        let options = PHImageRequestOptions()
        // The picture may only exist in iCloud, which for a review grid is
        // worth waiting for — the alternative is a grid of grey squares for
        // anyone with optimised storage turned on.
        options.isNetworkAccessAllowed = true
        // One callback, and the full-quality one. `.opportunistic` delivers a
        // placeholder first, which is a second resume of the continuation
        // below and therefore a crash rather than a flicker.
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        let size = CGSize(width: maxPixelSize, height: maxPixelSize)
        return await withCheckedContinuation { continuation in
            let gate = ResumeOnce(continuation)
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: size,
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                gate.resume(image.map(LoadedPhotoImage.init))
            }
        }
    }

    func imageData(for localIdentifier: String) async -> Data? {
        guard let asset = Self.asset(localIdentifier) else { return nil }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        // The unedited original would silently discard a crop or an
        // adjustment the user made in Photos, and the picture they remember
        // taking is the edited one.
        options.version = .current
        return await withCheckedContinuation { continuation in
            let gate = ResumeOnce(continuation)
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset,
                options: options
            ) { data, _, _, info in
                if data == nil {
                    let error = info?[PHImageErrorKey] as? Error
                    Self.logger.error(
                        """
                        Could not read a library photo: \
                        \(error?.localizedDescription ?? "no data", privacy: .public)
                        """
                    )
                }
                gate.resume(data)
            }
        }
    }

    // MARK: - PhotoKit

    /// Off the main thread by contract, like every other enumeration in this
    /// app: a fetch walks the library's index, and a walk of a hundred
    /// thousand assets is not a thing to do between two frames.
    @concurrent
    private static func fetchAssets(
        takenIn window: ClosedRange<Date>
    ) async -> [PhotoLibraryAsset] {
        assertOffMainThread("Photo library fetches must stay off the main thread")
        let options = PHFetchOptions()
        // Narrowed here rather than filtered afterwards. The predicate is the
        // difference between reading a walk's worth of index entries and
        // reading a lifetime's.
        //
        // swiftlint:disable:next legacy_objc_type
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate <= %@",
            window.lowerBound as NSDate, // swiftlint:disable:this legacy_objc_type
            window.upperBound as NSDate // swiftlint:disable:this legacy_objc_type
        )
        options.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: true),
        ]
        options.includeAssetSourceTypes = Self.sourceTypes
        let fetched = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PhotoLibraryAsset] = []
        assets.reserveCapacity(fetched.count)
        fetched.enumerateObjects { asset, _, _ in
            // An asset with no creation date cannot be placed on a walk by
            // clock, and the clock is the whole basis of this match.
            guard let createdAt = asset.creationDate else { return }
            assets.append(
                PhotoLibraryAsset(
                    localIdentifier: asset.localIdentifier,
                    createdAt: createdAt,
                    coordinate: asset.location?.coordinate
                )
            )
        }
        return assets
    }

    private static func asset(_ localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(
            withLocalIdentifiers: [localIdentifier],
            options: nil
        ).firstObject
    }

    private static func access(of status: PHAuthorizationStatus) -> PhotoLibraryAccess {
        switch status {
        case .authorized: .granted
        case .limited: .limited
        case .restricted: .restricted
        case .denied, .notDetermined: .denied
        @unknown default: .denied
        }
    }
}

/// Resumes a continuation at most once.
///
/// PhotoKit documents a single callback for `.highQualityFormat`, and both
/// requests above ask for exactly that. This exists because the promise
/// belongs to another process and the cost of it being broken is not a wrong
/// picture but a crash — and because a future edit to a `deliveryMode` should
/// not be able to introduce one silently.
nonisolated private final class ResumeOnce<Value: Sendable>: Sendable {
    private let continuation: CheckedContinuation<Value, Never>
    private let hasResumed = Mutex(false)

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        let isFirst = hasResumed.withLock { resumed in
            defer { resumed = true }
            return !resumed
        }
        guard isFirst else { return }
        continuation.resume(returning: value)
    }
}
