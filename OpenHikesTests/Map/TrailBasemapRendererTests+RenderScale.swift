//
//  TrailBasemapRendererTests+RenderScale.swift
//  OpenHikesTests
//
//  `renderScale` was a claim rather than a behaviour for as long as it
//  existed: `MKMapSnapshotter` ignores every scale knob it offers and returns
//  the device's own, so the images that reached the App Group were 960×960 and
//  1140×540 on a 3× phone while the constant asked for 640×640 and 760×360 —
//  2.25× the bytes to decode, inside the one process the renderer's header
//  says cannot recover from running out.
//
//  `encode` resamples now, and these are what stop the next OS release quietly
//  undoing it. They go at `encode` directly with an image built at a chosen
//  scale, so unlike the rest of the suite they need no render boundary at all:
//  the JPEG path is local work, and it is the production one that runs here.
//
//  Split from `TrailBasemapRendererTests.swift` for file length. The suite,
//  its fixtures and its `.timeLimit` live there.
//

import CoreGraphics
import Foundation
@testable import OpenHikes
import OpenHikesShared
import Testing
import UIKit

extension TrailBasemapRendererTests {
    /// An opaque image of `size` points at `scale`, standing in for what the
    /// snapshotter returns. Two tones rather than one so the JPEG encoder has
    /// something to do.
    @MainActor
    static func deviceScaleImage(size: CGSize, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
        }
    }

    /// Pixel dimensions read out of encoded bytes, so what is asserted is what
    /// a decoder will find in the file rather than what the struct claims.
    static func pixelSize(ofJPEG data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width: width, height: height)
    }

    nonisolated static let deviceScales: [CGFloat] = [2, 3]

    @Test("the intended pixel size is the point size at the renderer's scale")
    func intendedPixelSizeMatchesTheVariant() {
        #expect(TrailBasemapRenderer.intendedPixelSize(for: .square) == Self.expectedSquarePixels)
        #expect(TrailBasemapRenderer.intendedPixelSize(for: .wide) == Self.expectedWidePixels)
    }

    /// The fix itself, at both the scale that needed it and the scale that
    /// didn't. A 2× device already produced the intended size and must come
    /// through untouched; a 3× device is the case that was silently oversized.
    @Test(
        "an image at the device's own scale is written at the renderer's scale",
        arguments: TrailBasemapVariant.allCases, deviceScales
    )
    @MainActor
    func encodeResamplesToTheIntendedScale(variant: TrailBasemapVariant, deviceScale: CGFloat) throws {
        let source = Self.deviceScaleImage(size: variant.pointSize, scale: deviceScale)
        let intended = TrailBasemapRenderer.intendedPixelSize(for: variant)
        let label = "\(variant.rawValue) at \(deviceScale)×"

        let encoded = try #require(TrailBasemapRenderer.encode(source), Comment(rawValue: label))

        #expect(encoded.pixelWidth == intended.width, "\(label) recorded the wrong width")
        #expect(encoded.pixelHeight == intended.height, "\(label) recorded the wrong height")

        let onDisk = try #require(Self.pixelSize(ofJPEG: encoded.data), Comment(rawValue: label))
        #expect(onDisk.width == intended.width, "\(label) encoded the wrong width")
        #expect(onDisk.height == intended.height, "\(label) encoded the wrong height")
    }

    /// The saving is the point, so it is measured rather than inferred from
    /// the dimensions. Bounded loosely on purpose: what a JPEG encoder does
    /// with a given picture is not this suite's business, and a tight bound
    /// here would fail on a future encoder without anything being wrong.
    @Test("resampling actually shrinks what reaches the App Group")
    @MainActor
    func resamplingShrinksTheEncodedImage() throws {
        let variant = TrailBasemapVariant.square
        let native = try #require(
            Self.deviceScaleImage(size: variant.pointSize, scale: 3).jpegData(compressionQuality: 0.9)
        )
        let resampled = try #require(
            TrailBasemapRenderer.encode(Self.deviceScaleImage(size: variant.pointSize, scale: 3))
        )

        #expect(resampled.data.count < native.count)
    }

    /// The resample is UIKit drawing on a pipeline that must not touch the
    /// main thread — `encode` is reached from inside
    /// `withTaskExecutorPreference`, so this is where it really runs. A UIKit
    /// call that needed the main thread would fail here rather than in the
    /// field.
    @Test("encoding, and so the resample, works off the main thread")
    func encodeWorksOffTheMainThread() async throws {
        let variant = TrailBasemapVariant.square
        let source = Self.deviceScaleImage(size: variant.pointSize, scale: 3)

        let outcome = await Task.detached {
            (wasMain: pthread_main_np() != 0, encoded: TrailBasemapRenderer.encode(source))
        }.value

        #expect(!outcome.wasMain, "the probe itself ran on the main thread and proves nothing")
        let encoded = try #require(outcome.encoded)
        let intended = TrailBasemapRenderer.intendedPixelSize(for: variant)
        #expect(encoded.pixelWidth == intended.width)
        #expect(encoded.pixelHeight == intended.height)
    }

    /// A manifest written before the resample existed records the device's own
    /// scale. The short-circuit has to treat that as work still to do, or a
    /// walker who keeps one trail selected keeps the oversized images for as
    /// long as they keep it selected.
    @Test("a manifest recorded at the device's scale is not accepted as done")
    func anOversizedManifestIsNotAtIntendedScale() throws {
        let atIntended = try Self.basemapSet(scale: 2)
        let oversized = try Self.basemapSet(scale: 3)

        #expect(TrailBasemapRenderer.isAtIntendedScale(atIntended))
        #expect(!TrailBasemapRenderer.isAtIntendedScale(oversized))
    }

    /// One oversized image among correct ones still has to re-render: the
    /// widget picks per appearance and shape, so the one it lands on is not
    /// this renderer's to predict.
    @Test("one oversized image is enough to make the whole manifest stale")
    func oneOversizedImageMakesTheSetStale() throws {
        var mixed = try Self.basemapSet(scale: 2)
        mixed.images[0].pixelWidth *= 2
        mixed.images[0].pixelHeight *= 2

        #expect(!TrailBasemapRenderer.isAtIntendedScale(mixed))
    }

    /// A manifest as the renderer would have written it on a device of the
    /// given scale — every variant and appearance, since the widget picks
    /// among them and one wrong entry is one wrong widget.
    static func basemapSet(scale: CGFloat) throws -> TrailBasemapSet {
        let coverage = try #require(UnitMercatorRect(bounding: Self.trail))
        return TrailBasemapSet(
            hikeID: UUID(),
            coverage: coverage,
            images: TrailBasemapVariant.allCases.flatMap { variant in
                TrailBasemapAppearance.allCases.map { appearance in
                    TrailBasemap(
                        fileName: "\(variant.rawValue)-\(appearance.rawValue).jpg",
                        variant: variant,
                        appearance: appearance,
                        pixelWidth: Int(variant.pointSize.width * scale),
                        pixelHeight: Int(variant.pointSize.height * scale),
                        visibleRect: coverage
                    )
                }
            }
        )
    }
}
