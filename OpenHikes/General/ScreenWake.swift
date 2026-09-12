//
//  ScreenWake.swift
//  OpenHikes
//
//  Whether the display's idle timer is held off, and on whose behalf.
//
//  The fifth energy policy, and the only one whose default is *not* the
//  cheaper answer in every case. `isIdleTimerDisabled` was never set anywhere
//  in this app, which is right for a six-hour walk with the phone in a pocket:
//  holding a display on for that long would undo most of what the other four
//  policies buy, and the display is the largest single consumer on the device.
//  But it is wrong for the case the hiker actually complains about — standing
//  at a junction with wet gloves on, comparing the map to the ground, while
//  the screen dims every thirty seconds. Each of those wakes pays a full
//  display ramp and a render, and the hiker pays it repeatedly, so the
//  default *costs* battery in exactly the situation it was meant to save it.
//
//  Both halves being true is why this is a switch rather than a constant. Three
//  things about it are load-bearing:
//
//  * **Off by default.** A hiker who has not asked for this gets precisely
//    the behaviour the app has always had. Nothing about the hold is inferred
//    from conditions the way the GPS profile is, because unlike a distance
//    filter there is no reading of the situation that distinguishes "reading
//    the map" from "phone in a pocket with the screen unlocked".
//  * **Scoped to a claim, not to the app.** The hold belongs to a screen where
//    the question arises — the recording screen, and a hike's detail while a
//    walk is under way — and to a *live subject* on it. A Settings screen left
//    open in a pocket holds nothing, and neither does a hike's detail that is
//    merely being read. Claims are counted rather than assigned, because two
//    screens overlap across a navigation transition: the incoming one appears
//    before the outgoing one disappears, and a single flag would be cleared by
//    the screen that was leaving.
//  * **Foreground only.** `scenePhase` is the third input, so a backgrounded
//    recording — which goes on recording, and which
//    ``RecordingHeader``/``MapView`` already stop drawing for — releases the
//    hold rather than carrying an idle timer nobody can see the effect of.
//
//  The `UIApplication` write goes through one place with a seam in front of
//  it, for the same reason every other singleton here has one: both unit
//  bundles are hosted by the app, so a suite that flipped the real idle timer
//  would flip it for the whole process and for every test after it.
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Whether one screen's claim on the display is in force.
///
/// Three inputs that all have to agree, kept as a free function so the truth
/// table is testable without a view, a scene or an application object.
nonisolated enum ScreenWakePolicy {
    /// - Parameters:
    ///   - enabled: the hiker's switch — ``SettingsKey/keepScreenAwake``.
    ///   - subjectIsLive: whether the thing this screen is about is actually
    ///     happening: a recording session that exists, or a walk under way.
    ///     A screen with nothing live on it never holds the display, however
    ///     the switch reads.
    ///   - isForeground: whether anyone can see the screen.
    static func holdsDisplay(
        enabled: Bool,
        subjectIsLive: Bool,
        isForeground: Bool
    ) -> Bool {
        enabled && subjectIsLive && isForeground
    }
}

/// The one place `isIdleTimerDisabled` is written, and the count of who is
/// asking.
///
/// A set of claims rather than a boolean: see the file header for why the
/// overlap across a navigation transition makes a single flag wrong.
@MainActor
final class ScreenWakeCoordinator {
    /// The app's instance. Suites build their own with a recording `apply`.
    static let shared = ScreenWakeCoordinator()

    /// Whether the display is being held awake right now. Not `@Observable`:
    /// nothing draws this, and a view that re-rendered on it would be a view
    /// re-rendering on a system side effect.
    private(set) var isHoldingDisplayAwake = false

    private var claims: Set<UUID> = []
    private let apply: @MainActor (Bool) -> Void

    /// - Parameter apply: the seam the system write goes through. Defaults to
    ///   `UIApplication.shared.isIdleTimerDisabled`.
    init(apply: @escaping @MainActor (Bool) -> Void = ScreenWakeCoordinator.setSystemIdleTimerDisabled) {
        self.apply = apply
    }

    /// Records or withdraws `claim`'s request, and reconciles the display.
    ///
    /// Idempotent in both directions, which is what lets a caller drive it
    /// from a value that is recomputed on every pass of its body.
    func setClaim(_ claim: UUID, held: Bool) {
        if held {
            claims.insert(claim)
        } else {
            claims.remove(claim)
        }
        reconcile()
    }

    /// Withdraws `claim` unconditionally — what a screen going away does.
    func releaseClaim(_ claim: UUID) {
        setClaim(claim, held: false)
    }

    /// The write is guarded rather than repeated: this is a system call, not
    /// an `@Observable` property, so nothing upstream filters a same-value
    /// set and a claim recomputed per body pass would otherwise make one per
    /// GPS fix.
    private func reconcile() {
        let holding = !claims.isEmpty
        guard holding != isHoldingDisplayAwake else { return }
        isHoldingDisplayAwake = holding
        apply(holding)
    }

    static func setSystemIdleTimerDisabled(_ disabled: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }
}

/// Holds the display awake while a screen's subject is live, the hiker has
/// asked for it, and the app is in front.
///
/// A `ViewModifier` rather than anything in the screen itself, and that is a
/// render-isolation decision as much as a tidiness one: it declares
/// `@AppStorage` and `@Environment(\.scenePhase)`, both of which invalidate
/// the view that *declares* them whether or not its body reads them, and a
/// scene transition moves `scenePhase` several times. Declared on
/// ``HikeDetailView`` those would re-run a screen that re-sorts a gallery and
/// rebuilds a stats grid; declared here they re-run a modifier that re-wraps a
/// subtree the parent has already built. The same rule ``DismissButton``
/// follows.
///
/// `isLive` is a closure for the other half of that rule: it is called inside
/// this modifier's body, so the observable read it performs — the recorder's
/// phase, or the walk session's hike — registers as an input of *this* body
/// and not of the screen's.
private struct KeepScreenAwake: ViewModifier {
    let coordinator: ScreenWakeCoordinator
    let isLive: () -> Bool

    @AppStorage(SettingsKey.keepScreenAwake)
    private var enabled = SettingsDefault.keepScreenAwake
    @Environment(\.scenePhase)
    private var scenePhase
    /// Identity for this screen's claim, stable for as long as the view is.
    @State private var claim = UUID()

    func body(content: Content) -> some View {
        let holds = ScreenWakePolicy.holdsDisplay(
            enabled: enabled,
            subjectIsLive: isLive(),
            isForeground: scenePhase == .active
        )
        return content
            .onChange(of: holds, initial: true) { _, held in
                coordinator.setClaim(claim, held: held)
            }
            .onDisappear {
                coordinator.releaseClaim(claim)
            }
    }
}

extension View {
    /// Keeps the display from dimming while `isLive` holds — subject to the
    /// hiker's switch and to the app being in front. See ``ScreenWakePolicy``.
    ///
    /// - Parameters:
    ///   - coordinator: whose idle timer. The app's by default; a suite passes
    ///     its own.
    ///   - isLive: whether this screen's subject is actually happening.
    ///     Evaluated in the modifier's body, so an `@Observable` read here
    ///     belongs to the modifier rather than to the calling screen.
    func keepsScreenAwake(
        with coordinator: ScreenWakeCoordinator = .shared,
        while isLive: @escaping () -> Bool
    ) -> some View {
        modifier(KeepScreenAwake(coordinator: coordinator, isLive: isLive))
    }
}
