//
//  TrailWalkSessionTests+Offers.swift
//  OpenHikesTests
//
//  A match offers a walk rather than starting one, and the hiker's three
//  answers: Start, Ignore, and Don't Ask Again — see ``WalkOffer``.
//
//  What the notification does with an offer is the controller's subject, in
//  `MovementReminderControllerTests+WalkOffer`; the two meet in the last
//  section here, which is the wiring between them.
//

import Foundation
@testable import OpenHikes
import Testing

extension TrailWalkSessionTests {
    /// A defaults suite of its own, so an Ignore remembered by one test is
    /// not read by another — or by the host app.
    private func isolatedDefaults() -> UserDefaults {
        let name = "walk-offers-\(UUID().uuidString)"
        return UserDefaults(suiteName: name) ?? .standard
    }

    private func offeringSession(
        defaults: UserDefaults? = nil,
        reminders: MovementReminderController? = nil
    ) -> TrailWalkSession {
        TrailWalkSession(context: context, reminders: reminders, defaults: defaults, clock: clock.read)
    }

    // MARK: Offering

    /// Selection alone offers nothing; the first matched fix asks, and starts
    /// nothing until the hiker answers.
    @Test("a matched fix offers a walk and starts none")
    func matchOffersWithoutStarting() {
        let session = offeringSession()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        #expect(session.offer == nil, "nothing has matched yet")

        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[0])

