//
//  SheetRoute.swift
//  OpenHikes
//

import Foundation
import OpenHikesData
import SwiftData

enum SheetRoute: Hashable {
    /// A published hike, before it is imported. Carries the listing rather
    /// than a `Hike` because there is no `Hike` yet — that is the whole
    /// question the screen is asking — and the listing is a `Sendable` value
    /// with no model context behind it, so nothing here can be invalidated by
    /// a store the way a pushed `Hike` can.
    case communityHike(CommunityListing)
    /// A shared hike's gallery, opened at one photograph.
    ///
    /// Carries the pictures rather than a way of finding them, because there
    /// is no way of finding them: they are files in a directory the preview
    /// underneath this screen owns and deletes, and a ``CommunityHikeDetail``
    /// never leaves that screen. Which is also what keeps them alive while
    /// this route is up — the preview stays on the stack under it, so
    /// ``SheetPresentation/isPresentingCommunityHike(_:)`` goes on answering
    /// yes and nothing collects the downloads.
    case communityPhoto(CommunityListing, [CommunityGalleryPhoto], Int)
    case hike(Hike)
    /// A place about to be added to a hike from the map's pill, at the spot
    /// the pill resolved when it was tapped. Carries the spot rather than a
    /// ``TrailPlace`` because nothing is on the hike until the hiker says
    /// *Add* — see ``HikePlaceAdder``.
    case newPlace(Hike, HikePlaceSpot)
    /// A submission waiting for review. Carries the queue entry for the reason
    /// ``communityHike(_:)`` carries a listing — there is no `Hike` and no
    /// listing either, and the value is `Sendable` with no store behind it.
    ///
    /// Reachable only from a queue that came back non-empty, which is a thing
    /// the server decides. See ``CommunityReviewQueue``.
    /// Photographs waiting for review. Its own case rather than a payload on
    /// ``pendingSubmission(_:)``, because the two open different screens and
    /// publish different record types — the split ``CommunityReviewBatch``
    /// makes, carried through to navigation.
    case pendingPhotos(CommunityPendingPhotos)
    case pendingSubmission(CommunityPendingSubmission)
    /// A hike's gallery, opened at one photo. Carries the hike rather than the
    /// photo so the viewer can page through the rest of them, and so a photo
    /// deleted from inside the viewer doesn't invalidate the route showing it.
    case photo(Hike, UUID)
    /// One of a hike's places, on its own screen: what OpenStreetMap says
    /// about it and the photographs filed under it. Carries the hike and the
    /// place's id rather than the ``TrailPoint``, for the reason ``photo(_:_:)``
    /// does — a place removed from inside its screen must not invalidate the
    /// route showing it. See ``HikePlaceView``.
    case place(Hike, UUID)
    /// *Places Around Trail*: what OpenStreetMap has on and around a hike's
    /// line, on the map and in a list, to add to it. See
    /// ``HikePlacesAroundView``.
    case placesAround(Hike)
    case recording
    /// How a hike's line is drawn — see ``RouteStyleView``. Pushed over the
    /// hike's own screen, and popped with it when the hike is deleted.
    case routeStyle(Hike)
    /// How far the hiker has walked, summed across the library — see
    /// ``LibraryTotalsView``. Carries nothing: it is worked out on open.
    case totals
    /// The trail maker. Carries nothing: the draft it is about lives in
    /// ``TrailDraftController``, which the map writes into and this screen
    /// reads, exactly as the recording screen carries no recording.
    case trailDraft
    /// A finished walk's summary. Carries the walk, whose `hikeID` says which
    /// hike's screens it belongs under — so deleting the hike pops its
    /// summaries with it.
    case walk(HikeWalk)

    static func reopenRecording(in path: inout [Self]) {
        path = [.recording]
    }

    static func openRecording(
        hike: Hike?,
        selectedHike: inout Hike?,
        in path: inout [Self]
    ) {
        if let hike {
            selectedHike = hike
        }
        reopenRecording(in: &path)
    }

