//
//  OfflineCountries+Extras.swift
//  OpenHikes
//
//  What *Extra Detail* and *Elevation Data* mean for an area already down:
//  an offer on its row, and nothing until the hiker takes it.
//
//  The two switches say what the hiker means to keep, and a download reads
//  them as it starts. They used to be carried out on every area the moment
//  one was flipped: on, each area down brought its zoom 15 or its heights,
//  which for a few countries is gigabytes nobody had been shown the size of;
//  off, each lost them. By the owner's decision a flip now changes nothing
//  on the device. An area that holds less than the switches ask for offers
//  the rest, at its size (``OfflineCountries/addition(to:)``), and one that
//  holds what they no longer ask for offers to delete it
//  (``OfflineCountries/removal(from:)``). A tap on the offer is the whole of
//  the asking: it starts the download, or deletes the files, with no alert
//  between. Deleting the area itself, by its swipe, is as it was.
//
//  One offer each way, for everything the switches differ by, rather than
//  one a switch: the switches are where the hiker says which of the two is
//  meant, and the offer brings the area to that.
//

import Foundation

/// The parts of an area a switch decides: its zoom 15, which is *Extra
/// Detail*'s, and its heights, which are *Elevation Data*'s.
nonisolated struct OfflineCountryExtras: OptionSet, Hashable, Sendable {
    let rawValue: Int

    static let detail = Self(rawValue: 1 << 0)
    static let elevation = Self(rawValue: 1 << 1)

    /// The part a file of `role` belongs to: none, for a file every
    /// download takes.
    static func part(of role: OfflineCountryManifest.Role) -> Self {
        if role.isDetail { return .detail }
        return role.isElevation ? .elevation : []
    }
}

/// What a downloaded area's row offers to add to it, or to delete from it.
nonisolated struct OfflineCountryOffer: Equatable, Sendable {
    /// The parts it adds or deletes.
    let extras: OfflineCountryExtras
    /// The files it brings down or deletes.
    let files: [OfflineCountryManifest.File]

    /// What it takes to bring, or what deleting it frees.
    var byteCount: Int64 { files.reduce(0) { $0 + $1.byteCount } }
}

nonisolated extension OfflineCountryManifest.Role {
    /// Whether a switch decides if an area has a file of this role, where a
    /// file of any other is one every download takes.
    var isOptional: Bool { isDetail || isElevation }
}

extension OfflineCountries {
    /// What the switches ask for that the area `id` lacks, for its row to
    /// offer and ``extend(_:)`` to bring.
    ///
    /// `nil` where it lacks none of it, and where it cannot be brought on
    /// its own: while a download of the area is under way or has failed,
    /// whose row is that download's; while a file of it will not open, which
    /// is mended first; and where the list does not offer the build that is
    /// down. A newer build is an update, which takes what the switches say
    /// as any download does, and the server deletes the build it moved past.
    func addition(to id: String) -> OfflineCountryOffer? {
        guard let record = installed[id], downloads[id] == nil, !needsRepair(id),
              let listed = offeredBuild(of: record)
        else { return nil }
        let held = Set(record.files.map(\.fileName))
        let asked = listed.files.filter { $0.role.isOptional && wants($0.role) && !held.contains($0.fileName) }
        guard !asked.isEmpty else { return nil }
        // With what the build gained that every download takes, should it
        // not be down yet: see ``begin(_:bringing:)``.
        let files = Self.gained(by: listed, since: record) + asked
        return OfflineCountryOffer(extras: Self.extras(of: asked), files: files)
    }

    /// What the area `id` holds that the switches no longer ask for, for its
    /// row to offer and ``trim(_:)`` to delete. `nil` where it holds none,
    /// and while a download of the area is under way or has failed. Offered
    /// whatever the list says, since deleting needs no server.
    func removal(from id: String) -> OfflineCountryOffer? {
        guard let record = installed[id], downloads[id] == nil else { return nil }
        let unasked = record.files.filter { !wants($0.role) }
        guard !unasked.isEmpty else { return nil }
        return OfflineCountryOffer(extras: Self.extras(of: unasked), files: unasked)
    }

    /// Brings the area `id` what ``addition(to:)`` offers: the hiker's tap
    /// on that offer, and the only way a switch's files reach an area
    /// already down.
    func extend(_ id: String) {
        guard let record = installed[id], let listed = offeredBuild(of: record), let offer = addition(to: id)
        else { return }
        begin(listed, bringing: offer.files)
    }

    /// Deletes from the area `id` what ``removal(from:)`` offers, and keeps
    /// the area: the hiker's tap on that offer, and the only way a switch
    /// turned off takes anything off the device.
    func trim(_ id: String) {
        guard let record = installed[id], let offer = removal(from: id) else { return }
        strip(offer.files, from: record)
    }

    nonisolated private static func extras(of files: [OfflineCountryManifest.File]) -> OfflineCountryExtras {
        files.reduce(into: []) { $0.formUnion(.part(of: $1.role)) }
    }
}
