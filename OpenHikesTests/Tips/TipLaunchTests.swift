//
//  TipLaunchTests.swift
//  OpenHikesTests
//
//  Which launches get the first-run tips, and from which store — see
//  ``TipLaunch``. The rule that matters most is the first: this very bundle is
//  a hosted launch, and a hosted launch never reaches TipKit's store.
//

@testable import OpenHikes
import Testing

@Suite("Tip launch")
struct TipLaunchTests {
    @Test("a hiker's launch gets the tips, from TipKit's own store")
    func hikerLaunchIsLive() {
        let launch = TipLaunch(isHostingTests: false, isUITesting: false, showsTips: false, storeFailed: false)
        #expect(launch == .live)
    }

    /// Whatever else the launch asked for — a hosted bundle cannot be handed
    /// the UI-test argument in the first place, and must not take it if it is.
    @Test("a launch hosting a test bundle never configures TipKit", arguments: [false, true])
    func hostedLaunchIsOff(askedForTips: Bool) {
        let launch = TipLaunch(
            isHostingTests: true,
            isUITesting: askedForTips,
            showsTips: askedForTips,
            storeFailed: false
        )
        #expect(launch == .off)
    }

    @Test("automation gets the tips only when it asks, and then a fresh store", arguments: [false, true])
    func automationOptsIn(showsTips: Bool) {
        let launch = TipLaunch(isHostingTests: false, isUITesting: true, showsTips: showsTips, storeFailed: false)
        #expect(launch == (showsTips ? .fresh : .off))
    }

    /// The fallback store is in memory and empty, which would read as a first
    /// launch for a hiker who may have years of hikes behind the failure.
    @Test("a launch whose store failed to open gets no tips")
    func failedStoreIsOff() {
        let launch = TipLaunch(isHostingTests: false, isUITesting: false, showsTips: false, storeFailed: true)
        #expect(launch == .off)
    }

    @Test("this hosted launch has no tips at all")
    func thisLaunchHasNone() {
        #expect(AppTips.forThisLaunch(startupIssue: nil) == nil)
    }
}
