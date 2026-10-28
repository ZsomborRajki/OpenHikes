import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
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
    /// again, so what it has found lives here until the screen is popped.
    @Test("Places Around Trail's search and its open card outlive rotation, and go with the screen")
    func placesAroundSearchFollowsTheNavigationLifetime() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let route = SheetRoute.placesAround(hike)
        let presentation = SheetPresentation()
        presentation.path = [.hike(hike), route]
        let search = presentation.placesAroundSearch(for: route)
        let card = UUID()
        search.reach = .onTrail
        search.selection = card

        for layout in [SheetLayout.sidePanel, .bottomSheet] {
            presentation.layout = layout
            #expect(presentation.placesAroundSearch(for: route) === search)
            #expect(search.selection == card, "the card open over the screen is presented again")
            #expect(search.reach == .onTrail)
        }

        let spot = HikePlaceSpot(CLLocationCoordinate2D(latitude: 47.6, longitude: 12.9))
        presentation.path.append(.newPlace(hike, spot))
        #expect(presentation.placesAroundSearch(for: route) === search, "a screen pushed over it keeps it")
        presentation.path = [.hike(hike)]
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
}
