//
//  CommunityPublisher.swift
//  OpenHikes
//
//  Turning a hike the walker owns into a submission somebody may one day
//  review.
//
//  The shape is ``HikeImport``'s, run backwards, and for the same reason: the
//  interesting part is not the happy path but what is left behind when it
//  fails. An upload is the longest piece of work in this app that a walker
//  waits on — a route, a dozen re-encoded photographs, and a round trip — and
//  it can fail in the middle of any of it. So the temporary directory holding
//  the re-encoded copies is created here, owned here, and deleted here on
//  every exit, and the only durable trace a submission leaves on the device is
//  written *after* CloudKit has accepted it.
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
    /// and nothing in the app can say whether they have.
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
    /// paid by somebody other than the walker choosing: the public database's
    /// asset quota, which this app pays for, and the download of anyone who
    /// opens the hike. A dozen pictures is a generous account of a walk;
    /// ninety is an album, and nobody browsing scrolls one.
    static let maximumPhotos = 12

    /// Shares `hike`, waiting for CloudKit to accept it.
    ///
    /// - Parameter authorName: What to publish it under. The walker's own
    ///   words — see ``SettingsKey/communityAuthorName``.
    /// - Parameter save: The commit seam, the same shape ``HikeImport`` and
    ///   ``HikePhotoImport`` take theirs in, so a suite can refuse it.
    @MainActor
    static func share(
        _ hike: Hike,
        authorName: String,
        transport: any CommunityTransporting,
        store: HikePhotoStore = .shared,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) async -> CommunityShareOutcome {
        guard hike.pointCount >= 2 else { return .refused(.nothingToShare) }

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
        let photos = selectedPhotos(of: hike)

        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CommunityShare-\(details.hikeID.uuidString)",
                isDirectory: true
            )
        defer { discard(workingDirectory) }

        let draft = await prepare(
            details,
            photos: photos,
            in: workingDirectory,
            store: store
        )

        let submissionID: String
        do {
            submissionID = try await transport.submit(draft)
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
        if let context = hike.modelContext {
            do {
                try save(context)
            } catch {
                // The submission is real either way, so this is not a failed
                // share. What is lost is only the device's memory of it, which
                // costs the walker a share button that offers to send a hike
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

    /// Which of a hike's photographs go, and in what order.
    ///
    /// Anchored ones first, because a photograph with no place on the route is
    /// the one least worth somebody else's download: the whole point of
    /// carrying pictures with a shared trail is that they sit on the map where
    /// they were taken. Within that, chronological — the order the walk
    /// produced them in, which is the order the gallery pages through.
    @MainActor
    private static func selectedPhotos(of hike: Hike) -> [HikePhoto] {
        let ordered = hike.orderedPhotos
        let anchored = ordered.filter(\.isAnchored)
        let unanchored = ordered.filter { !$0.isAnchored }
        return Array((anchored + unanchored).prefix(maximumPhotos))
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
    ) async -> CommunitySubmissionDraft {
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        var pins: [CommunityPhotoPin] = []
        var urls: [URL] = []
        for (index, photo) in photos.enumerated() {
            // A photo that will not encode is dropped rather than failing the
            // share. One unreadable file should cost its own picture and not
            // the walk — and the pin is appended only alongside a file that
            // exists, which is what keeps the two arrays describing each
            // other. See ``CommunityHikeDetail/isConsistent``.
            guard let url = store.exportCopy(
                of: photo,
                maxPixelSize: photoMaxPixelSize,
                quality: photoQuality,
                named: "photo-\(index).jpeg",
                into: directory
            ) else { continue }
            urls.append(url)
            pins.append(
                CommunityPhotoPin(capturedAt: photo.capturedAt, coordinate: photo.coordinate)
            )
        }

        return CommunitySubmissionDraft(
            hikeID: details.hikeID,
            title: details.title,
            authorName: details.authorName,
            trackDescription: details.trackDescription,
            hikeDate: details.hikeDate,
            distanceMeters: details.distanceMeters,
            route: details.route,
            photoPins: pins,
            photoFileURLs: urls
        )
    }

    /// Removes the re-encoded copies, whatever happened.
    ///
    /// Fire-and-forget and off the main actor, in the shape the photo and tile
    /// deletions already use: what is left behind on a kill is wasted space in
    /// a temporary directory the system reclaims on its own, which is the
    /// cheapest failure in this file.
    private static func discard(_ directory: URL) {
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
