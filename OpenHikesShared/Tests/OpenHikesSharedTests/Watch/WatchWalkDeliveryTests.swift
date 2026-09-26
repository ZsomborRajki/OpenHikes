//
//  WatchWalkDeliveryTests.swift
//  OpenHikesSharedTests
//
//  When the watch offers a finished walk to the phone again, and when it holds
//  back because one is already crossing.
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Watch walk delivery")
struct WatchWalkDeliveryTests {
    private static let walk = UUID(uuidString: "6A2F9C1E-0B7D-4E1A-9C3F-2D8B5E7A1C40") ?? UUID()
    private static let now = Date(timeIntervalSince1970: 1_758_000_000)

    private static func offered() -> WatchWalkDelivery {
        var delivery = WatchWalkDelivery()
        delivery.handedOver(walk)
        return delivery
    }

    @Test("a walk this process has never offered is offered")
    func neverOfferedIsOffered() {
        let delivery = WatchWalkDelivery()
        #expect(delivery.hasNeverOffered(Self.walk))
        #expect(delivery.shouldOffer(Self.walk, at: Self.now))
    }

    @Test("repeated reachability drains while a transfer is crossing offer nothing")
    func crossingIsNotOfferedAgain() {
        let delivery = Self.offered()
        #expect(!delivery.hasNeverOffered(Self.walk))
        for minutes in [0.0, 1, 30, 600] {
            #expect(!delivery.shouldOffer(Self.walk, at: Self.now.addingTimeInterval(minutes * 60)))
        }
    }

    @Test("a failed transfer or a refused save is offered again once the first wait has passed")
    func finishedWithoutReceiptIsRetried() {
        // A transport failure and a delivery the phone refused to keep reach
        // the watch the same way — a finished transfer and no receipt — and
        // are the same answer.
        var delivery = Self.offered()
        delivery.transferFinished(Self.walk, at: Self.now)
        #expect(!delivery.shouldOffer(Self.walk, at: Self.now))
        let due = Self.now.addingTimeInterval(WatchWalkDelivery.firstRetryDelay)
        #expect(!delivery.shouldOffer(Self.walk, at: due.addingTimeInterval(-1)))
        #expect(delivery.shouldOffer(Self.walk, at: due))
    }

    @Test("each unanswered attempt doubles the wait, up to the longest")
    func waitsBackOffAndCap() {
        var delivery = Self.offered()
        var clock = Self.now
        for wait: TimeInterval in [60, 120, 240, 480, 960, 1800, 1800, 1800] {
            delivery.transferFinished(Self.walk, at: clock)
            #expect(!delivery.shouldOffer(Self.walk, at: clock.addingTimeInterval(wait - 1)))
            #expect(delivery.shouldOffer(Self.walk, at: clock.addingTimeInterval(wait)))
            clock = clock.addingTimeInterval(wait)
            delivery.handedOver(Self.walk)
        }
    }

    @Test("a receipt forgets the walk, so a later arrival of the same ID starts afresh")
    func receiptForgets() {
        var delivery = Self.offered()
        delivery.transferFinished(Self.walk, at: Self.now)
        delivery.receiptArrived(Self.walk)
        #expect(delivery.hasNeverOffered(Self.walk))
        #expect(delivery.shouldOffer(Self.walk, at: Self.now))
    }

    @Test("a lost receipt is recovered by the retry, and the retry's receipt ends it")
    func lostReceiptThenSuccessfulRetry() {
        var delivery = Self.offered()
        delivery.transferFinished(Self.walk, at: Self.now)
        let retry = Self.now.addingTimeInterval(WatchWalkDelivery.firstRetryDelay)
        #expect(delivery.shouldOffer(Self.walk, at: retry))
        delivery.handedOver(Self.walk)
        #expect(!delivery.shouldOffer(Self.walk, at: retry))
        delivery.receiptArrived(Self.walk)
        delivery.transferFinished(Self.walk, at: retry)
        // The receipt beat the delegate's finish; the late finish must not
        // resurrect a walk that is already off the disk queue.
        #expect(delivery.hasNeverOffered(Self.walk))
    }

    @Test("a finish for a walk this process never offered is ignored")
    func strayFinishIsIgnored() {
        var delivery = WatchWalkDelivery()
        delivery.transferFinished(Self.walk, at: Self.now)
        #expect(delivery.shouldOffer(Self.walk, at: Self.now))
    }
}
