import Foundation
@testable import OpenHikes
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
}
