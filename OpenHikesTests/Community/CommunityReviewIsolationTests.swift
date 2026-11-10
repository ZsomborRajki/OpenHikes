//
//  CommunityReviewIsolationTests.swift
//  OpenHikesTests
//
//  A hike's review, kept from doing again what nothing changed (#1367).
//
//  The form's body read the title and ordered the submission's places along
//  its route in the same pass, so every keystroke projected every place onto
//  every leg of the line again, on the main thread: 161 ms a pass in a Debug
//  build on the simulator, for forty places on a 20,000-point line. These
//  hold the title to the sections that draw it, the places to a section that
//  reads them through the review's ``HikePlaceRows``, and that measuring to
//  once a review, off the main thread past its budget.
//
//  Counted the way `RenderIsolationTests` counts: an ``ObservationCounter``
//  around a body, which is what SwiftUI re-runs on a write. The form's zero
//  for a keystroke was watched failing against the form as it was; the place
//  section's zeros sit beside the one write that has to redraw it, so a
//  counter that saw nothing cannot pass for one that was not asked.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftUI
import Synchronization
import Testing

@MainActor
@Suite("Community review isolation", .timeLimit(.minutes(1)))
struct CommunityReviewIsolationTests {
    /// The real projection, counted: how often it ran, and how often that was
    /// on the main thread.
    nonisolated private final class Tally: Sendable {
        private struct Counts {
            var calls = 0
            var onMainThread = 0
        }

        private let counts = Mutex(Counts())

        var calls: Int { counts.withLock { $0.calls } }
        var onMainThread: Int { counts.withLock { $0.onMainThread } }

        func measure(_ places: [TrailPlace], _ route: [RouteCoordinate]) -> [UUID: TrailPlaceAnchor] {
            let onMain = pthread_main_np() != 0
            counts.withLock { counts in
                counts.calls += 1
                if onMain { counts.onMainThread += 1 }
            }
            return TrailPlaceOrder.anchors(of: places, along: route)
        }
    }

    /// One review with its submission arrived, and the screens built for it.
    private struct Review {
        let pending: CommunityPendingSubmission
        let session: CommunityHikeReviewSession
        let detail: CommunityHikeDetail
        let transport = StubCommunityTransport()
        let queue = CommunityReviewQueue(transport: nil)
        let browser = CommunityBrowser(transport: nil, blockList: .scratch())

        /// The form, built anew each time as a turn of the phone builds it.
        func form() -> CommunityReviewView {
            CommunityReviewView(
                pending: pending,
                transport: transport,
                queue: queue,
                browser: browser,
                review: session,
                onFinished: { /* nothing is decided here */ },
                remainsPushed: { true }
            )
        }

        func submission() -> CommunityReviewSubmissionSection {
            CommunityReviewSubmissionSection(pending: pending, review: session)
        }

        func decision() -> CommunityHikeDecisionSection {
            CommunityHikeDecisionSection(pending: pending, review: session) { /* nothing is published here */ }
        }

        func places() -> CommunityReviewPlaceSection {
            CommunityReviewPlaceSection(places: detail.places, route: detail.route, review: session)
        }
    }

    /// What a title correction types, one keystroke at a time.
    private static let keystrokes = ["K", "Ka", "Kar"]

    /// A line due north, `points` long.
    private static func route(points: Int) -> [RouteCoordinate] {
        (0..<points).map { index in
            RouteCoordinate(latitude: 47.40 + Double(index) * 0.00001, longitude: 11.40)
        }
    }

    /// `count` places beside `route`, marked from its north end down, so the
    /// order they are met walking it is the reverse of the order they were
    /// marked in.
    private static func places(_ count: Int, beside route: [RouteCoordinate]) -> [TrailPlace] {
        guard let first = route.first, let last = route.last else { return [] }
        let span = last.latitude - first.latitude
        return (0..<count).map { index in
            TrailPlace(
                latitude: first.latitude + span * (Double(count - index) - 0.5) / Double(count),
                longitude: first.longitude + 0.0002,
                name: "Place \(index)"
            )
        }
    }

