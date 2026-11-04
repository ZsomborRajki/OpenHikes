//
//  WatchSessionActivationTests.swift
//  OpenHikesSharedTests
//
//  What the phone may hand `WCSession` before activation has completed and
//  while the hiker switches watches, and what the activation that follows
//  does with what waited for it.
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Watch session activation")
struct WatchSessionActivationTests {
    private static let walk = UUID(uuidString: "3B8E1D5A-7C2F-4A96-B0E4-9F1D6C2A8E57") ?? UUID()
    private static let otherWalk = UUID(uuidString: "C41A7E0D-2B9F-4D63-8A15-6E0F3B7D9C28") ?? UUID()
    private static let hike = UUID(uuidString: "8D2C6F1B-4E7A-4B30-9D58-1A6E3C9F0B74") ?? UUID()

    private static func package(answering requestID: UUID = UUID()) -> WatchTrailPackage {
        WatchTrailPackage(
            hikeID: hike,
            title: "Ridge Loop",
            tintHex: "#2E7D32",
            totalDistanceMeters: 140,
            points: [
                WatchTrailPoint(latitude: 47.0, longitude: 8.0),
                WatchTrailPoint(latitude: 47.001, longitude: 8.001),
            ],
            requestID: requestID
        )
    }

    private static func activated() -> WatchSessionActivation {
        var activation = WatchSessionActivation()
        _ = activation.finished(activated: true)
        return activation
    }

    /// The phone's link as `WatchSessionCoordinator` wires it: a transfer goes
    /// to the session only when the gate allows it and is held otherwise, and
    /// each activation that succeeds sends what it released. The session
    /// counts anything it is handed while it could not take it.
    private struct Link {
        var activation = WatchSessionActivation()
        private(set) var sentPackages: [UUID] = []
        private(set) var sentReceipts: [UUID] = []
        private(set) var refused = 0
        /// What the session itself would say its state is.
        private var isSessionActivated = false

        mutating func send(_ package: WatchTrailPackage) {
            guard activation.allowsTransfers else {
                activation.hold(package)
                return
            }
            if takes() { sentPackages.append(package.requestID) }
        }

        mutating func send(_ receipt: WatchWalkReceipt) {
            guard activation.allowsTransfers else {
                activation.hold(receipt)
                return
            }
            if takes() { sentReceipts.append(receipt.sessionID) }
        }

        mutating func activationCompleted(activated: Bool) {
            isSessionActivated = activated
            guard let release = activation.finished(activated: activated) else { return }
            release.packages.forEach { send($0) }
            release.receipts.forEach { send($0) }
        }

        /// `sessionDidBecomeInactive`, then `sessionDidDeactivate` and the
        /// `activate()` it calls.
        mutating func switchBegan() {
            isSessionActivated = false
            activation.becameInactive()
        }

        /// Whether the session took a transfer, counting one it could not.
        private mutating func takes() -> Bool {
            guard isSessionActivated else {
                refused += 1
                return false
            }
            return true
        }
    }

    // MARK: Before activation

    @Test("nothing may be transferred before the session has answered, and anything may after")
    func transfersWaitForTheCallback() {
        #expect(!WatchSessionActivation().allowsTransfers)
        #expect(Self.activated().allowsTransfers)
    }

    @Test("a package and a receipt finished before activation reach no session and go when it activates")
    func heldBeforeActivationGoOnActivation() {
        var link = Link()
        let package = Self.package()
        link.send(package)
        link.send(WatchWalkReceipt(sessionID: Self.walk))
        #expect(link.sentPackages.isEmpty)
        #expect(link.sentReceipts.isEmpty)

        link.activationCompleted(activated: true)
        #expect(link.sentPackages == [package.requestID])
        #expect(link.sentReceipts == [Self.walk])
        #expect(link.refused == 0)
    }

    @Test("every held package is released, oldest first, because the watch picks the one it asked for")
    func everyPackageIsReleasedInOrder() throws {
        let earlier = Self.package()
        let later = Self.package()
        var activation = WatchSessionActivation()
        activation.hold(earlier)
        activation.hold(later)

        let answer = activation.finished(activated: true)
        let release = try #require(answer)
        #expect(release.packages.map(\.requestID) == [earlier.requestID, later.requestID])
    }

