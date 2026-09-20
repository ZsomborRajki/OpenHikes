//
//  CommunityPublisher.swift
//  OpenHikes
//
//  Turning a hike the hiker owns into a submission somebody may one day
//  review.
//
//  The shape is ``HikeImport``'s, run backwards, and for the same reason: the
//  interesting part is not the happy path but what is left behind when it
//  fails. An upload is the longest piece of work in this app that a hiker
//  waits on — a route, a dozen re-encoded photographs, and a round trip — and
//  it can fail in the middle of any of it. So the temporary directory holding
//  everything the attempt writes to disk — the re-encoded copies and the JSON
//  the transport hands CloudKit as assets — is created here, owned here, and
//  deleted here on every exit, and the only durable trace a submission leaves
//  on the device is written *after* CloudKit has accepted it.
//
//  That ordering is the whole of the contract. ``Hike/communitySubmissionID``
//  is what the share button reads to say a hike has already been sent, and
//  writing it before the upload landed would make a failed share look like a
//  successful one forever — with no way back, since this app cannot query its
//  own submissions to find out.
//

import CoreLocation
import Foundation
import os
import SwiftData

/// What one attempt to share a hike did.
enum CommunityShareOutcome: Equatable {
    case refused(CommunityFailure)
    /// Accepted. Not the same as published: a human still has to look at it,
    /// and at this point nothing has. Whether they later did is asked
    /// afterwards and elsewhere — ``CommunityPublicationCheck`` looks for the
    /// listing, which is the one observation this app can make.
    case submitted
}

/// Everything about a hike that is read off the `@Model` before any
/// suspension, gathered into one value that can cross to the encoding
/// executor.
///
/// A struct rather than eight arguments because that is what it is: the whole
/// of the hike, lifted off the main actor in one place so there is exactly one
/// line in this file that touches a `@Model`. ``GPXExport/Track`` exists for
/// the same reason, and this is deliberately *not* that type — a GPX track and
/// a published hike are two different subsets that would drift the moment
/// either grew a field.
nonisolated struct SharedHikeDetails: Sendable {
    var hikeID: UUID
    var title: String
    var authorName: String
    var trackDescription: String?
    var hikeDate: Date
    var distanceMeters: Double
    var route: [RouteCoordinate]
}

/// A draft, and which of the hike's photographs actually went into it.
///
/// The two are returned together because the second cannot be worked out from
/// the first. A draft carries files and pins and no identity at all — by
/// design, since what reaches CloudKit is bytes — while the stamp that stops a
/// picture being offered twice is keyed on ``HikePhoto/id``. Asking the disk a
/// second time afterwards would be a different question with a different
/// answer: the encode is what decides, and it drops a row whose pixels are on
/// another device or whose file will not read.
///
/// ``ContributedPhotoDetails``'s counterpart wraps ``CommunityPhotoDraft`` the
/// same way, and both stay out of the draft types themselves: those are the
/// payload, and every field on one is a field
/// ``CommunityShareDisclosure`` has to account for.
nonisolated struct StagedSubmission: Sendable {
    var draft: CommunitySubmissionDraft
    /// In upload order, and only the pictures a file was written for.
    var photoIDs: [UUID]
}

