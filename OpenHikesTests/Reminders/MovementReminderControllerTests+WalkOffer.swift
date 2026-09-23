//
//  MovementReminderControllerTests+WalkOffer.swift
//  OpenHikesTests
//
//  The controller's half of the walk offer: posted only behind the app,
//  once per offer, never twice across a relaunch, and not over a recording.
//
//  The session calls ``MovementReminderController/walkOffered(_:trailTitle:)``
//  on every eligible match, so "once" is this type's to keep — a hiker who
//  heard the question at the trailhead must not hear it again every half a
//  kilometre up the trail.
//

import Foundation
@testable import OpenHikes
import Testing

extension MovementReminderControllerTests {
    private static let routeLengthMeters: Double = 4200
    private static let subject = WalkOfferSubject(hikeID: UUID(), routeLengthMeters: routeLengthMeters)

    @Test("an offer behind the app is posted once, named, and carries the walk")
    func offerIsPostedOnce() async {
        let harness = MovementReminderHarness.harness()

        harness.controller.walkOffered(Self.subject, trailTitle: "Ridge Loop")
        harness.controller.walkOffered(Self.subject, trailTitle: "Ridge Loop")
        harness.controller.walkOffered(Self.subject, trailTitle: "Ridge Loop")
        await harness.controller.settle()

        #expect(harness.notifier.postedKinds == [.walkNearby])
        let posted = harness.notifier.posted.first
        #expect(posted?.body.contains("Ridge Loop") == true)
        #expect(posted?.walkOffer == Self.subject)
    }

    /// With the app in front the card asks; what the foreground gets is the
    /// permission prompt, once.
    @Test("an offer with the app in front posts nothing and asks permission once")
    func foregroundOfferAsksPermissionOnly() async {
        let harness = MovementReminderHarness.harness()
        harness.activity.isActive = true

        harness.controller.walkOffered(Self.subject, trailTitle: "Ridge Loop")
        harness.controller.walkOffered(Self.subject, trailTitle: "Ridge Loop")
        await harness.controller.settle()

        #expect(harness.notifier.posted.isEmpty)
        #expect(harness.notifier.authorizationRequests == 1)
    }

    /// The phone goes into a pocket with the card unanswered: the first match
    /// behind the app is when the notification is owed.
    @Test("an offer first made in front is posted once the app is behind")
    func foregroundOfferIsPostedLater() async {
        let harness = MovementReminderHarness.harness()
        harness.activity.isActive = true
        harness.controller.walkOffered(Self.subject, trailTitle: "Ridge Loop")

        harness.activity.isActive = false
        harness.controller.walkOffered(Self.subject, trailTitle: "Ridge Loop")
        await harness.controller.settle()

        #expect(harness.notifier.postedKinds == [.walkNearby])
    }

    /// The background feed runs in whatever process the system relaunched;
    /// re-posting would replace the banner with a fresh one, sound and all.
    @Test("a banner an earlier process posted is not posted again")
    func deliveredBannerIsNotReposted() async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.deliveredOffer = Self.subject

        harness.controller.walkOffered(Self.subject, trailTitle: "Ridge Loop")
        await harness.controller.settle()

        #expect(harness.notifier.posted.isEmpty)
    }

    @Test("a different trail is a new question")
    func differentTrailIsANewOffer() async {
        let harness = MovementReminderHarness.harness()
        let other = WalkOfferSubject(hikeID: UUID(), routeLengthMeters: 900)

        harness.controller.walkOffered(Self.subject, trailTitle: "Ridge Loop")
        harness.controller.walkOffered(other, trailTitle: "Lake Path")
        await harness.controller.settle()

        #expect(harness.notifier.posted.map(\.walkOffer) == [Self.subject, other])
    }

    @Test("a recording suppresses the offer's notification")
    func recordingSuppressesTheOffer() async {
        let harness = MovementReminderHarness.harness()
        harness.controller.hasActiveRecording = { true }

        harness.controller.walkOffered(Self.subject, trailTitle: "Ridge Loop")
        await harness.controller.settle()

        #expect(harness.notifier.posted.isEmpty)
    }

    /// That switch is "Remind Me to Pause and Resume", and the offer is how
    /// a walk starts at all — Background Trail Tracking and the trail's own
    /// switch are what govern it.
    @Test("the pause-and-resume switch does not silence the offer")
    func remindersSwitchLeavesTheOffer() async {
        let harness = MovementReminderHarness.harness(remindersEnabled: false)

        harness.controller.walkOffered(Self.subject, trailTitle: "Ridge Loop")
        harness.controller.reconcileWithPreferences()
        await harness.controller.settle()

        #expect(harness.notifier.postedKinds == [.walkNearby])
        #expect(!harness.notifier.withdrawn.contains(.walkNearby))
    }

    /// Answered, and then the hiker reaches the trail again later: a settled
    /// offer is forgotten, so the next one is posted.
    @Test("settling takes the banner down and lets the next offer be posted")
    func settlingWithdrawsAndResets() async {
        let harness = MovementReminderHarness.harness()
        harness.controller.walkOffered(Self.subject, trailTitle: "Ridge Loop")

        harness.controller.walkOfferSettled()
        harness.controller.walkOffered(Self.subject, trailTitle: "Ridge Loop")
        await harness.controller.settle()

        #expect(harness.notifier.withdrawn == [.walkNearby])
        #expect(harness.notifier.postedKinds == [.walkNearby, .walkNearby])
    }

    // MARK: The banner itself

    @Test("the offer has Start and Ignore, and hears being cleared away")
    func offerButtons() {
        #expect(MovementReminderKind.walkNearby.actions == [.startWalk, .ignoreWalk])
        #expect(MovementReminderKind.walkNearby.reportsDismissal)
        #expect(MovementReminderKind.allCases.filter(\.reportsDismissal) == [.walkNearby])
    }

    /// The notification centre serialises `userInfo`, so what comes back is
    /// what a plist can hold — and a banner from any other kind has no walk.
    @Test("the walk survives the round trip through a notification")
    func subjectRoundTrips() {
        #expect(WalkOfferSubject(userInfo: Self.subject.userInfo) == Self.subject)
        #expect(WalkOfferSubject(userInfo: [:]) == nil)
        #expect(WalkOfferSubject(userInfo: ["walkOffer.hikeID": "not a uuid"]) == nil)
    }
}
