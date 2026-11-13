//
//  ScreenshotDisplayGesture.swift
//  OpenHikesUITests
//
//  XCTest's element gestures can resolve the Duo's inactive cover display.
//  Its event records also accept an explicit display ID. Keep that private
//  API in screenshot automation, guarded by selector checks, like hinge's
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
    private typealias Synthesize = @convention(c) (
        AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>
    ) -> Bool

    private static let dragDuration = 0.5
    /// How long a finger rests where its path ends before it lifts, so the
    /// gesture ends as a drag and leaves no fling behind.
    private static let holdBeforeLift = 0.2
    private static let tapDuration = 0.1
    private static let fingerSpacing: CGFloat = 30

    static func tapWithTwoFingers(at point: CGPoint, on display: ScreenshotDisplay) -> Bool {
        send(on: display, paths: [
            [CGPoint(x: point.x - fingerSpacing, y: point.y)],
            [CGPoint(x: point.x + fingerSpacing, y: point.y)],
        ])
    }

    static func drag(from start: CGPoint, to end: CGPoint, on display: ScreenshotDisplay) -> Bool {
        send(on: display, paths: [[start, end]])
    }

    /// Two fingers side by side, moved together: what tilts a map. XCTest has
    /// no element gesture for it on any display.
    static func dragWithTwoFingers(from start: CGPoint, to end: CGPoint, on display: ScreenshotDisplay) -> Bool {
        send(on: display, paths: [-fingerSpacing, fingerSpacing].map { offset in
            [CGPoint(x: start.x + offset, y: start.y), CGPoint(x: end.x + offset, y: end.y)]
        })
    }

    /// Sends one finger along each of `paths`, all at once: down at a path's
    /// first point, across to its last, and up. A path of one point is a tap.
    private static func send(on display: ScreenshotDisplay, paths: [[CGPoint]]) -> Bool {
        let screen = display.screen
        let recordSelector = NSSelectorFromString("initWithName:displayID:interfaceOrientation:")
        let touchSelector = NSSelectorFromString("initForTouchAtPoint:offset:")
        let moveSelector = NSSelectorFromString("moveToPoint:atOffset:")
        let liftSelector = NSSelectorFromString("liftUpAtOffset:")
        let sendSelector = NSSelectorFromString("synthesizeWithError:")
        guard screen.responds(to: NSSelectorFromString("displayID")),
              let displayID = screen.value(forKey: "displayID") as? UInt,
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
        guard let record = makeRecord(allocated as AnyObject, recordSelector, recordName, displayID, 1),
              let object = record as? NSObject,
              object.responds(to: NSSelectorFromString("addPointerEventPath:")) else { return false }
        let makeTouch = unsafeBitCast(method_getImplementation(touchMethod), to: TouchInit.self)
        let move = unsafeBitCast(method_getImplementation(moveMethod), to: Move.self)
        let lift = unsafeBitCast(method_getImplementation(liftMethod), to: Lift.self)
        for path in paths {
            guard let start = path.first,
                  let allocatedTouch = class_createInstance(touchClass, 0),
                  let touch = makeTouch(allocatedTouch as AnyObject, touchSelector, display.natural(start), 0) else {
                return false
            }
            if path.count > 1, let end = path.last {
                move(touch, moveSelector, display.natural(end), dragDuration)
            }
            lift(touch, liftSelector, path.count > 1 ? dragDuration + holdBeforeLift : tapDuration)
            object.perform(NSSelectorFromString("addPointerEventPath:"), with: touch)
        }
        var error: NSError?
        let synthesize = unsafeBitCast(method_getImplementation(sendMethod), to: Synthesize.self)
        let success = synthesize(record, sendSelector, &error)
        if !success { XCTFail("display gesture failed: \(String(describing: error))") }
        return success
    }
}
