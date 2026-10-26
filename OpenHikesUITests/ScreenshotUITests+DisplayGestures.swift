//
//  ScreenshotUITests+DisplayGestures.swift
//  OpenHikesUITests
//
//  XCTest's element gestures can resolve the Duo's inactive cover display.
//  Its event records also accept an explicit display ID. Keep that private
//  API in screenshot automation, guarded by selector checks, like duo-pose's
//  guarded simulator interfaces. No app target compiles this file.
//

import ObjectiveC
import UIKit
import XCTest

@MainActor
enum ScreenshotDisplayGesture {
    private typealias RecordInit = @convention(c) (AnyObject, Selector, AnyObject, UInt, Int) -> AnyObject?
    private typealias TouchInit = @convention(c) (AnyObject, Selector, CGPoint, Double) -> AnyObject?
    private typealias Move = @convention(c) (AnyObject, Selector, CGPoint, Double) -> Void
    private typealias Lift = @convention(c) (AnyObject, Selector, Double) -> Void
    private typealias Synthesize = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> Bool

    private static let dragDuration = 0.5
    private static let releaseOffset = 0.7
    private static let tapDuration = 0.1
    private static let fingerSpacing: CGFloat = 30

    static func tapWithTwoFingers(at point: CGPoint, on screen: XCUIScreen) -> Bool {
        send(on: screen, paths: [
            (CGPoint(x: point.x - fingerSpacing, y: point.y), nil),
            (CGPoint(x: point.x + fingerSpacing, y: point.y), nil),
        ])
    }

    static func drag(from start: CGPoint, to end: CGPoint, on screen: XCUIScreen) -> Bool {
        send(on: screen, paths: [(start, end)])
    }

    private static func send(on screen: XCUIScreen, paths: [(CGPoint, CGPoint?)]) -> Bool {
        let recordSelector = NSSelectorFromString("initWithName:displayID:interfaceOrientation:")
        let touchSelector = NSSelectorFromString("initForTouchAtPoint:offset:")
        let moveSelector = NSSelectorFromString("moveToPoint:atOffset:")
        let liftSelector = NSSelectorFromString("liftUpAtOffset:")
        let sendSelector = NSSelectorFromString("synthesizeWithError:")
        guard screen.responds(to: NSSelectorFromString("displayID")),
              let display = screen.value(forKey: "displayID") as? UInt,
              let recordClass = NSClassFromString("XCSynthesizedEventRecord"),
              let touchClass = NSClassFromString("XCPointerEventPath"),
              let recordMethod = class_getInstanceMethod(recordClass, recordSelector),
              let touchMethod = class_getInstanceMethod(touchClass, touchSelector),
              let moveMethod = class_getInstanceMethod(touchClass, moveSelector),
              let liftMethod = class_getInstanceMethod(touchClass, liftSelector),
              let sendMethod = class_getInstanceMethod(recordClass, sendSelector),
              let allocated = class_createInstance(recordClass, 0) else {
            XCTFail("this XCTest does not support display-specific gesture records")
            return false
        }
        let makeRecord = unsafeBitCast(method_getImplementation(recordMethod), to: RecordInit.self)
        let recordName = "Screenshot gesture" as AnyObject
        guard let record = makeRecord(allocated as AnyObject, recordSelector, recordName, display, 1),
              let object = record as? NSObject,
              object.responds(to: NSSelectorFromString("addPointerEventPath:")) else { return false }
        let makeTouch = unsafeBitCast(method_getImplementation(touchMethod), to: TouchInit.self)
        let move = unsafeBitCast(method_getImplementation(moveMethod), to: Move.self)
        let lift = unsafeBitCast(method_getImplementation(liftMethod), to: Lift.self)
        let shot = screen.screenshot().image
        for (start, end) in paths {
            guard let allocatedTouch = class_createInstance(touchClass, 0),
                  let touch = makeTouch(allocatedTouch as AnyObject, touchSelector, natural(start, in: shot), 0) else {
                return false
            }
            if let end { move(touch, moveSelector, natural(end, in: shot), dragDuration) }
            lift(touch, liftSelector, end == nil ? tapDuration : releaseOffset)
            object.perform(NSSelectorFromString("addPointerEventPath:"), with: touch)
        }
        var error: NSError?
        let synthesize = unsafeBitCast(method_getImplementation(sendMethod), to: Synthesize.self)
        let success = synthesize(record, sendSelector, &error)
        if !success { XCTFail("display gesture failed: \(String(describing: error))") }
        return success
    }

    private static func natural(_ point: CGPoint, in image: UIImage) -> CGPoint {
        switch image.imageOrientation {
        case .right: CGPoint(x: point.y, y: image.size.width - point.x)
        case .left: CGPoint(x: image.size.height - point.y, y: point.x)
        case .down: CGPoint(x: image.size.width - point.x, y: image.size.height - point.y)
        default: point
        }
    }
}
