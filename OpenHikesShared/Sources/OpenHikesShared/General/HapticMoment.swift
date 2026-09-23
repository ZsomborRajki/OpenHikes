//
//  HapticMoment.swift
//  OpenHikesShared
//
//  What the app says through the Taptic Engine, named by the moment rather
//  than by the buzz.
//
//  The enum is the whole point. A `.sensoryFeedback(.success, trigger:)`
//  written at a call site is a decision about *intensity* taken by whoever
//  happened to be editing that screen, and a dozen of them drift: the phone
//  and the watch stop agreeing about what stopping a walk feels like, and the
//  quiet tiers stop being quiet one well-meaning edit at a time. Naming the
//  moment moves every one of those decisions into ``HapticMoment/feedback``,
//  where the three tiers can be read against each other in one screen of text.
//
//  The cases below are in alphabetical order because `sorted_enum_cases` says
//  so, which scatters the tiers — so the tiers live in `feedback`'s switch,
//  which is free to group them, and each case names its own here.
//
//  Three tiers, and they are a claim about how loud the app is allowed to be:
//
//  **The walk** is the only tier that interrupts. A hiker's phone is in a
//  pocket and their watch is under a sleeve, and the seven moments there are
//  the ones where they cannot look — so those are the system's own full-weight
//  patterns, the vocabulary Apple's own Workout app speaks.
//
//  **An outcome that settled** is a tap the hiker made, waited on, and is
//  looking at the answer to. The screen already says what happened; the haptic
//  only says *it is done now*, so it is a soft low-intensity impact and
//  deliberately not `.success`/`.error`, whose three-beat patterns read as an
//  announcement.
//
//  **Texture** answers a gesture that could have missed — a tap on a drawn
//  line, a swatch, a row being dropped. Lighter again, and never more than one
//  per gesture. One of them is not light: a press and hold that drops a pin
//  is answered while the thumb is still resting on the glass, waiting to be
//  told it can let go, and a soft knock under a pressing thumb is one nobody
//  feels.
//
//  There is no settings switch. iOS already has a system-wide Haptics control
//  and `SensoryFeedback` and `UIFeedbackGenerator` both honour it; a second
//  switch inside one app would only be a way to disagree with it. Nothing here
//  fires unprompted either — every moment below answers something the hiker
//  just did, which is what makes the system's own setting a sufficient answer.
//

import SwiftUI
// `canImport(UIKit)` is *true* on watchOS — the module is there — while every
// feedback generator in it is unavailable, so the platform has to be named as
// well. The guard written the obvious way compiles for the phone and fails the
// watch build, which is the shape of trap the instructions file records under
// *Toolchain isolation*.
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// One thing the app can say through the Taptic Engine.
///
/// Carries two faces because the app has two kinds of call site, and they must
/// not drift apart: ``feedback`` for SwiftUI, and ``play()`` for the UIKit and
/// MapKit code that has no view to hang a modifier on.
public enum HapticMoment: String, CaseIterable, Equatable, Sendable {
    /// *Texture.* One of a small set of choices was picked.
    case choiceChanged = "choiceChanged"
    /// *An outcome that settled,* and did not work.
    case outcomeFailed = "outcomeFailed"
    /// *An outcome that settled.* Something the hiker asked for and waited on
    /// has finished, and worked.
    case outcomeSucceeded = "outcomeSucceeded"
    /// *Texture,* at full weight. A press and hold dropped a pin.
    ///
    /// Not ``targetHit``, which a tap is answered with once the finger has
    /// lifted. This one arrives while the finger is still down and is what
    /// says the press was long enough, so it has to get through a thumb
    /// pressing on the glass. Apple Maps answers the same press the same way.
    case pinDropped = "pinDropped"
    /// *Texture.* A dragged row was let go in its new place.
    case rowMoved = "rowMoved"
    /// *Texture.* A tap that could have missed, and did not — a drawn route,
    /// a pin.
    case targetHit = "targetHit"
    /// *The walk.* The first fix the recorder accepted: the line is being
    /// drawn now.
    ///
    /// Separate from ``walkBegan`` because they answer different questions and
    /// arrive seconds apart. The first says the tap landed; this one says the
    /// walk is actually being recorded, which under a cold sky is not the same
    /// news and is the one a hiker waits for.
    case trackingBegan = "trackingBegan"
    /// *The walk.* A recording or a trail walk was asked to start.
    case walkBegan = "walkBegan"
    /// *The walk.* It was thrown away at the hiker's asking.
    case walkDiscarded = "walkDiscarded"
    /// *The walk.* It could not be started, continued or kept.
    case walkFailed = "walkFailed"
    /// *The walk.* It stopped being drawn, without ending.
    case walkPaused = "walkPaused"
    /// *The walk.* …and started again.
    case walkResumed = "walkResumed"
    /// *The walk.* It is written down and kept.
    case walkSaved = "walkSaved"
}

