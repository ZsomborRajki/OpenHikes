//
//  PhotoLibrarySource.swift
//  OpenHikes
//
//  Which photo library the discovery flow reads, and the fake one it reads in
//  automation.
//
//  The real library is unreachable from a UI test in three separate ways, and
//  each of them alone would be enough. The authorization prompt is a system
//  alert about somebody's private data, which a test must not be in the
//  business of dismissing. The Simulator's library holds whatever the last
//  person to use that device left in it, so a scan finds a different number of
//  photos on every machine. And nothing in it was taken during a hike recorded
//  in 2026 by a GPX fixture, so the honest answer for a real library is always
//  "no photos found" — which is exactly the state that proves nothing.
//
//  So automation gets a stub, chosen by launch argument and compiled only into
//  DEBUG builds. What it fakes is the library and only the library: the
//  matching rules, the state machine, the store, the files on disk and the
//  gallery that reads them back are all the shipping ones. A test that watches
//  photos appear in the strip afterwards has watched the real pipeline run.
//
//  The stub answers the window it is *asked* for rather than a window of its
//  own, which is what makes it a fair test of the query: if the timeline ever
//  starts asking for the wrong range, the assets come back wrong too.
//

import CoreLocation
import Foundation

nonisolated enum PhotoLibrarySource {
    /// The reader this launch should use.
    static func reader() -> any PhotoLibraryReading {
        #if DEBUG
        if let count = AppLaunchEnvironment.stubbedLibraryPhotoCount {
            return StubPhotoLibrary(assetCount: count)
        }
        #endif
        return PhotosLibraryReader()
    }
}

#if DEBUG
#if os(iOS)
import UIKit
#endif

/// A photo library with a known number of photographs in it, all of them taken
/// during whatever window is asked for.
nonisolated struct StubPhotoLibrary: PhotoLibraryReading {
    /// Small enough that a scenario spends its time on the flow rather than on
    /// encoding, and large enough to fill a grid and force a scroll.
    let assetCount: Int
    /// Answered instead of prompting, so no system alert is ever raised.
    var access = PhotoLibraryAccess.granted

    /// Big enough to be a photograph rather than an icon, small enough that
    /// generating a dozen costs nothing. Nothing here is measuring a decode —
    /// that is ``SeededPhotoFixture``'s job, and it draws full-size frames.
    private static let pixelSide: CGFloat = 640
    private static let quality = 0.8
    private static let hueCount = 8.0

    // Async because the protocol is, not because these bodies suspend: the
    // real library is a cross-process query and this one is arithmetic.
    // swiftlint:disable async_without_await
    func requestAccess() async -> PhotoLibraryAccess { access }

    /// Spread evenly across the window, so every one of them falls inside the
    /// walk and lands on a different part of the route.
    ///
    /// No coordinate: a photograph whose camera recorded no position is both
    /// the commonest case in a real library and the one that exercises the
    /// timeline on its own, which is the path this feature is built on.
    func assets(takenIn window: ClosedRange<Date>) async -> [PhotoLibraryAsset] {
        guard assetCount > 0 else { return [] }
        let span = window.upperBound.timeIntervalSince(window.lowerBound)
        let step = span / Double(assetCount + 1)
        return (0..<assetCount).map { index in
            PhotoLibraryAsset(
                localIdentifier: "stub-asset-\(index)",
                createdAt: window.lowerBound.addingTimeInterval(
                    step * Double(index + 1)
                )
            )
        }
    }
    // swiftlint:enable async_without_await

    func thumbnail(
        for localIdentifier: String,
        maxPixelSize: Int
    ) async -> LoadedPhotoImage? {
        await Self.render(localIdentifier).flatMap { data in
            #if os(iOS)
            UIImage(data: data).map(LoadedPhotoImage.init)
            #else
            nil
            #endif
        }
    }

    func imageData(for localIdentifier: String) async -> Data? {
        await Self.render(localIdentifier)
    }

    /// JPEG bytes for one stub asset, off the main thread like every other
    /// encode in this app.
    ///
    /// Deterministic in the identifier, so the same asset is the same picture
    /// every time it is asked for — a grid whose cells changed colour between
    /// the thumbnail and the import would be a confusing thing to watch fail.
    @concurrent
    private static func render(_ localIdentifier: String) async -> Data? {
        #if os(iOS)
        let hue = Double(abs(localIdentifier.hashValue) % Int(hueCount)) / hueCount
        let size = CGSize(width: pixelSide, height: pixelSide)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(hue: hue, saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(hue: hue, saturation: 0.9, brightness: 0.4, alpha: 1).setFill()
            context.cgContext.fillEllipse(
                in: CGRect(origin: .zero, size: size).insetBy(
                    dx: pixelSide / 4,
                    dy: pixelSide / 4
                )
            )
        }
        return image.jpegData(compressionQuality: quality)
        #else
        return nil
        #endif
    }
}
#endif