    @Test("two receipts for one walk are held as one, and each walk keeps its own")
    func receiptsAreHeldOncePerWalk() {
        var activation = WatchSessionActivation()
        activation.hold(WatchWalkReceipt(sessionID: Self.walk))
        activation.hold(WatchWalkReceipt(sessionID: Self.otherWalk))
        activation.hold(WatchWalkReceipt(sessionID: Self.walk))
        let release = activation.finished(activated: true)
        #expect(release?.receipts.map(\.sessionID) == [Self.walk, Self.otherWalk])
    }

    // MARK: Switching watches

    @Test("a switch stops transfers until the session has activated again")
    func switchClosesTheGate() {
        var activation = Self.activated()
        activation.becameInactive()
        #expect(!activation.allowsTransfers)
        _ = activation.finished(activated: true)
        #expect(activation.allowsTransfers)
    }

    @Test("a package and a receipt finished during a switch go to the session once it is back")
    func heldDuringSwitchGoOnReactivation() {
        var link = Link()
        link.activationCompleted(activated: true)
        link.switchBegan()

        let package = Self.package()
        link.send(package)
        link.send(WatchWalkReceipt(sessionID: Self.walk))
        #expect(link.sentPackages.isEmpty)
        #expect(link.sentReceipts.isEmpty)

        link.activationCompleted(activated: true)
        #expect(link.sentPackages == [package.requestID])
        #expect(link.sentReceipts == [Self.walk])
        #expect(link.refused == 0)
    }

    @Test("what a failed reactivation keeps goes on the activation after it")
    func failedReactivationKeepsWhatItHeld() {
        var link = Link()
        link.activationCompleted(activated: true)
        link.switchBegan()
        link.send(WatchWalkReceipt(sessionID: Self.walk))

        link.activationCompleted(activated: false)
        #expect(link.sentReceipts.isEmpty)
        #expect(!link.activation.allowsTransfers)

        link.activationCompleted(activated: true)
        #expect(link.sentReceipts == [Self.walk])
        #expect(link.refused == 0)
    }

    @Test("a transfer on an activated session goes at once and is not held for the next activation")
    func activatedSessionSendsDirectly() {
        var link = Link()
        link.activationCompleted(activated: true)
        let package = Self.package()
        link.send(package)
        link.send(WatchWalkReceipt(sessionID: Self.walk))
        #expect(link.sentPackages == [package.requestID])
        #expect(link.sentReceipts == [Self.walk])

        link.switchBegan()
        link.activationCompleted(activated: true)
        #expect(link.sentPackages == [package.requestID])
        #expect(link.sentReceipts == [Self.walk])
    }

    // MARK: How an activation ends

    @Test("a failed activation opens nothing and releases nothing")
    func failureReleasesNothing() {
        var activation = WatchSessionActivation()
        activation.hold(Self.package())
        let release = activation.finished(activated: false)
        #expect(release == nil)
        #expect(!activation.allowsTransfers)
    }

    @Test("a failure answered after a success stops transfers, whatever came before it")
    func failureAfterSuccessCloses() {
        var activation = Self.activated()
        let release = activation.finished(activated: false)
        #expect(release == nil)
        #expect(!activation.allowsTransfers)
    }

    @Test("an answer repeated after a success releases nothing")
    func secondSuccessReleasesNothing() {
        var activation = WatchSessionActivation()
        activation.hold(WatchWalkReceipt(sessionID: Self.walk))
        _ = activation.finished(activated: true)
        let again = activation.finished(activated: true)
        #expect(again == nil)
        #expect(activation.allowsTransfers)
    }

    @Test("what one activation released is not released again by the next")
    func releasedTransfersAreGone() {
        var activation = WatchSessionActivation()
        activation.hold(Self.package())
        activation.hold(WatchWalkReceipt(sessionID: Self.walk))
        _ = activation.finished(activated: true)
        activation.becameInactive()
        let later = activation.finished(activated: true)
        #expect(later == WatchSessionActivation.Release(packages: [], receipts: []))
    }
}
