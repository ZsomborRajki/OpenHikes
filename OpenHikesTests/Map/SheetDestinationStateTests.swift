import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
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
    @Test("a walk's share card outlives rotation, and Share starts it over")
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

        presentation.path.removeLast()
        presentation.path.append(route)
        #expect(presentation.walkShare(for: route) !== share)
        #expect(!presentation.walkShare(for: route).isPresented)
    }
}
