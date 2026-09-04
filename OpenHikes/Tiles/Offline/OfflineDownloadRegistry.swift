//
//  OfflineDownloadRegistry.swift
//  OpenHikes
//
//  The one place that knows a bulk download is in flight, so the buttons that
//  delete durable tiles can stand it down before they run.
//
//  A download outlives the screen that started it — that is the whole point of
//  ``OfflineDownloadClaim`` — which means the walker can reach Settings, or
//  another hike's Delete, while tiles are still landing. Those actions take
//  the manifests and the durable directory as they find them, and an in-flight
//  run is invisible to both: its tiles are not claimed yet, so `Clear Map
//  Cache` counts them as reclaimable, and `Delete All Saved Tiles` empties the
//  manifest the run is about to write into. The run then finishes and commits
//  a record for tiles the walker just deleted — coverage resurrected after an
//  explicit deletion, and a hike reporting a saved map that is partly gone.
//
//  Standing the run down instead of racing it is what makes the deletion
//  final. Cancelling bumps the run's generation, so its completion returns
//  before it claims anything (see
//  ``OfflineTileDownloader/finalize(savedKeys:tiles:source:generation:)``), and
//  every decision here happens on the main actor between the deletion's own
//  fetch and its first write — there is no suspension point in that window for
//  a completion to slip through.
//
//  Registrations are weak: a downloader belongs to the screen that made it,
//  and a registry that kept them alive would be a leak per visited hike.
//

import Foundation

final class OfflineDownloadRegistry {
    /// The app's registry. Injected like ``TileCache/shared`` is, so a suite
    /// can hold its own rather than reach across into whatever another test
    /// happens to be downloading.
    static let shared = OfflineDownloadRegistry()

    private struct Registration {
        weak var downloader: OfflineTileDownloader?
    }

    private var registrations: [Registration] = []

    /// Records a downloader that is starting a run. Repeat starts of the same
    /// downloader register it once.
    func track(_ downloader: OfflineTileDownloader) {
        registrations.removeAll { $0.downloader == nil || $0.downloader === downloader }
        registrations.append(Registration(downloader: downloader))
    }

    /// Cancels every run still in flight, and returns how many there were —
    /// which is what a suite can assert on, since a cancelled run leaves no
    /// other trace by design.
    ///
    /// Runs that have already finished, failed or been cancelled are left
    /// alone: they hold no tiles nobody claims, and cancelling one would clear
    /// a result the walker is still reading.
    @discardableResult func standDown() -> Int {
        let live = registrations.compactMap(\.downloader)
        registrations = live.map { Registration(downloader: $0) }
        let running = live.filter(\.isRunning)
        for downloader in running {
            downloader.cancel()
        }
        return running.count
    }
}

@MainActor
extension OfflineTileDownloader {
    /// Whether this downloader has work the walker has not seen the end of —
    /// tiles landing, or a plan parked on the space confirmation. Defined
    /// beside its only caller: it is the question the registry asks, and the
    /// answer is what separates a run holding tiles nobody claims yet from a
    /// finished one whose result is still being read.
    var isRunning: Bool {
        switch phase {
        case .downloading, .needsSpace: true
        case .failed, .finished, .idle: false
        }
    }
}