        #expect(session.offer == .asking(hikeID: hike.id))
        #expect(session.walkedHikeID == nil)
        #expect(hike.walkInProgress == nil, "and nothing is written until Start")
    }

    @Test("Start begins the walk and takes the offer down")
    func startBeginsTheWalk() {
        let session = offeringSession()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[0])

        #expect(session.start(hike: hike, routeLengthMeters: profile.totalDistanceMeters))

        #expect(session.walkedHikeID == hike.id)
        #expect(session.phase == .following)
        #expect(session.offer == nil)
        #expect(hike.walkInProgress?.hikeID == hike.id)
    }

    /// The fix that found the hiker is the walk's first, not spent on the
    /// question: a Start followed by one step already covers that step.
    @Test("the match that made the offer is the walk's first")
    func offeringMatchSeedsTheWalk() {
        let session = offeringSession()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[0])
        session.start(hike: hike, routeLengthMeters: profile.totalDistanceMeters)

        clock.advance(by: 60)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[1])

        #expect(session.furthestDistanceMeters == profile.distances[1])
        #expect(session.coveredFraction > 0, "the stretch from the offer to the next fix is walked")
    }

    /// Following off is what the switch has always meant: this trail may not
    /// start a walk from a match — and so may not ask to.
    @Test("following off means nothing is offered")
    func followingOffOffersNothing() {
        let session = offeringSession()
        let hike = hike { $0.autoFollowEnabled = false }
        let profile = RouteProfile(route: hike.route)

        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[0])

        #expect(session.offer == nil)
    }

    @Test("turning following off withdraws an offer already standing")
    func followingOffWithdrawsTheOffer() {
        let session = offeringSession()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[0])

        hike.autoFollowEnabled = false
        session.autoFollowDidChange(hikeID: hike.id, enabled: false)

        #expect(session.offer == nil)
    }

    @Test("a recording's draft is never offered a walk")
    func draftIsNotOffered() {
        let session = offeringSession()
        let draft = hike(title: "Draft") { $0.isRecording = true }
        let profile = RouteProfile(route: draft.route)

        session.recordForegroundMatch(hike: draft, profile: profile, distance: profile.distances[0])

        #expect(session.offer == nil)
    }

    /// End is an end until the hiker leaves the route, and asking straight
    /// after it would be the controls coming back by another name.
    @Test("a walk just ended is not offered again on the same trail")
    func endedWalkIsNotReoffered() {
        let session = offeringSession()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        walk(session, hike: hike, profile: profile, from: 0, through: 1)
        session.end()

        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[2])

        #expect(session.offer == nil)
        #expect(session.walkedHikeID == nil)
    }

    /// The background feed knows the trail by identifier and carries the
    /// route length itself — the case the notification exists for.
    @Test("a background match offers the walk too")
    func backgroundMatchOffers() {
        let session = offeringSession()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)

        session.offerWalk(hikeID: hike.id, routeLengthMeters: profile.totalDistanceMeters)

        #expect(session.offer == .asking(hikeID: hike.id))
        #expect(session.walkedHikeID == nil)
    }

    @Test("a notification's Start starts the walk by identifier")
    func startByIdentifier() {
        let session = offeringSession()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)

        #expect(session.start(hikeID: hike.id, routeLengthMeters: profile.totalDistanceMeters))

        #expect(session.walkedHikeID == hike.id)
        #expect(!session.start(hikeID: UUID(), routeLengthMeters: profile.totalDistanceMeters), "no such trail")
    }

    // MARK: Ignore

    /// "Not now" must not become "not possible": the hiker is still on the
    /// trail and can change their mind without walking off it and back.
    @Test("Ignore stops asking but leaves Start available")
    func ignoreLeavesStartAvailable() {
        let session = offeringSession()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[0])

        session.ignoreOffer(hikeID: hike.id)
        clock.advance(by: 60)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[1])

        #expect(session.offer == .available(hikeID: hike.id))
        #expect(session.start(hike: hike, routeLengthMeters: profile.totalDistanceMeters))
    }

    /// A fix under the leave threshold is as likely to be the trail's own
    /// switchback as the hiker going somewhere else.
    @Test("Ignore holds until the hiker is well clear of the trail")
    func ignoreHoldsUntilTheHikerLeaves() {
        let session = offeringSession()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[0])
        session.ignoreOffer(hikeID: hike.id)

        session.recordOffRoute(hikeID: hike.id, offRouteMeters: WalkOfferPolicy.leftTrailMeters - 1)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[1])
        #expect(session.offer == .available(hikeID: hike.id), "a near miss is not a leave")

        session.recordOffRoute(hikeID: hike.id, offRouteMeters: WalkOfferPolicy.leftTrailMeters)
        #expect(session.offer == nil, "the offer is moot once they have gone")

        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[2])
        #expect(session.offer == .asking(hikeID: hike.id), "and coming back is a new visit")
    }

    /// The leave nobody saw: the background feed stands down outside the
    /// trail's region, so a drive home produces no off-route fix at all.
    @Test("an Ignore expires on its own")
    func ignoreExpires() {
        let session = offeringSession()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[0])
        session.ignoreOffer(hikeID: hike.id)

        clock.advance(by: TrailWalkPolicy.abandonAfter)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[0])

        #expect(session.offer == .asking(hikeID: hike.id))
    }

    /// The background feed runs in whatever process the system relaunched,
    /// and one that forgot the answer would ask again up the trail.
    @Test("an Ignore survives a relaunch")
    func ignoreSurvivesRelaunch() {
        let defaults = isolatedDefaults()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        let first = offeringSession(defaults: defaults)
        first.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[0])
        first.ignoreOffer(hikeID: hike.id)

        let relaunched = offeringSession(defaults: defaults)
        relaunched.offerWalk(hikeID: hike.id, routeLengthMeters: profile.totalDistanceMeters)

        #expect(relaunched.offer == .available(hikeID: hike.id))
    }

    @Test("turning following back on forgets an Ignore")
    func followingOnForgetsIgnore() {
        let session = offeringSession()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[0])
        session.ignoreOffer(hikeID: hike.id)

        session.autoFollowDidChange(hikeID: hike.id, enabled: true)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[1])

        #expect(session.offer == .asking(hikeID: hike.id))
    }

    // MARK: Don't Ask Again

    @Test("Don't Ask Again silences this trail, and the switch brings it back")
    func dontAskAgainSilencesTheTrail() {
        let session = offeringSession()
        let hike = hike()
        let other = self.hike(title: "Other Trail")
        let profile = RouteProfile(route: hike.route)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[0])

        #expect(session.setOffersWalks(false, for: hike))

        #expect(!hike.walkOffersEnabled)
        #expect(session.offer == .available(hikeID: hike.id), "Start by hand is still there")
        let relaunched = offeringSession()
        relaunched.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[1])
        #expect(relaunched.offer == .available(hikeID: hike.id), "the flag is on the trail, not in memory")
        relaunched.recordForegroundMatch(hike: other, profile: profile, distance: profile.distances[1])
        #expect(relaunched.offer == .asking(hikeID: other.id), "and on this trail alone")

        #expect(relaunched.setOffersWalks(true, for: hike))
        relaunched.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[2])
        #expect(relaunched.offer == .asking(hikeID: hike.id))
    }

    // MARK: The notification's tap

    /// A tap can launch the app, and the new process has no offer in memory
    /// for the detail to draw.
    @Test("a tap on the notification puts the card back in a new process")
    func tapReoffers() {
        let hike = hike()
        let relaunched = offeringSession()

        relaunched.reoffer(hikeID: hike.id)

        #expect(relaunched.offer == .asking(hikeID: hike.id))
    }

    @Test("a tap on a trail that was silenced meanwhile offers only Start")
    func tapAfterSilencingOffersStartOnly() {
        let hike = hike()
        let session = offeringSession()
        session.setOffersWalks(false, for: hike)

        session.reoffer(hikeID: hike.id)

        #expect(session.offer == .available(hikeID: hike.id))
    }

    // MARK: Wiring to the notification

    @Test("an offer behind the app posts the question, and answering it takes it down")
    func offerPostsAndAnswerWithdraws() async {
        let harness = MovementReminderHarness.harness()
        let session = offeringSession(reminders: harness.controller)
        let hike = hike()
        let profile = RouteProfile(route: hike.route)

        session.offerWalk(hikeID: hike.id, routeLengthMeters: profile.totalDistanceMeters)
        await harness.controller.settle()
        #expect(harness.notifier.postedKinds == [.walkNearby])
        #expect(
            harness.notifier.posted.first?.walkOffer
                == WalkOfferSubject(hikeID: hike.id, routeLengthMeters: profile.totalDistanceMeters)
        )

        session.ignoreOffer(hikeID: hike.id)
        await harness.controller.settle()
        #expect(harness.notifier.withdrawn.contains(.walkNearby))
        #expect(harness.notifier.deliveredOffer == nil)
    }

    @Test("starting the walk takes the question down")
    func startWithdrawsTheQuestion() async {
        let harness = MovementReminderHarness.harness()
        let session = offeringSession(reminders: harness.controller)
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        session.offerWalk(hikeID: hike.id, routeLengthMeters: profile.totalDistanceMeters)

        session.start(hike: hike, routeLengthMeters: profile.totalDistanceMeters)
        await harness.controller.settle()

        #expect(harness.notifier.deliveredOffer == nil)
    }

    /// A relaunched process answering a banner it never posted has no offer
    /// to settle — and the banner still has to go.
    @Test("an Ignore from a banner an earlier process posted still takes it down")
    func ignoreFromAnOrphanedBanner() async {
        let harness = MovementReminderHarness.harness()
        let hike = hike()
        harness.notifier.deliveredOffer = WalkOfferSubject(hikeID: hike.id, routeLengthMeters: 1000)
        let relaunched = offeringSession(reminders: harness.controller)

        relaunched.ignoreOffer(hikeID: hike.id)
        await harness.controller.settle()

        #expect(harness.notifier.deliveredOffer == nil)
    }
}
