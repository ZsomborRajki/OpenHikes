//
//  OfflineStorageAlerts.swift
//  OpenHikes
//
//  The two alerts a hike's offline-storage row can raise, chief among them the
//  confirmation in front of the one path that deletes offline coverage a hike
//  still claims.
//
//  A provider whose terms cap durable storage — Stadia's 100 MB per device —
//  can be full of another route's tiles when a new download is asked for. The
//  download stops at ``OfflineTileDownloader/Phase/needsSpace(_:)`` before
//  fetching or deleting anything, and this is what turns that into a question.
//  Dismissing it by any route cancels the download and leaves every saved map
//  exactly as it was.
//

import SwiftUI

private struct OfflineStorageAlerts: ViewModifier {
    let downloader: OfflineTileDownloader
    @Binding var deletionFailed: Bool

    func body(content: Content) -> some View {
        content
        .alert("Couldn’t Delete Offline Tiles", isPresented: $deletionFailed) {
            Button("OK", role: .cancel) { /* dismiss */ }
        } message: {
            Text(
                "OpenHikes couldn’t read the other hikes’ offline coverage."
                + " No tiles were deleted."
            )
        }
        .alert(
            "Not Enough Space for This Map",
            isPresented: Binding(
                get: { downloader.pendingSpaceShortfall != nil },
                set: { presented in
                    guard !presented, downloader.pendingSpaceShortfall != nil else { return }
                    downloader.cancel()
                }
            ),
            presenting: downloader.pendingSpaceShortfall
        ) { _ in
            Button("Free Up Space", role: .destructive) {
                downloader.confirmReclaimingSpace()
            }
            Button("Cancel", role: .cancel) {
                downloader.cancel()
            }
        } message: { shortfall in
            Text(Self.reclaimMessage(for: shortfall))
        }
    }

    /// Names what freeing space costs, in the terms the licence sets it in.
    ///
    /// A user has no reason to expect a map app to have a storage ceiling
    /// unrelated to their phone's free space, so the message says whose limit
    /// it is and what will be given up — never "some tiles".
    static func reclaimMessage(for shortfall: OfflineTileDownloader.SpaceShortfall) -> String {
        let limit = ByteCountFormatter.string(fromByteCount: shortfall.limit, countStyle: .file)
        let freeing = ByteCountFormatter.string(
            fromByteCount: shortfall.bytesToFree,
            countStyle: .file
        )
        return "\(shortfall.providerName) allows \(limit) of saved maps on this device, and that’s"
            + " already in use. Saving this route will delete about \(freeing) of your"
            + " least-recently-used saved tiles from other hikes."
            + "\n\nThose hikes keep their routes, and their maps refill the next time you view"
            + " them online."
    }
}

extension View {
    /// Both alerts together rather than separately: they belong to the same
    /// screen's storage state, and a detail view already at its length limit
    /// should not carry either of them inline.
    func offlineStorageAlerts(
        downloader: OfflineTileDownloader,
        deletionFailed: Binding<Bool>
    ) -> some View {
        modifier(OfflineStorageAlerts(downloader: downloader, deletionFailed: deletionFailed))
    }
}