    /// Whether this route is showing the given hike — a pushed photo viewer
    /// counts, since deleting a hike takes its gallery with it.
    func shows(hikeID: UUID) -> Bool {
        switch self {
        case let .hike(hike): hike.id == hikeID
        case let .photo(hike, _): hike.id == hikeID
        case let .place(hike, _): hike.id == hikeID
        case let .newPlace(hike, _): hike.id == hikeID
        case let .placesAround(hike): hike.id == hikeID
        case let .routeStyle(hike): hike.id == hikeID
        case let .walk(walk): walk.hikeID == hikeID
        // None of them shows a `Hike`, so none is popped by one being
        // deleted. A community preview — and the gallery over it — is about a
        // hike that is not in the library at all, which is exactly the state a
        // deletion puts one back into.
        case .communityHike, .communityPhoto, .pendingPhotos, .pendingSubmission, .recording, .totals, .trailDraft:
            false
        }
    }

    /// Takes a deleted hike out of the sheet's selection and navigation stack,
    /// reporting whether the selection was the one deleted.
    ///
    /// Extracted from `MapSheet.delete(_:among:)` so a test can call the rule
    /// rather than restate it. While it lived inside that private view method
    /// the only way to cover it was to re-implement it in the test, which pins
    /// the reasoning but cannot fail when the call site drifts away from it —
    /// and the call site is the half that has a deleted hike in front of it.
    ///
    /// The path is cleared unconditionally where the selection is not: a
    /// widget deep link pushes a trail directly, so "pushed" and "selected"
    /// are not guaranteed to be the same hike.
    ///
    /// - Returns: `true` when the deleted hike was the selected one, so the
    ///   caller knows to clear the map highlight with it.
    @discardableResult static func removeHike(
        _ hikeID: UUID,
        selectedHike: inout Hike?,
        from path: inout [Self]
    ) -> Bool {
        let wasSelected = selectedHike?.id == hikeID
        if wasSelected { selectedHike = nil }
        path.removeAll { $0.shows(hikeID: hikeID) }
        return wasSelected
    }

    /// Whether this route belongs to a stranger's preview: the preview itself
    /// and the gallery over it, whose files the preview underneath owns.
    /// What ``SheetPresentation/showCommunityHike(_:)`` clears when a
    /// different trail is tapped, so one preview replaces the last rather
    /// than stacking onto it.
    var isCommunityPreview: Bool {
        switch self {
        case .communityHike, .communityPhoto: true
        case .hike, .newPlace, .pendingPhotos, .pendingSubmission, .photo, .place, .placesAround, .recording,
            .routeStyle, .totals, .trailDraft, .walk:
            false
        }
    }

    /// Whether this route wants the whole sheet. Both photo viewers do: each
    /// draws one picture and nothing else, and a picture in the medium detent
    /// is a stamp. Whose picture it is changes nothing about that.
    var prefersFullHeight: Bool {
        switch self {
        case .communityPhoto, .photo: true
        case .communityHike, .hike, .newPlace, .pendingPhotos, .pendingSubmission, .place, .placesAround, .recording,
            .routeStyle, .totals, .trailDraft, .walk:
            false
        }
    }