nonisolated enum CommunityPublisher {
    private static let logger = Logger(subsystem: "OpenHikes", category: "Community")

    /// Longest edge of a published photograph, in pixels.
    ///
    /// Comfortably sharper than a phone screen and far under a capture. The
    /// number is a quota decision as much as a quality one — see
    /// ``HikePhotoStore/exportCopy(of:maxPixelSize:quality:named:into:)``.
    static let photoMaxPixelSize = 1600
    static let photoQuality = 0.7
    /// How many photographs one shared hike may carry.
    ///
    /// A cap rather than all of them, because the two costs it bounds are both
    /// paid by somebody other than the hiker choosing: the public database's
    /// asset quota, which this app pays for, and the download of anyone who
    /// opens the hike.
    ///
    /// It was a dozen, on the argument that a dozen is a generous account of a
    /// walk and ninety is an album nobody browsing scrolls. The argument about
    /// *reading* still stands and is not what the number is set by — the
    /// gallery pages one picture at a time and always did. What set it at
    /// twelve was the bill, and the bill is a forecast: nothing is published
    /// yet, so the quota this bounds is being spent by nobody. Raised to
    /// thirty-six while that is true, which is three times the account a walk
    /// needs and still an order of magnitude under a day's camera roll.
    ///
    /// **This is the number to bring back down first** if the public
    /// database's asset quota becomes a real cost, and it is the cheapest
    /// lever there is: it is read in one place on the way up
    /// (``selectedPhotos(of:excluding:)``) and quoted rather than restated
    /// everywhere else, so lowering it changes what new uploads carry and
    /// nothing about what is already published. At
    /// ``photoMaxPixelSize``/``photoQuality`` a published photograph is a few
    /// hundred kilobytes, so this is the difference between roughly four
    /// megabytes an upload and twelve.
    static let maximumPhotos = 36

    /// Shares `hike`, waiting for CloudKit to accept it.
    ///
    /// - Parameter authorName: What to publish it under. The hiker's own
    ///   words — see ``SettingsKey/communityAuthorName``.
    /// - Parameter save: The commit seam, the same shape ``HikeImport`` and
    ///   ``HikePhotoImport`` take theirs in, so a suite can refuse it.
    ///
    /// Nothing here asks what the hiker has paid for. Publishing sat behind
    /// the Pro subscription once and no longer does, and what that gate was
    /// never doing is worth keeping written down: the thing that keeps an
    /// unreviewed route off other people's screens is the schema — see
    /// ``CommunitySchema`` — which a client-side check of any kind could only
    /// ever have agreed with.
    /// - Parameter excludingPhotos: The photographs the hiker struck off on
    ///   the share form, by id. Applied *before* the cap, deliberately: taking
    ///   a picture out should let the next one in rather than simply shorten
    ///   the upload, which is the difference between choosing twelve and
    ///   getting whichever eleven were left over.
    @MainActor
    static func share(
        _ hike: Hike,
        authorName: String,
        transport: any CommunityTransporting,
        excludingPhotos excluded: Set<UUID> = [],
        store: HikePhotoStore = .shared,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) async -> CommunityShareOutcome {
        guard hike.pointCount >= 2 else { return .refused(.nothingToShare) }
        // The two rules that need nothing but this hike, re-checked here for
        // the same reason the point floor above is: the form's Share button
        // holds both, and this is the one function that can actually start an
        // upload. The retread rule is not among them — it needs a fetch, and
        // a publisher that went looking for other hikes would be doing the
        // form's job from inside the send.
        let eligibility = CommunityPublishingEligibility.of(
            importedFromListingID: hike.importedFromListingID,
            importedAuthorName: hike.importedAuthorName,
            distanceMeters: hike.distanceMeters
        )
        if let reason = eligibility.reason { return .refused(.notEligible(reason)) }

        // Everything read off the `@Model` happens here, on the main actor and
        // before any suspension. A `Hike` cannot cross to the executor that
        // does the encoding, and re-reading one after an await is how a row
        // deleted mid-upload turns into a crash rather than a failure.
        let details = SharedHikeDetails(
            hikeID: hike.id,
            title: hike.displayTitle,
            authorName: authorName,
            trackDescription: hike.trackDescription,
            hikeDate: hike.date,
            distanceMeters: hike.distanceMeters,
            route: hike.route
        )
        let photos = selectedPhotos(of: hike, excluding: excluded)

        // One directory per *attempt*, not per hike, and under the parent a
        // sweep can reach — see ``CommunityStaging``. The `defer` below is the
        // ordinary way this directory goes, and the sweep is for the way it
        // does not: being killed mid-upload is how a long share in the
        // background usually ends, and a `defer` is code that has to get to
        // run.
        let workingDirectory = CommunityStaging.shareDirectory(of: details.hikeID)
        CommunityStaging.sweep()
        defer { CommunityStaging.discard(workingDirectory) }

        let staged = await prepare(
            details,
            photos: photos,
            in: workingDirectory,
            store: store
        )

        let submissionID: String
        do {
            submissionID = try await transport.submit(staged.draft)
        } catch {
            let failure = error as? CommunityFailure ?? .unavailable(error.localizedDescription)
            logger.error(
                "Sharing a hike failed: \(failure.localizedDescription, privacy: .public)"
            )
            return .refused(failure)
        }

        // The upload landed, and only now is anything written down. The hike
        // may have been deleted while it was in flight — a share is a long
        // wait and the list is one tap away — in which case the submission
        // stands and there is simply nothing here left to remember it.
        guard hike.isAttached else { return .submitted }
        hike.communitySubmissionID = submissionID
        // Both columns, together, because they describe one submission between
        // them: ``Hike/communityListingID`` caches an answer about whichever
        // submission ``Hike/communitySubmissionID`` names, and the moment that
        // name changes the cached answer is about a hike nobody is asking
        // after any more. Leaving it would say *published* about a copy no
        // reviewer has seen, and — worse, because it is silent —
        // ``CommunityPublicationCheck`` skips a hike that already has a
        // listing, so the new submission would never be asked about at all.
        //
        // The listing itself is untouched by this; a published hike stays
        // published and stays findable. What is cleared is only this device's
        // record of it, which is what the share form promises when it says the
        // published copy stays as it is.
        hike.communityListingID = nil
        // In the same commit as the two columns above, and for a version of
        // their reason: these stamps say which pictures are now in the public
        // database, and a hike whose submission was recorded without them
        // would offer every one of them again as though it were new. See
        // ``HikePhoto/sentToCommunityAt``.
        markSent(staged.photoIDs, on: hike)
        if let context = hike.modelContext {
            do {
                try save(context)
            } catch {
                // The submission is real either way, so this is not a failed
                // share. What is lost is only the device's memory of it, which
                // costs the hiker a share button that offers to send a hike
                // that is already sent.
                logger.error(
                    """
                    Shared a hike but could not record it locally: \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
            }
        }
        return .submitted
    }

    /// How many of `hike`'s photographs this device could actually send.
    ///
    /// The number the share form quotes, asked of the disk rather than of the
    /// rows. Photo *rows* mirror between a hiker's devices and photo *files*
    /// do not — see ``HikePhotoStore/hasImage(for:)`` and *Settled decisions*
    /// in the repository instructions — so a walk recorded on a phone has a
    /// full strip of pictures on the iPad and nothing behind any of them.
    /// ``prepare(_:photos:in:store:)`` drops exactly those, silently and
    /// correctly, which is why the form has to ask the same question rather
    /// than count the rows.
    ///
    /// Counted over ``selectedPhotos(of:)`` so the cap and the ordering are
    /// the upload's, not a second opinion about them.
    @MainActor
    static func sendablePhotoCount(
        of hike: Hike,
        excludingPhotos excluded: Set<UUID> = [],
        store: HikePhotoStore = .shared
    ) async -> Int {
        await reachablePhotoCount(
            of: selectedPhotos(of: hike, excluding: excluded),
            store: store
        )
    }

    /// `@concurrent` for the reason ``prepare(_:photos:in:store:)`` is, and
    /// for one more: ``HikePhotoStore/hasImage(for:)`` asserts it is off the
    /// main thread, because it touches the file system once per photograph.
    @concurrent
    private static func reachablePhotoCount(
        of photos: [HikePhoto],
        store: HikePhotoStore
    ) async -> Int {
        photos.filter { store.hasImage(for: $0) }.count
    }

    /// Which of a hike's photographs go, and in what order.
    ///
    /// Anchored ones first, because a photograph with no place on the route is
    /// the one least worth somebody else's download: the whole point of
    /// carrying pictures with a shared trail is that they sit on the map where
    /// they were taken. Within that, chronological — the order the walk
    /// produced them in, which is the order the gallery pages through.
    /// Struck-off pictures are dropped *before* the cap, which is what makes
    /// the share form's strip a choice rather than a subtraction: a hiker with
    /// twenty photographs who strikes off the first can have the thirteenth,
    /// where filtering afterwards would simply have sent eleven.
    ///
    /// A photograph that came with somebody else's hike is not here at all,
    /// and that exclusion is nearer a safety rail than a rule about order —
    /// see ``ownPhotos(of:)``.
    ///
    /// Internal rather than private so the form can draw the same list in the
    /// same order the upload will use. A screen that built its own order would
    /// eventually disagree with this one about which twelve go.
    @MainActor
    static func selectedPhotos(of hike: Hike, excluding excluded: Set<UUID> = []) -> [HikePhoto] {
        let ordered = ownPhotos(of: hike).filter { !excluded.contains($0.id) }
        let anchored = ordered.filter(\.isAnchored)
        let unanchored = ordered.filter { !$0.isAnchored }
        return Array((anchored + unanchored).prefix(maximumPhotos))
    }

    /// The pictures a form must open with struck off: the ones a copy of
    /// which is already up there.
    ///
    /// Here rather than inside the form for the reason ``selectedPhotos(of:excluding:)``
    /// is here: what goes and what stays is the publisher's rule, and a screen
    /// that worked it out for itself would eventually disagree with the send
    /// it is describing. It is also the half of that rule a suite can reach —
    /// a `View`'s `init` is not.
    @MainActor
    static func alreadySentPhotoIDs(of hike: Hike) -> Set<UUID> {
        // Over ``ownPhotos(of:)`` rather than over every row, so this set and
        // the strip are two readings of one list. A photograph that came with
        // somebody else's hike can never have been sent from here anyway —
        // that gate is in front of both senders — so the filter changes no
        // answer today. It is here because the day it does change one, the
        // form would be striking off a tile it is not drawing.
        Set(ownPhotos(of: hike).filter(\.hasBeenSentToCommunity).map(\.id))
    }

    /// Writes down that these pictures are now in the public database.
    ///
    /// Called by both senders — the hike share and the photo contribution —
    /// because a copy is a copy however it got there, and the forms that offer
    /// photographs ask only whether one already went. It does not save; the
    /// caller does, in the same commit as the record names it is writing
    /// beside, so a hike can never be seen remembering a submission it has no
    /// stamps for or stamps for a submission it has forgotten.
    ///
    /// Idempotent in the way that matters: a picture sent twice keeps the
    /// *first* stamp, because what the forms read is whether one exists at
    /// all, and moving it would be a claim nobody makes use of.
    @MainActor
    static func markSent(_ photoIDs: [UUID], on hike: Hike, at date: Date = .now) {
        guard !photoIDs.isEmpty else { return }
        let sent = Set(photoIDs)
        // Read out, stamped, and written back once. Mutating through
        // ``Hike/photos`` in place would send every element assignment
        // through the model's accessor and copy the whole array again for
        // each one, which is a dozen rewrites of a blob to change a dozen
        // dates in it.
        var photos = hike.photos
        var stampedAny = false
        for index in photos.indices
        where sent.contains(photos[index].id) && !photos[index].hasBeenSentToCommunity {
            photos[index].sentToCommunityAt = date
            stampedAny = true
        }
        guard stampedAny else { return }
        hike.photos = photos
    }

    /// Every photograph the form offers, in the order the upload would take
    /// them — including the ones struck off, which still have to be drawn so
    /// they can be put back.
    @MainActor
    static func shareablePhotos(of hike: Hike) -> [HikePhoto] {
        let ordered = ownPhotos(of: hike)
        return ordered.filter(\.isAnchored) + ordered.filter { !$0.isAnchored }
    }

    /// A hike's photographs minus the ones that came with somebody else's
    /// listing, in the hike's own order.
    ///
    /// The single gate both paths above go through, so *what may be published*
    /// is decided in one place rather than agreed on by two.
    ///
    /// It matters most on the path that looks least like publishing. A hike
    /// saved from the community carries a copy of its author's pictures — see
    /// ``CommunityImport`` — and is precisely the hike the contribution form
    /// then offers to add photographs to, aimed at the trail those pictures
    /// came from. Drawing them there would put somebody else's work in a strip
    /// that is pre-selected and one tap from being sent back under a different
    /// credit. On the hike-share path it can never fire, because an imported
    /// hike is refused a listing of its own — which is a reason to keep the
    /// gate here rather than to put it on the caller that needs it: the two
    /// forms must not be able to disagree about this.
    @MainActor
    static func ownPhotos(of hike: Hike) -> [HikePhoto] {
        // `recordsPlaceOnly` is a second thing this gate refuses, and it is
        // refused here for the same reason: there is no picture behind such a
        // row at all — it is a `<wpt>` read out of an imported `.gpx` — so
        // offering it would put a tile in the form that can never upload
        // anything. The encode drops it downstream regardless; what this
        // prevents is the hiker selecting it and being told nothing went.
        hike.orderedPhotos.filter { $0.isOwn && !$0.recordsPlaceOnly }
    }

    /// Re-encodes the photographs and assembles the draft, entirely off the
    /// main actor.
    ///
    /// `@concurrent` rather than a bare `nonisolated async`: with
    /// `SWIFT_APPROACHABLE_CONCURRENCY` the latter runs on its caller's
    /// executor, and the caller here is the main actor — which would put a
    /// dozen JPEG encodes on the thread drawing the progress view that is
    /// reporting them.
    @concurrent
    private static func prepare(
        _ details: SharedHikeDetails,
        photos: [HikePhoto],
        in directory: URL,
        store: HikePhotoStore
    ) async -> StagedSubmission {
        let staged = CommunityStaging.stagePhotos(photos, into: directory, store: store)
        let draft = CommunitySubmissionDraft(
            hikeID: details.hikeID,
            title: details.title,
            authorName: details.authorName,
            trackDescription: details.trackDescription,
            hikeDate: details.hikeDate,
            distanceMeters: details.distanceMeters,
            route: details.route,
            photoPins: staged.pins,
            photoFileURLs: staged.fileURLs,
            stagingDirectory: directory
        )
        return StagedSubmission(draft: draft, photoIDs: staged.photoIDs)
    }
}
