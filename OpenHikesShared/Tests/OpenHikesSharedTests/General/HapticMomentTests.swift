//
//  HapticMomentTests.swift
//  OpenHikesSharedTests
//

import SwiftUI
import Testing

@testable import OpenHikesShared

/// Pins the tier boundaries, which are the only thing about a haptic a test
/// can hold.
///
/// It cannot assert that anything was felt — nothing in a test process drives
/// a Taptic Engine, and on the macOS host `swift test` runs on there is no
/// engine to drive. What it can hold is the claim the file is organised
/// around: that the three tiers stay distinguishable from each other, and that
/// the quiet two stay quiet. Every one of these went red against a plausible
/// wrong version — a call site reaching for `.success` on a community publish
/// is exactly the drift the enum exists to prevent, and `quietTiersStayQuiet`
/// is what notices.
@Suite("Haptic moments")
struct HapticMomentTests {
    /// The walk's seven moments, and the two the quiet tiers are built from.
    private static let walkMoments: [HapticMoment] = [
        .walkBegan, .trackingBegan, .walkPaused,
        .walkResumed, .walkSaved, .walkDiscarded, .walkFailed,
    ]

    private static let quietMoments: [HapticMoment] = [
        .outcomeSucceeded, .outcomeFailed, .targetHit, .pinDropped, .choiceChanged,
        .rowMoved,
    ]

    @Test("Every moment belongs to exactly one tier")
    func everyMomentIsTiered() {
        let tiered = Set(Self.walkMoments).union(Self.quietMoments)
        #expect(tiered.count == Self.walkMoments.count + Self.quietMoments.count)
        #expect(tiered == Set(HapticMoment.allCases))
    }

    /// The claim the second and third tiers rest on. `SensoryFeedback` is
    /// opaque, so this asserts by *inequality* against the announcing patterns
    /// rather than by reading an intensity back out: nothing below the walk
    /// may be one of the system's three notification patterns, and none of
    /// them may borrow `.start` or `.stop` either.
    @Test("The quiet tiers never reach for an announcement")
    func quietTiersStayQuiet() {
        let announcements: [SensoryFeedback] = [
            .success, .warning, .error, .start, .stop,
        ]
        for moment in Self.quietMoments {
            for announcement in announcements {
                #expect(
                    moment.feedback != announcement,
                    "\(moment.rawValue) is in a quiet tier and must not announce"
                )
            }
        }
    }

    /// Two moments that mean opposite things must not feel the same, or the
    /// pair is worth nothing. Pause against resume is the pair a hiker reads
    /// through a sleeve; succeeded against failed is the one that says whether
    /// to look at the screen.
    @Test("Opposed moments are distinguishable")
    func opposedMomentsDiffer() {
        #expect(HapticMoment.walkPaused.feedback != HapticMoment.walkResumed.feedback)
        #expect(HapticMoment.walkSaved.feedback != HapticMoment.walkDiscarded.feedback)
        #expect(HapticMoment.walkSaved.feedback != HapticMoment.walkFailed.feedback)
        #expect(
            HapticMoment.outcomeSucceeded.feedback != HapticMoment.outcomeFailed.feedback
        )
    }

    /// Starting and resuming share `.start` on purpose — see ``HapticMoment``
    /// — and this is the pin that keeps that a decision rather than a typo
    /// somebody later "fixes" in one direction.
    @Test("Resuming feels like starting, deliberately")
    func resumingSharesStarting() {
        #expect(HapticMoment.walkResumed.feedback == HapticMoment.walkBegan.feedback)
    }

    /// The first fix is lighter than the tap that asked for it, because the
    /// two arrive seconds apart and a second knock of equal weight reads as a
    /// stutter.
    @Test("The first fix is quieter than the tap that asked for it")
    func trackingIsQuieterThanBeginning() {
        #expect(HapticMoment.trackingBegan.feedback != HapticMoment.walkBegan.feedback)
        #expect(HapticMoment.trackingBegan.feedback == .impact(weight: .light))
    }

    /// A pin dropped by a press is answered while the thumb is still down, so
    /// it is the one texture moment at full weight. If it went back to sharing
    /// ``HapticMoment/targetHit``, the press would get the soft knock that
    /// nobody could feel under a pressing thumb.
    @Test("A dropped pin is felt through the pressing thumb")
    func pinDropIsFirmerThanATap() {
        #expect(HapticMoment.pinDropped.feedback != HapticMoment.targetHit.feedback)
        #expect(HapticMoment.pinDropped.feedback == .impact(weight: .medium))
    }
}
