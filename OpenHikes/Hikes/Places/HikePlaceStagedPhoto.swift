//
//  HikePlaceStagedPhoto.swift
//  OpenHikes
//
//  A photograph *Add Place* is holding until the place it is of exists — see
//  ``HikePlaceAdder`` for why nothing reaches the hike before *Add*.
//
//  Its own file rather than inside the form's, because filing it is logic the
//  unit suites can reach, and a view's file is one the coverage floor does not
//  measure.
//

import Foundation
import OpenHikesData
import SwiftData
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A photograph held by *Add Place* until the place exists.
struct HikePlaceStagedPhoto: Identifiable {
    enum Source {
        case captured(CapturedFrame)
        case picked(Data, assetLocalIdentifier: String?)
    }

    let id = UUID()
    let source: Source
    let thumbnail: PhotoImage?

    /// Files it under `place` through the path every photograph takes,
    /// answering what went wrong — `nil` when it is on the hike.
    func file(
        under place: TrailPlace,
        of hike: Hike,
        savesCapturesToPhotoLibrary: Bool,
        store: HikePhotoStore = .shared,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) async -> PhotoCaptureState.Failure? {
        switch source {
        case let .captured(frame):
            let stored = await HikePhotoImport.add(
                captured: frame,
                to: hike,
                coordinate: place.clCoordinate,
                savesToPhotoLibrary: savesCapturesToPhotoLibrary,
                placeID: place.id,
                store: store,
                save: save
            )
            return stored == nil ? .captureNotStored : nil
        case let .picked(data, identifier):
            let stored = await HikePhotoImport.add(
                data,
                to: hike,
                coordinate: place.clCoordinate,
                savesToPhotoLibrary: false,
                assetLocalIdentifier: identifier,
                placeID: place.id,
                store: store,
                save: save
            )
            return stored == nil ? .importFailed : nil
        }
    }

    private static let thumbnailPixels = CGSize(
        width: PhotoTileMetrics.stripTileSize * 3,
        height: PhotoTileMetrics.stripTileSize * 3
    )

    /// A strip-sized copy, decoded off the main actor: a camera frame is
    /// twelve megapixels and the strip draws it at seventy-six points.
    static func thumbnail(of image: PhotoImage) async -> PhotoImage? {
        #if canImport(UIKit)
        await image.byPreparingThumbnail(ofSize: thumbnailPixels)
        #else
        image
        #endif
    }

    static func thumbnail(of data: Data) async -> PhotoImage? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        return await thumbnail(of: image)
        #else
        NSImage(data: data)
        #endif
    }
}
