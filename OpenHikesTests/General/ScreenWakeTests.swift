//
//  ScreenWakeTests.swift
//  OpenHikesTests
//
//  The display is the largest thing this app could spend a hiker's battery
//  on, and it is now the only one a switch can turn on. Two things are pinned
//  here, both of which fail silently in the field: a hold that is taken when
//  one of the three answers was no, and a hold that is *left behind* when the
//  screen that took it has gone.
//
//  The second is why the coordinator counts claims rather than storing a flag.
//  A navigation transition presents the incoming screen before the outgoing
//  one disappears, so the release from the screen that is leaving arrives
//  after the claim from the screen that arrived — and a flag would be cleared
//  by it, leaving the hiker's recording screen with the idle timer back on
//  and nothing on screen to say so.
//

import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Screen wake")
struct ScreenWakeTests {
    /// Records every write that reached the system seam, so a test can assert
    /// on what was *not* written as well as on what was.
    private final class Writes {
        private(set) var values: [Bool] = []

        func record(_ value: Bool) { values.append(value) }
    }

    private static func makeCoordinator() -> (ScreenWakeCoordinator, Writes) {
        let writes = Writes()
        let coordinator = ScreenWakeCoordinator { held in writes.record(held) }
        return (coordinator, writes)
    }

    /// Written out rather than parameterised: the whole point of a three-input
    /// policy is that no combination produces a hold nobody asked for, and the
    /// combinations are cheap enough to state.
    @Test("All three answers have to agree")
    func policyTruthTable() {
        #expect(holds(enabled: true, live: true, foreground: true))
        #expect(!holds(enabled: false, live: true, foreground: true))
        #expect(!holds(enabled: true, live: false, foreground: true))
        #expect(!holds(enabled: true, live: true, foreground: false))
        #expect(!holds(enabled: false, live: false, foreground: true))
        #expect(!holds(enabled: false, live: true, foreground: false))
        #expect(!holds(enabled: true, live: false, foreground: false))
        #expect(!holds(enabled: false, live: false, foreground: false))
    }

    private func holds(enabled: Bool, live: Bool, foreground: Bool) -> Bool {
        ScreenWakePolicy.holdsDisplay(
            enabled: enabled,
            subjectIsLive: live,
            isForeground: foreground
        )
    }

    @Test("Nothing is held until something claims it")
    func idleByDefault() {
        let (coordinator, writes) = Self.makeCoordinator()

        #expect(!coordinator.isHoldingDisplayAwake)
        #expect(writes.values.isEmpty)
    }

    @Test("A claim holds the display and releasing it gives it back")
    func claimAndRelease() {
        let (coordinator, writes) = Self.makeCoordinator()
        let screen = UUID()

        coordinator.setClaim(screen, held: true)
        #expect(coordinator.isHoldingDisplayAwake)

        coordinator.releaseClaim(screen)
        #expect(!coordinator.isHoldingDisplayAwake)
        #expect(writes.values == [true, false])
    }

    /// The reason the claim is idempotent: the modifier drives it from a value
    /// recomputed on every pass of its body, and a recording's body runs once
    /// per accepted GPS fix. Without the guard that is a `UIApplication` write
    /// per fix for the whole of a six-hour walk.
    @Test("Re-asserting a claim writes nothing")
    func repeatedClaimsAreNotRewritten() {
        let (coordinator, writes) = Self.makeCoordinator()
        let screen = UUID()

        for _ in 0..<50 {
            coordinator.setClaim(screen, held: true)
        }

        #expect(writes.values == [true])
    }

    @Test("Releasing something that never claimed writes nothing")
    func releasingAnUnknownClaimIsInert() {
        let (coordinator, writes) = Self.makeCoordinator()

        coordinator.releaseClaim(UUID())

        #expect(!coordinator.isHoldingDisplayAwake)
        #expect(writes.values.isEmpty)
    }

    /// The transition case in full: the detail screen's walk claims, the
    /// recording screen is pushed and claims, then the detail screen finally
    /// disappears. The display must still be held.
    @Test("An overlapping transition does not drop the hold")
    func overlappingClaimsSurviveTheOutgoingScreen() {
        let (coordinator, writes) = Self.makeCoordinator()
        let detail = UUID()
        let recording = UUID()

        coordinator.setClaim(detail, held: true)
        coordinator.setClaim(recording, held: true)
        coordinator.releaseClaim(detail)

        #expect(coordinator.isHoldingDisplayAwake)
        #expect(writes.values == [true])

        coordinator.releaseClaim(recording)
        #expect(!coordinator.isHoldingDisplayAwake)
        #expect(writes.values == [true, false])
    }

    /// Off, and the hiker who never finds the switch gets exactly the
    /// behaviour the app has always had.
    @Test("The switch is off until it is asked for")
    func defaultIsOff() {
        #expect(!SettingsDefault.keepScreenAwake)
        #expect(
            !ScreenWakePolicy.holdsDisplay(
                enabled: SettingsDefault.keepScreenAwake,
                subjectIsLive: true,
                isForeground: true
            )
        )
    }
}
