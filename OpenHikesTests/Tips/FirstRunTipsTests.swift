//
//  FirstRunTipsTests.swift
//  OpenHikesTests
//
//  The ids the first-run tips are stored against. A tip's status — closed,
//  used — is kept by id, so an id that changed would show its tip again to
//  every hiker who had already closed it; and TipKit's default id is the
//  type's name, which a refactor renames without a second thought.
//
//  Reads the tips' own properties only. Nothing here reaches TipKit's store,
//  which is one of the app's singletons — see ``TipLaunch``.
//

@testable import OpenHikes
import Testing

@Suite("First-run tips")
struct FirstRunTipsTests {
    @Test("each tip is stored under the id it shipped with")
    func idsAreStable() {
        #expect(RecordHikeTip().id == "record-hike")
        #expect(MakeTrailTip().id == "make-trail")
        #expect(CommunityTabTip().id == "community-tab")
        #expect(SearchThisAreaTip().id == "search-this-area")
        #expect(AddPlaceTip().id == "recording-add-place")
        #expect(PlacesNearbyTip().id == "recording-places-nearby")
    }

    @Test("no two tips share an id, or one closing would close the other")
    func idsAreDistinct() {
        let ids = [
            RecordHikeTip().id,
            MakeTrailTip().id,
            CommunityTabTip().id,
            SearchThisAreaTip().id,
            AddPlaceTip().id,
            PlacesNearbyTip().id,
        ]
        #expect(Set(ids).count == ids.count)
    }
}