    // Spelled out rather than synthesized, because the compiler cannot see
    // `HikeWalk`'s `PersistentModel` conformance from here: `Hike` names
    // `\HikeWalk.hike` in its relationship and `HikeWalk` names `Hike`, and
    // the two macro expansions refer to each other. The identities compared
    // are the ones the synthesis would have used.
    static func == (lhs: Self, rhs: Self) -> Bool {
        if lhs.isAboutPlaces || rhs.isAboutPlaces { return placeRoutesEqual(lhs, rhs) }
        return switch (lhs, rhs) {
        case let (.hike(left), .hike(right)): left == right
        case let (.routeStyle(left), .routeStyle(right)): left == right
        case let (.photo(left, leftPhoto), .photo(right, rightPhoto)): left == right && leftPhoto == rightPhoto
        // The three that carry nothing are equal to themselves and to nothing
        // else, which is one rule rather than three.
        case (.recording, .recording), (.trailDraft, .trailDraft), (.totals, .totals): true
        case let (.walk(left), .walk(right)): left.persistentModelID == right.persistentModelID
        case let (.communityHike(left), .communityHike(right)): left.id == right.id
        // The listing and the page, and deliberately not the photographs: the
        // array is the one the strip was showing when it was tapped, and two
        // pushes of the same picture of the same hike are the same screen.
        case let (.communityPhoto(left, _, leftIndex), .communityPhoto(right, _, rightIndex)):
            left.id == right.id && leftIndex == rightIndex
        case let (.pendingSubmission(left), .pendingSubmission(right)): left.id == right.id
        case let (.pendingPhotos(left), .pendingPhotos(right)): left.id == right.id
        default: false
        }
    }

    /// Whether this is one of the three routes about a hike's places.
    private var isAboutPlaces: Bool {
        switch self {
        case .newPlace, .place, .placesAround: true
        default: false
        }
    }

    /// `==` for the three routes about a hike's places — split from `==` so
    /// that switch stays inside the complexity limit.
    private static func placeRoutesEqual(_ lhs: Self, _ rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.place(left, leftPlace), .place(right, rightPlace)): left == right && leftPlace == rightPlace
        case let (.newPlace(left, leftSpot), .newPlace(right, rightSpot)): left == right && leftSpot == rightSpot
        case let (.placesAround(left), .placesAround(right)): left == right
        default: false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case let .hike(hike):
            hasher.combine(0)
            hasher.combine(hike)
        case let .photo(hike, photoID):
            hasher.combine(1)
            hasher.combine(hike)
            hasher.combine(photoID)
        case .recording:
            hasher.combine(2)
        case let .walk(walk):
            hasher.combine(3)
            hasher.combine(walk.persistentModelID)
        case .communityHike, .communityPhoto, .pendingSubmission, .pendingPhotos:
            hashCommunity(into: &hasher)
        case .trailDraft:
            hasher.combine(8)
        case .totals:
            hasher.combine(11)
        case let .routeStyle(hike):
            hasher.combine(12)
            hasher.combine(hike)
        case let .place(hike, placeID):
            hasher.combine(9)
            hasher.combine(hike)
            hasher.combine(placeID)
        case let .newPlace(hike, spot):
            hasher.combine(10)
            hasher.combine(hike)
            hasher.combine(spot)
        case let .placesAround(hike):
            hasher.combine(13)
            hasher.combine(hike)
        }
    }

    /// The four routes about the shared list, which hash by record names —
    /// split from ``hash(into:)`` so that switch stays inside the complexity
    /// limit.
    private func hashCommunity(into hasher: inout Hasher) {
        switch self {
        case let .communityHike(listing):
            hasher.combine(4)
            // The listing's record name alone, matching `==` above: the rest
            // of a listing is a snapshot of a record a reviewer can edit, and
            // two pushes of the same hike a minute apart are the same screen.
            hasher.combine(listing.id)
        case let .communityPhoto(listing, _, index):
            hasher.combine(6)
            // The two things `==` compares, for the reason it gives.
            hasher.combine(listing.id)
            hasher.combine(index)
        case let .pendingSubmission(pending):
            hasher.combine(5)
            // The notice's record name, for the reason above: the fields
            // beside it are a snapshot of a submission, and two pushes of the
            // same queue entry are the same screen.
            hasher.combine(pending.id)
        case let .pendingPhotos(pending):
            hasher.combine(7)
            hasher.combine(pending.id)
        case .hike, .newPlace, .photo, .place, .placesAround, .recording, .routeStyle, .totals, .trailDraft, .walk:
            break
        }
    }
}