    private func review(points: Int, places count: Int, placeRows: HikePlaceRows) async -> Review {
        let pending = CommunityPendingSubmission.stub()
        let session = CommunityHikeReviewSession(pending: pending, placeRows: placeRows)
        let route = Self.route(points: points)
        let detail = CommunityHikeDetail(
            listing: pending.prospectiveListing,
            route: route,
            places: Self.places(count, beside: route),
            photoPins: [CommunityPhotoPin(capturedAt: pending.hikeDate, coordinate: nil)],
            photoFileURLs: [session.decisions.staging.appending(path: "photo-0.jpeg")],
            photosOnRecord: 1
        )
        session.decisions.begin(loading: { _ in detail }, thenShowing: { _ in /* no map behind this */ })
        await settleDelegateHop(until: "the submission arrives") { session.decisions.hasLoaded }
        return Review(pending: pending, session: session, detail: detail)
    }

    @Test("a title keystroke re-runs the title's sections, and neither the form nor its places")
    func keystrokesStayWithTheTitle() async {
        let review = await review(points: 400, places: 8, placeRows: HikePlaceRows())
        let form = ObservationCounter { _ = review.form().body }
        let places = ObservationCounter { _ = review.places().body }
        let submission = ObservationCounter { _ = review.submission().body }
        let decision = ObservationCounter { _ = review.decision().body }

        for (typed, keystroke) in Self.keystrokes.enumerated() {
            review.session.titleDraft = keystroke
            await settleDelegateHop(until: "the field's section sees \"\(keystroke)\"") {
                submission.count == typed + 1
            }
        }
        await form.settle()

        #expect(form.count == 0, "a keystroke is the title's business, not the form's")
        #expect(places.count == 0)
        #expect(decision.count == Self.keystrokes.count, "whether Publish may be pressed follows the title")
    }

    @Test("only its own answer redraws the places, not a keystroke, a photograph or a decision")
    func onlyAnAnswerRedrawsThePlaces() async {
        // Off the main actor whatever the size, so the one write that has to
        // redraw the section — the answer landing — is in this test too.
        let review = await review(points: 400, places: 8, placeRows: HikePlaceRows(budget: 0))
        let places = ObservationCounter { _ = review.places().body }
        await settleDelegateHop(until: "the anchors land") { review.session.placeRows.revision == 1 }
        await settleDelegateHop(until: "the section is redrawn with them") { places.count == 1 }

        review.session.titleDraft = "Karwendelhaus"
        review.session.decisions.toggleRemoval(of: 0) { _ in /* no map behind this */ }
        review.session.decisions.isConfirmingDecline = true
        review.session.decisions.decisionFailure = .unreachable
        await places.settle()

        #expect(places.count == 1, "nothing about the line or where a place stands moved")
    }

    @Test("the places are measured once for the review, however often its screens are drawn")
    func placesAreMeasuredOnce() async {
        let tally = Tally()
        let review = await review(
            points: 400,
            places: 8,
            placeRows: HikePlaceRows { places, route in tally.measure(places, route) }
        )

        for keystroke in Self.keystrokes {
            review.session.titleDraft = keystroke
            _ = review.form().body
            _ = review.places().body
        }
        review.session.decisions.toggleRemoval(of: 0) { _ in /* no map behind this */ }
        _ = review.form().body
        _ = review.places().body
        let rows = review.session.orderedPlaces(review.detail.places, along: review.detail.route)

        #expect(tally.calls == 1)
        #expect(rows == TrailPlaceOrder.ordered(review.detail.places, along: review.detail.route))
        #expect(
            rows.map(\.place.name) == review.detail.places.map(\.name).reversed(),
            "walked north, met in the reverse of the order they were marked"
        )
    }

    /// The submission the issue measured: forty places on a 20,000-point line,
    /// 799,960 projections, which is past ``HikePlaceRows/synchronousBudget``.
    @Test("a long submission's places are measured off the main thread, and listed meanwhile")
    func longSubmissionIsMeasuredOffTheMainThread() async {
        let tally = Tally()
        let review = await review(
            points: 20_000,
            places: 40,
            placeRows: HikePlaceRows { places, route in tally.measure(places, route) }
        )

        let first = review.session.orderedPlaces(review.detail.places, along: review.detail.route)
        #expect(first.map(\.id) == review.detail.places.map(\.id), "as they were marked, until measured")
        #expect(first.allSatisfy { $0.anchor == nil })
        _ = review.form().body
        await settleDelegateHop(until: "the anchors land") { review.session.placeRows.revision == 1 }
        for keystroke in Self.keystrokes {
            review.session.titleDraft = keystroke
            _ = review.form().body
            _ = review.places().body
        }

        #expect(tally.calls == 1)
        #expect(tally.onMainThread == 0)
        #expect(
            review.session.orderedPlaces(review.detail.places, along: review.detail.route)
                == TrailPlaceOrder.ordered(review.detail.places, along: review.detail.route)
        )
    }
}
