//
//  RouteStyleTrackingTests.swift
//  OpenHikesTests
//
//  `RouteStyle.follow(_:)` is the only thing that decides which hike's
//  appearance the map line answers to. What it holds while following, what it
//  lets go of when told to follow nothing, and what it refuses to hear from a
//  hike it has already left, is the whole of its state.
//

@testable import OpenHikes
import Testing

@MainActor
@Suite("Route style tracking")
struct RouteStyleTrackingTests {
    @Test("following a hike takes its appearance and holds it")
    func followingAdoptsTheHike() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        hike.routeWidth = 9
        let style = RouteStyle()

        style.follow(hike)

        #expect(style.trackedHike === hike)
        #expect(style.width == 9)
    }

    /// The defaults coming back is what a reader would notice; the reference
    /// going away is what this is really asserting, because nothing else
    /// distinguishes a cleared field from one still pointing at the hike the
    /// user just deselected.
    @Test("following nil restores the defaults and lets go of the hike")
    func followingNilClearsTheTrackedHike() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        hike.routeWidth = 9
        let style = RouteStyle()
        style.follow(hike)

        style.follow(nil)

        #expect(style.trackedHike == nil)
        #expect(style.width == RouteStyle.defaultWidth)
    }

    /// A write arriving after the deselection must not reinstate the old
    /// hike's appearance — the registration it was made under is dead, and
    /// with the reference gone there is nothing left for it to read either.
    @Test("a deselected hike's later writes no longer reach the style")
    func writesAfterDeselectionAreIgnored() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let style = RouteStyle()
        style.follow(hike)
        style.follow(nil)

        let observed = ObservationCounter { _ = style.width }
        await observed.settle()
        hike.routeWidth = 12
        await observed.settle()

        #expect(observed.count == 0)
        #expect(style.width == RouteStyle.defaultWidth)
        #expect(style.trackedHike == nil)
    }

    @Test("following a second hike replaces the first")
    func followingAnotherHikeReplacesTheTrackedOne() throws {
        let context = try Fixture.modelContext()
        let first = Fixture.hike(in: context)
        let second = Fixture.hike(in: context)
        let style = RouteStyle()

        style.follow(first)
        style.follow(second)

        #expect(style.trackedHike === second)
    }

    /// `generation` has two jobs and only one of them is covered by the
    /// `trackedHike` re-read beside it. Keeping the deselected hike's colour
    /// out is the shared one. The other is its own: a stale callback that is
    /// allowed to run also calls `track(generation:)` again, arming a *second*
    /// registration on the newly followed hike — after which every write to
    /// that hike is applied once per hike ever followed.
    ///
    /// None of that is visible in `tint`, `width` or `pattern`, which is why
    /// it went untested for so long. A duplicated apply always restates the
    /// *current* hike's appearance, so it writes values that are already
    /// there, and Observation drops an equal write to an `Equatable` property
    /// (`Observation cost` in `RenderIsolationTests` pins that runtime
    /// behaviour). An `ObservationCounter` on `style.width` reads 1 either
    /// way. So this counts the work through `RouteStyle.appliedCount`, which
    /// exists for this test and nothing else.
    ///
    /// Note what the deselected hike's write does *not* prove on its own: with
    /// `generation` gone the stale callback finds a perfectly good
    /// `trackedHike` and applies *its* values, so the visible appearance is
    /// right in both worlds. Only the count separates them.
    @Test("a stale callback neither applies nor arms a second registration")
    func staleCallbackDoesNotRearmASecondRegistration() async throws {
        let context = try Fixture.modelContext()
        let first = Fixture.hike(in: context, title: "First")
        let second = Fixture.hike(in: context, title: "Second")
        first.routeWidth = 4
        second.routeWidth = 5
        let style = RouteStyle()

        style.follow(first)
        style.follow(second)
        let appliesAfterFollowing = style.appliedCount
        #expect(appliesAfterFollowing == 2, "precondition: one apply per follow")
        #expect(style.width == 5)

        // The write the first hike's registration is still armed on. It has to
        // genuinely notify — a same-value write to a `@Model` does, but this
        // test would be measuring nothing if the write were elided — so the
        // wait is on a witness of that write rather than on a number of
        // scheduler turns.
        let staleWrite = ObservationCounter { _ = first.routeWidth }
        await staleWrite.settle()
        first.routeWidth = 40
        await settleDelegateHop(until: "the deselected hike's write to be delivered") {
            staleWrite.count == 1
        }
        await staleWrite.settle()
        #expect(staleWrite.count == 1, "precondition: the stale write must notify somebody")
        #expect(style.appliedCount == appliesAfterFollowing, "the stale callback applied nothing")

        // And now the followed hike, which is where a second registration
        // shows: one write, one apply, however many hikes have been followed
        // before it. Waited on the appearance actually arriving, which also
        // orders this assertion after the stale callback's own hop — that one
        // was enqueued first.
        second.routeWidth = 50
        await settleDelegateHop(until: "the followed hike's new width to reach the style") {
            style.width == 50
        }
        #expect(style.appliedCount == appliesAfterFollowing + 1, "one write, one apply")
        #expect(style.trackedHike === second)
    }
}