public extension HapticMoment {
    /// How hard the two quiet tiers are allowed to hit.
    ///
    /// Named rather than written out at each site, because the numbers *are*
    /// the tiers: every settled outcome shares one and every texture moment
    /// shares the other, so a haptic that has drifted out of its tier shows up
    /// as a number that stopped matching.
    enum Intensity {
        public static let settled = 0.5
        public static let texture = 0.4
    }

    /// What SwiftUI plays for this moment.
    ///
    /// The tiers are visible in the shape of the values rather than only in
    /// the comments: the walk uses the system's named patterns, and everything
    /// below it is a single impact at a fraction of full intensity.
    var feedback: SensoryFeedback {
        switch self {
        // MARK: The walk

        // `.start` and `.stop` are the framework's own words for "an activity
        // began / ended", which is exactly what these are. Resuming is
        // starting again — to a wrist under a waterproof the two are the same
        // news — so it deliberately shares `.start` rather than inventing a
        // third pattern nobody could tell from the first.
        case .walkBegan, .walkResumed: .start
        case .walkPaused: .stop
        // Lighter than `.walkBegan` on purpose. This one arrives on its own,
        // seconds after a tap, and a second full-weight knock for news the
        // hiker did not ask for again would read as a stutter.
        case .trackingBegan: .impact(weight: .light)
        case .walkSaved: .success
        case .walkDiscarded: .warning
        case .walkFailed: .error

        // MARK: An outcome that settled

        // Soft and half-intensity: the screen in front of the hiker already
        // carries the answer.
        case .outcomeSucceeded:
            .impact(flexibility: .soft, intensity: Intensity.settled)
        // Rigid rather than soft, at the same intensity — the one axis that
        // separates these two is sharpness, so a hiker can tell a refusal from
        // an acceptance without the volume of `.error`.
        case .outcomeFailed:
            .impact(flexibility: .rigid, intensity: Intensity.settled)

        // MARK: Texture

        case .targetHit:
            .impact(flexibility: .soft, intensity: Intensity.texture)
        // Full intensity, so the texture intensity deliberately does not
        // apply. It is still one impact and not a pattern, so it stays out of
        // the walk's vocabulary.
        case .pinDropped: .impact(weight: .medium)
        case .choiceChanged: .selection
        case .rowMoved:
            .impact(flexibility: .solid, intensity: Intensity.texture)
        }
    }
}

#if canImport(UIKit) && !os(watchOS)
public extension HapticMoment {
    /// Plays this moment from code that has no SwiftUI view to hang
    /// ``SwiftUICore/View/sensoryFeedback(_:trigger:)`` on.
    ///
    /// Two kinds of call site need it and both are real: `MKMapView`'s
    /// delegate, which is where a tap on a drawn route or a pin is resolved
    /// and which is not on the SwiftUI path at all — see *Older API that is
    /// justified, not legacy* in the instructions file for why the map is a
    /// `UIViewRepresentable` — and the `async` outcome handlers, where the
    /// alternative is a `@State` counter that exists only to be a trigger and
    /// invalidates its declaring view for it.
    ///
    /// This is a *second* switch over the same cases rather than a translation
    /// of ``feedback``, because `SensoryFeedback` is opaque and cannot be taken
    /// apart. What keeps the two from drifting is exhaustiveness alone — a new
    /// case fails to compile in both places at once — and that is the whole of
    /// the guarantee, deliberately stated rather than implied: no test asserts
    /// the pair agree, because `swift test` runs this package on the macOS
    /// host, where `canImport(UIKit)` is false and this extension does not
    /// exist. Keep the two switches in the same order, which is the only thing
    /// that makes a disagreement visible by reading.
    @MainActor
    func play() {
        switch self {
        case .walkBegan, .walkResumed:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        // Not `.medium` as well. UIKit has no `.start`/`.stop`, so this face
        // has to make the pair differ by something — and pause against resume
        // is the one pair a hiker reads through a sleeve, pinned for
        // ``feedback`` by `HapticMomentTests.opposedMomentsDiffer`. Sharp
        // against blunt at the same weight is the same axis `.outcomeFailed`
        // uses to separate itself from `.outcomeSucceeded`.
        case .walkPaused:
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        case .trackingBegan:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .walkSaved:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .walkDiscarded:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .walkFailed:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .outcomeSucceeded:
            UIImpactFeedbackGenerator(style: .soft)
                .impactOccurred(intensity: Intensity.settled)
        case .outcomeFailed:
            UIImpactFeedbackGenerator(style: .rigid)
                .impactOccurred(intensity: Intensity.settled)
        case .targetHit:
            UIImpactFeedbackGenerator(style: .soft)
                .impactOccurred(intensity: Intensity.texture)
        case .pinDropped:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .choiceChanged:
            UISelectionFeedbackGenerator().selectionChanged()
        case .rowMoved:
            UIImpactFeedbackGenerator(style: .medium)
                .impactOccurred(intensity: Intensity.texture)
        }
    }
}
#endif
