//
//  CommunityBlockList.swift
//  OpenHikes
//
//  The people this device has decided it does not want to see hikes from.
//
//  App Store Guideline 1.2 asks an app carrying user-generated content for two
//  things, and this is the half that is not ``CommunityReport``: reporting asks
//  a person to look at something, blocking hides it for the hiker who blocked
//  it and takes nothing down. They sit next to each other in the toolbar of
//  ``CommunityHikeView`` because they are one gesture in most apps, and they
//  are not the same gesture — a block is a reader's control, and a hiker who
//  wants a hike removed for everybody has to report it.
//
//  ## Why this is device-local and has no schema
//
//  Browsing is account-free by design: public reads need no Apple Account,
//  which is why a signed-out phone can find a published hike and open one. The
//  public database accepts a *write* only from an authenticated account, so a
//  block that lived in CloudKit would be missing for exactly the hikers the
//  account-free flow exists for — the same argument that made reporting an
//  email rather than a record type, reaching the same answer for a different
//  reason. A list on the device needs no account, no network and no record
//  type, and blocking is the kind of thing that is *supposed* to be one
//  person's opinion rather than a fact about the hike.
//
//  What that costs is a list that does not follow the hiker to a new phone.
//  Deliberately not synced through ``SyncedSettings``: see
//  ``SettingsKey/communityBlockedAuthors``.
//
//  ## Why it is keyed on `authorID` and not on a name
//
//  ``CommunityListing/authorName`` is free text the hiker types when they
//  share — chosen precisely because it is not an identity, so that publishing
//  a trail does not mean publishing an Apple Account. Two people may type the
//  same name and one person may type a different one every time, so a list
//  keyed on it would block a string rather than a person, and would fail open
//  for anybody deliberately evading it. ``CommunityListing/authorID`` is the
//  creator CloudKit stamps on the submission, denormalised onto the listing at
//  publication so the browse query has it — see
//  ``CommunitySchema/Listing/authorID``.
//
//  The name is kept alongside it anyway, and only for the Settings row: a list
//  of opaque record names is one nobody can undo an entry in. It is a *label
//  recorded at the moment of blocking*, not a second key, and nothing matches
//  on it.
//

import Foundation
import Observation
import os

/// The blocked authors, and the one place a block is made or undone.
///
/// A stable `@Observable` reference type held by ``OpenHikesModel`` rather
/// than `@AppStorage` on a view, for two reasons. The list is read by
/// ``CommunityBrowser`` and written by a screen pushed over it, so no single
/// view owns it; and `@AppStorage` on a `[String]` is a stringly-typed round
/// trip that cannot carry the name and the date a Settings row needs.
@MainActor
@Observable
final class CommunityBlockList {
    /// Non-isolated so releasing the last reference never requires proving we
    /// are on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// One blocked author, as the device remembers them.
    nonisolated struct BlockedAuthor: Codable, Hashable, Identifiable, Sendable {
        /// The creator CloudKit stamped on the submission. The key, and the
        /// only field anything matches on.
        var id: String
        /// The name the blocked hike was published under, as it read at the
        /// moment of blocking. Shown in Settings so the entry can be
        /// recognised and undone; empty when the author published without one.
        var name: String
        /// Sorts the Settings list newest-first, so the entry a hiker just
        /// made — and may want back — is the one at the top.
        var blockedAt: Date
    }

    @ObservationIgnored private static let logger = Logger(
        subsystem: "OpenHikes",
        category: "Community"
    )

    /// The blocked authors, newest first. What the Settings section draws.
    private(set) var authors: [BlockedAuthor] = []

    /// The same set, for the question that is actually asked — once per row of
    /// every list, on every draw.
    ///
    /// Observed rather than `@ObservationIgnored`, and that is what makes a
    /// block take effect on the list behind the screen it was made from:
    /// ``CommunityBrowser`` filters through this, so a SwiftUI body that drew
    /// the rows has read it and is invalidated when it changes.
    private(set) var blockedIDs: Set<String> = []

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        authors = Self.load(from: defaults)
        blockedIDs = Set(authors.map(\.id))
    }

    var isEmpty: Bool { authors.isEmpty }

    // MARK: - Asking

    func isBlocked(_ listing: CommunityListing) -> Bool {
        blockedIDs.contains(listing.authorID)
    }

    /// `listings` without anything from a blocked author.
    ///
    /// The early return is not a micro-optimisation but the ordinary case: a
    /// hiker who has never blocked anybody pays a `Set.isEmpty` per request
    /// rather than a pass over every row of every draw.
    func excludingBlocked(_ listings: [CommunityListing]) -> [CommunityListing] {
        guard !blockedIDs.isEmpty else { return listings }
        return listings.filter { !blockedIDs.contains($0.authorID) }
    }

    // MARK: - Changing

    /// Blocks whoever published `listing`, or does nothing if they already are.
    ///
    /// Takes a listing rather than an id so the name can be recorded with it —
    /// see ``BlockedAuthor/name``, which exists only so the entry can be
    /// recognised in Settings.
    func block(_ listing: CommunityListing, at date: Date = .now) {
        // Belt and braces: ``CommunityListing/init(record:)`` refuses a record
        // without this field, so an empty one cannot arrive from CloudKit. If
        // one ever did, adding it would block every *other* listing that was
        // also missing the field, which is the one failure a block list must
        // not have.
        guard !listing.authorID.isEmpty else {
            Self.logger.error(
                "Refused to block listing \(listing.id, privacy: .public): it names no author."
            )
            return
        }
        guard !blockedIDs.contains(listing.authorID) else { return }
        authors.insert(
            BlockedAuthor(id: listing.authorID, name: listing.authorName, blockedAt: date),
            at: 0
        )
        blockedIDs.insert(listing.authorID)
        save()
    }

    func unblock(_ id: String) {
        guard blockedIDs.contains(id) else { return }
        authors.removeAll { $0.id == id }
        blockedIDs.remove(id)
        save()
    }

    func unblockAll() {
        guard !authors.isEmpty else { return }
        authors = []
        blockedIDs = []
        save()
    }

    // MARK: - Storage

    /// JSON under one key rather than a key per author.
    ///
    /// Three fields per entry and an order that matters, which a `[String]`
    /// cannot carry — and one write per change rather than a defaults domain
    /// that grows a key for every person a hiker ever blocked.
    private func save() {
        do {
            defaults.set(try JSONEncoder().encode(authors), forKey: SettingsKey.communityBlockedAuthors)
        } catch {
            // The in-memory list is already correct, so the block the hiker
            // just made holds for this launch and is lost on the next one.
            // Nothing to tell them that they could act on, and unwinding the
            // block to match the failed write would be the worse half.
            Self.logger.error(
                "Could not store the blocked authors: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func load(from defaults: UserDefaults) -> [BlockedAuthor] {
        guard let data = defaults.data(forKey: SettingsKey.communityBlockedAuthors) else { return [] }
        do {
            return try JSONDecoder().decode([BlockedAuthor].self, from: data)
        } catch {
            // Read as "nobody is blocked", which is the reading that shows a
            // hiker content they asked not to see — so it is said in the log
            // rather than swallowed. Not erased: a shape this build cannot
            // read is not evidence there is nothing there, and the next launch
            // gets to try again.
            logger.error(
                "Could not read the blocked authors: \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }
}
