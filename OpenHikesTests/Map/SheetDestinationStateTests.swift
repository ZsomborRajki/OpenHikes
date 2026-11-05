import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import SwiftData
import SwiftUI
import Testing

@Suite("Sheet destination state")
struct SheetDestinationStateTests {
    @Test("rotation retains destination choices and popping releases them")
    func choicesFollowTheNavigationLifetime() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let presentation = SheetPresentation()
        let photoRoute = SheetRoute.photo(hike, UUID())
        presentation.path = [.hike(hike), photoRoute]
        let interaction = presentation.hikeInteraction(for: hike)
        let selection = presentation.photoSelection(for: photoRoute)
        interaction.segment = .history
        interaction.titleDraft = "Unfinished rename"
        interaction.isEditingTitle = true
        let currentPhoto = UUID()
        selection.currentID = currentPhoto

        for layout in [SheetLayout.sidePanel, .bottomSheet] {
            presentation.layout = layout
            #expect(presentation.hikeInteraction(for: hike) === interaction)
            #expect(presentation.hikeInteraction(for: hike).segment == .history)
            #expect(presentation.hikeInteraction(for: hike).titleDraft == "Unfinished rename")
            #expect(presentation.photoSelection(for: photoRoute).currentID == currentPhoto)
        }

        presentation.path.removeLast()
        presentation.path.append(photoRoute)
        #expect(presentation.photoSelection(for: photoRoute).currentID == nil)
        #expect(presentation.hikeInteraction(for: hike) === interaction)
        presentation.path = []
        presentation.path = [.hike(hike)]
        #expect(presentation.hikeInteraction(for: hike) !== interaction)
        #expect(presentation.hikeInteraction(for: hike).segment == .details)
    }

    /// #1263: a screen pushed over a hike's own opens on the line that has
    /// landed there, and a turn of the phone keeps it.
    @Test("the screens about a hike share its line until the last of them is popped")
    func theLineFollowsTheHikesScreens() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let presentation = SheetPresentation()
        presentation.path = [.hike(hike)]
        let line = presentation.hikeInteraction(for: hike).line

        presentation.path.append(.place(hike, UUID()))
        presentation.layout = .sidePanel
        #expect(presentation.hikeInteraction(for: hike).line === line)

        presentation.path = [.placesAround(hike)]
        #expect(presentation.hikeInteraction(for: hike).line === line, "the hike's own screen need not be under it")

        presentation.path = []
        #expect(presentation.hikeInteraction(for: hike).line !== line)
    }

    /// #795: a turn of the phone replaces the summary that presents the share
    /// card, so the card lives here until the summary is popped.
    @Test("a walk's share card outlives rotation, Share starts it over, and Close lets it go")
    func walkShareFollowsTheNavigationLifetime() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let walk = HikeWalk(
            hikeID: hike.id,
            startedAt: .now,
            endedAt: .now,
            activeSeconds: 600,
            coveredIntervals: [0, 500],
            furthestDistanceMeters: 500,
            routeDistanceMeters: 1000,
            endReason: .ended
        )
        context.insert(walk)
        walk.hike = hike
        let route = SheetRoute.walk(walk)
        let presentation = SheetPresentation()
        presentation.path = [.hike(hike), route]
        let share = presentation.walkShare(for: route)
        share.start()
        share.shape = .empty
        share.isEditing = true

        for layout in [SheetLayout.sidePanel, .bottomSheet] {
            presentation.layout = layout
            #expect(presentation.walkShare(for: route) === share)
            #expect(share.isPresented && share.isEditing)
        }

        let generation = share.generation
        share.isPresented = false
        share.start()
        #expect(share.generation != generation, "a load from the closed flow is told it is stale")
        #expect(share.isPresented && !share.isEditing && share.shape == nil)

        share.editor = WalkShareEditorModel(
            card: WalkShareCard(
                photo: PhotoImage(),
                figures: WalkShareFigures(walk: walk, title: "Hike", profile: nil),
                shape: .empty,
                tint: .green
            ),
            defaults: try #require(UserDefaults(suiteName: "SheetDestinationStateTests.walkShare"))
        )
        share.isEditing = true
        let shown = share.generation
        share.closed()
        #expect(share.editor != nil, "the old host's dismissal in a turn leaves the card alone")
        share.isPresented = false
        share.closed()
        #expect(share.editor == nil && !share.isEditing, "closing lets the photograph go")
        #expect(share.generation != shown, "and a load still on its way lands nowhere")

        presentation.path.removeLast()
        presentation.path.append(route)
        #expect(presentation.walkShare(for: route) !== share)
        #expect(!presentation.walkShare(for: route).isPresented)
    }

    /// A turn of the phone replaces *Add Place*'s form, which closed the
    /// camera it had open and came back emptied, so what it holds lives here
    /// until the form is popped — by *Cancel*, or by *Add* putting the new
    /// place's screen in its stead.
    @Test("Add Place's form and its open camera outlive rotation, and go with the form")
    func placeAdderFollowsTheNavigationLifetime() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let route = SheetRoute.newPlace(hike, HikePlaceSpot(CLLocationCoordinate2D(latitude: 47.6, longitude: 12.9)))
        let presentation = SheetPresentation()
        presentation.path = [.recording, route]
        let form = presentation.placeAdder(for: route)
        form.draft.name = "Lookout"
        form.draft.setKind(.summit)
        form.capture.showCamera = true

        for layout in [SheetLayout.sidePanel, .bottomSheet] {
            presentation.layout = layout
            #expect(presentation.placeAdder(for: route) === form)
            #expect(form.draft.name == "Lookout" && form.draft.symbol == .summit)
            #expect(form.capture.showCamera, "the camera the form had open is presented again")
        }

        presentation.path.removeLast()
        presentation.path.append(route)
        #expect(presentation.placeAdder(for: route) !== form, "Cancel leaves nothing for the next form")
        let fresh = presentation.placeAdder(for: route).draft
        #expect(fresh.name == HikePlaceDraft.defaultKind.label && fresh.symbol == HikePlaceDraft.defaultKind)
        #expect(!presentation.placeAdder(for: route).capture.showCamera)

        let added = presentation.placeAdder(for: route)
        presentation.path[presentation.path.count - 1] = .place(hike, UUID())
        presentation.path[presentation.path.count - 1] = route
        #expect(presentation.placeAdder(for: route) !== added, "nor does Add")
    }

    /// #1170: a turn of the phone replaces *Places Around Trail*, which
    /// closed the card open over it, put *Within* back and asked the line
    /// again, so what it has found lives here until the screen is popped —
    /// and so does a request still out, which only Back withdraws.
    @Test("Places Around Trail's search, card and request out outlive rotation, and go with the screen")
    func placesAroundSearchFollowsTheNavigationLifetime() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let route = SheetRoute.placesAround(hike)
        let presentation = SheetPresentation()
        presentation.path = [.hike(hike), route]
        let search = presentation.placesAroundSearch(for: route)
        let card = UUID()
        search.reach = .onTrail
        search.selection = card
        let line = [
            RouteCoordinate(latitude: 47.60, longitude: 12.98),
            RouteCoordinate(latitude: 47.61, longitude: 12.98),
        ]
        let spring = TrailPlace(latitude: 47.605, longitude: 12.98, name: "Spring", symbol: .water)
        // Out until this test awaits: the suite holds the main actor.
        let out = search.search(along: line, from: AnsweringSource(answer: [spring]), showing: [.water])

        for layout in [SheetLayout.sidePanel, .bottomSheet] {
            presentation.layout = layout
            #expect(presentation.placesAroundSearch(for: route) === search)
            #expect(search.selection == card, "the card open over the screen is presented again")
            #expect(search.reach == .onTrail)
            #expect(!search.needsSearch(showing: [.water]), "and the request out is waited for")
        }

        let spot = HikePlaceSpot(CLLocationCoordinate2D(latitude: 47.6, longitude: 12.9))
        presentation.path.append(.newPlace(hike, spot))
        #expect(presentation.placesAroundSearch(for: route) === search, "a screen pushed over it keeps it")
        #expect(!search.needsSearch(showing: [.water]), "request and all")
        presentation.path = [.hike(hike)]
        #expect(search.needsSearch(showing: [.water]), "Back withdraws the request")
        await out.value
        #expect(search.found.isEmpty, "so its answer lands nowhere")
        presentation.path.append(route)
        #expect(presentation.placesAroundSearch(for: route) !== search, "Back leaves nothing for the next visit")
        #expect(presentation.placesAroundSearch(for: route).selection == nil)
    }

    /// The same for *Places Nearby*, which also keeps where its rows are
    /// measured from and what it has asked, so a turn neither frames the map
    /// afresh nor asks about the area again.
    @Test("Places Nearby's session outlives rotation, and goes with the screen")
    func placesNearbyFollowsTheNavigationLifetime() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let route = SheetRoute.placesNearby(hike)
        let presentation = SheetPresentation()
        presentation.path = [.recording, route]
        let session = presentation.placesNearby(for: route)
        let here = CLLocationCoordinate2D(latitude: 47.6, longitude: 12.9)
        session.origin = here
        session.asked.ask(CommunitySearchArea(coordinate: here, radiusMeters: 1500), for: [.water], isTaken: true)
        session.search.selection = UUID()

        for layout in [SheetLayout.sidePanel, .bottomSheet] {
            presentation.layout = layout
            #expect(presentation.placesNearby(for: route) === session)
            #expect(session.asked.hasAsked, "coming up again asks nothing")
            #expect(session.search.selection != nil)
        }

        presentation.path.removeLast()
        presentation.path.append(route)
        #expect(presentation.placesNearby(for: route) !== session)
        #expect(presentation.placesNearby(for: route).origin == nil)
        #expect(!presentation.placesNearby(for: route).asked.hasAsked)
    }

    /// #1336: a turn of the phone builds a shared hike's preview again in the
    /// other host, which asked for the hike again, downloaded it again and put
    /// the chart's marker back at the trailhead. So the visit lives here until
    /// its route is popped — and its downloads go then, and not before,
    /// whether or not its screen is on top to see itself go.
    @Test("a shared hike's preview outlives rotation and its gallery, and its downloads go with its route")
    func communityPreviewFollowsTheNavigationLifetime() async throws {
        let listing = CommunityListing.stub()
        let route = SheetRoute.communityHike(listing)
        let presentation = SheetPresentation()
        presentation.path = [route]
        let visit = presentation.communityPreview(of: listing)
        let scrubbed = 300.0
        visit.tracker.trackerDistance = scrubbed
        // An import that saved the hike and missed a photograph, which only
        // this visit's downloads can supply again.
        let directory = visit.downloadDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let photo = directory.appending(path: "photo-0.jpeg")
        try Data("photo".utf8).write(to: photo)
        var copy = CommunityPhotoCopy(places: [:])
        copy.attempted(
            copy.pending([(CommunityPhotoPin(capturedAt: .now, coordinate: nil), photo)], from: nil),
            landed: []
        )
        visit.photoCopy = copy

        for layout in [SheetLayout.sidePanel, .bottomSheet] {
            presentation.layout = layout
            #expect(presentation.communityPreview(of: listing) === visit)
            #expect(visit.tracker.trackerDistance.isApproximatelyEqual(to: scrubbed), "the chart's marker stays put")
            #expect(visit.photoCopy?.isComplete == false, "the missed photograph can still be tried again")
            #expect(!visit.hasEnded && FileManager.default.fileExists(atPath: photo.path))
        }

        presentation.path.append(.communityPhoto(listing, [], 0))
        #expect(presentation.communityPreview(of: listing) === visit, "its gallery over it keeps it")
        #expect(!visit.hasEnded)

        // Taken off the stack from under its gallery, by a tap on one of the
        // hiker's own hikes, while a retry is still reading the photograph.
        let gate = AsyncGate()
        visit.importTask = Task { await gate.wait() }
        let context = try Fixture.modelContext()
        presentation.path = [.hike(Fixture.hike(in: context))]
        #expect(visit.hasEnded)
        await settleDelegateHop(until: "the discard has had its chance to run")
        #expect(FileManager.default.fileExists(atPath: photo.path), "the retry reading it holds it")
        await gate.open()
        await settleDelegateHop(until: "the downloads to go once nothing is using them") {
            !FileManager.default.fileExists(atPath: directory.path)
        }

        presentation.path = [route]
        let next = presentation.communityPreview(of: listing)
        #expect(next !== visit && next.visit != visit.visit, "opening it again is a new visit")
        #expect(next.photoCopy == nil && !next.hasEnded)
    }
}

/// Answers as soon as it is asked — which, in a suite holding the main actor,
/// is not before the suite awaits.
private struct AnsweringSource: TrailPointSourcing {
    let answer: [TrailPlace]

    func places(near _: CommunitySearchArea, showing _: Set<TrailPlaceSymbol>) -> [TrailPlace] {
        answer
    }
}
