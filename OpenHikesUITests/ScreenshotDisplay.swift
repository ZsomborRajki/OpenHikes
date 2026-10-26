//
//  ScreenshotDisplay.swift
//  OpenHikesUITests
//
//  Resolve a capture's display and its image orientation together, once.
//  Pixel probes still take fresh images; gestures reuse this geometry rather
//  than screenshotting both Duo displays on every step.
//

import UIKit
import XCTest

@MainActor
struct ScreenshotDisplay {
    let screen: XCUIScreen
    let windowSize: CGSize
    let imageSize: CGSize
    let orientation: UIImage.Orientation

    init(screen: XCUIScreen, image: UIImage, windowSize: CGSize) {
        self.screen = screen
        self.windowSize = windowSize
        imageSize = image.size
        orientation = image.imageOrientation
    }

    func natural(_ point: CGPoint) -> CGPoint {
        switch orientation {
        case .right: CGPoint(x: point.y, y: imageSize.width - point.x)
        case .left: CGPoint(x: imageSize.height - point.y, y: point.x)
        case .down: CGPoint(x: imageSize.width - point.x, y: imageSize.height - point.y)
        default: point
        }
    }
}
