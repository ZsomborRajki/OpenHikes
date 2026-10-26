//
//  ScreenshotUITests+MapPixels.swift
//  OpenHikesUITests
//
//  The recording is a drawn overlay with no accessibility element. Measure
//  its red stroke in the actual capture so framing can stop when the line
//  fits, instead of assuming a zoom level or panning by a fixed screen share.
//

import CoreGraphics
import UIKit
import XCTest

extension ScreenshotUITests {
    private static let recordingRedFloor: UInt8 = 230
    private static let recordingOtherChannelCeiling: UInt8 = 110
    private static let terrainColorSpread: UInt8 = 25
    private static let terrainSampleStride = 4
    private static let minimumTerrainFraction = 0.6
    private static let placeholderRed = 249
    private static let placeholderGreen = 245
    private static let placeholderBlue = 237
    private static let placeholderTolerance = 2
    private static let maximumPlaceholderFraction = 0.04
    private static let mapSampleInset: CGFloat = 12

    @MainActor
    private func screenshotPixels(in app: XCUIApplication) -> (bytes: [UInt8], width: Int, height: Int)? {
        let shot = Self.screen(showing: app).screenshot().image
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let normalized = UIGraphicsImageRenderer(size: shot.size, format: format).image { _ in
            shot.draw(in: CGRect(origin: .zero, size: shot.size))
        }
        guard let image = normalized.cgImage else { return nil }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }
        return (pixels, width, height)
    }

    @MainActor
    func screenshotMapHasTiles(in app: XCUIApplication, requireTerrain: Bool = true) -> Bool {
        guard let image = screenshotPixels(in: app) else { return false }
        let area = openMapArea(in: app)
        let region = area.insetBy(dx: Self.mapSampleInset, dy: Self.mapSampleInset)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !region.isEmpty else { return false }
        var terrain = 0
        var placeholder = 0
        var samples = 0
        for row in stride(from: Int(region.minY), to: Int(region.maxY), by: Self.terrainSampleStride) {
            for column in stride(from: Int(region.minX), to: Int(region.maxX), by: Self.terrainSampleStride) {
                let offset = (row * image.width + column) * 4
                let channels = image.bytes[offset..<(offset + 3)]
                if abs(Int(image.bytes[offset]) - Self.placeholderRed) <= Self.placeholderTolerance,
                   abs(Int(image.bytes[offset + 1]) - Self.placeholderGreen) <= Self.placeholderTolerance,
                   abs(Int(image.bytes[offset + 2]) - Self.placeholderBlue) <= Self.placeholderTolerance {
                    placeholder += 1
                }
                if let high = channels.max(), let low = channels.min(), high - low > Self.terrainColorSpread {
                    terrain += 1
                }
                samples += 1
            }
        }
        return samples > 0
            && (!requireTerrain || Double(terrain) / Double(samples) >= Self.minimumTerrainFraction)
            && Double(placeholder) / Double(samples) < Self.maximumPlaceholderFraction
    }

    @MainActor
    func recordedLineBounds(in app: XCUIApplication, within area: CGRect) -> CGRect? {
        guard let image = screenshotPixels(in: app) else { return nil }
        let width = image.width
        let height = image.height
        let pixels = image.bytes
        let region = area.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !region.isEmpty else { return nil }
        var left = width
        var top = height
        var right = 0
        var bottom = 0
        for row in Int(region.minY)..<Int(region.maxY) {
            for column in Int(region.minX)..<Int(region.maxX) {
                let offset = (row * width + column) * 4
                // The recording's system red; OSM's brown paths and muted
                // red labels do not pass this threshold.
                guard pixels[offset] > Self.recordingRedFloor,
                      pixels[offset + 1] < Self.recordingOtherChannelCeiling,
                      pixels[offset + 2] < Self.recordingOtherChannelCeiling else {
                    continue
                }
                left = min(left, column)
                right = max(right, column)
                top = min(top, row)
                bottom = max(bottom, row)
            }
        }
        guard right > left, bottom > top else { return nil }
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }
}
