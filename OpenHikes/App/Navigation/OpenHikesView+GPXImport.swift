//
//  OpenHikesView+GPXImport.swift
//  OpenHikes
//
//  A picked or opened .gpx file becoming hikes, and the selection that race
//  competes for.
//

import OpenHikesData
import SwiftUI

// MARK: - GPX import

/// Importing, and the selection it competes for, kept out of the view's own
/// file for length — see the internal `@State` block in `OpenHikesView.swift`
/// for why what this reaches is internal rather than private.
extension OpenHikesView {
    /// Parses the picked .gpx files one after another, persists them as
    /// hikes, and leaves the last of them on the map — each file's import
    /// takes the selection in turn, as a lone file's does. A file that can't become a hike raises
    /// ``importReport``'s failure rather than leaving the user looking at an
    /// unchanged screen, and one kept without every place raises its notice —
    /// each once for the lot when several were picked, naming each file,
    /// rather than one alert per file.
    func importGPX(from urls: [URL]) {
        Task {
            var failures: [HikeImportFailure.FileFailure] = []
            var cut: [HikeImportPlaceNotice.File] = []
            for url in urls {
                let outcome = await performImport(from: url, reportsOutcome: urls.count == 1)
                if outcome.placesPastLimit > 0 {
                    cut.append(.init(fileName: url.lastPathComponent, placesPastLimit: outcome.placesPastLimit))
                }
                guard case let .refused(failure) = outcome, failure != .file(.multipleTracks) else { continue }
                failures.append(
                    HikeImportFailure.FileFailure(
                        fileName: url.lastPathComponent,
                        reason: failure.errorDescription ?? ""
                    )
                )
            }
            guard urls.count > 1 else { return }
            if !failures.isEmpty { importReport.failure = .several(failures) }
            if !cut.isEmpty { importReport.placeNotice = HikeImportPlaceNotice(files: cut) }
        }
    }

    func importRequestedGPXFixture() async {
        guard !didProcessLaunchFixture,
              let name = AppLaunchEnvironment.importedGPXFixtureName else { return }
        didProcessLaunchFixture = true
        guard let url = Bundle.main.url(forResource: name, withExtension: "gpx") else {
            importReport.failure = .file(.unreadable)
            return
        }
        let outcome = await performImport(from: url)
        await seedRequestedPhotos(for: outcome.hike)
        seedRequestedWalks(for: outcome.hike)
    }

    /// Imports `url`, and hands back the hike it persisted — whether or not
    /// that hike went on to win the selection below. A caller with something
    /// left to do to the new hike needs the hike itself; reading the selection
    /// afterwards would hand it whatever won the race instead.
    ///
    /// Refused only when the file could not become a *kept* hike, which the
    /// alert this raises is already the report of. The failure is carried out
    /// as well as shown, because what a caller may do with the file next
    /// depends on which of the two failures it was — see
    /// ``HikeImportOutcome``. A hike kept without every place the file marked
    /// raises the notice that says so, and carries the count out the same way
    /// (#1076).
    ///
    /// - Parameter reportsOutcome: whether a refusal or a cut raises its
    ///   alert here, or is left to a caller that is gathering several into
    ///   one. A multi-track file the hiker chose none of is not a failure to
    ///   report either way: they said so.
    func performImport(from url: URL, reportsOutcome: Bool = true) async -> HikeImportOutcome {
        let selectionToken = importSelectionGate.token(
            selectedHikeID: selectedHike?.id,
            path: sheet.path
        )
        #if DEBUG
        // Losing this race needs a navigation or selection change to land in
        // the moment a GPX parse takes, which is not something automation can
        // aim at. A scenario that is about the losing side asks for it here
        // instead; see ``AppLaunchEnvironment/losesImportSelection``.
        if AppLaunchEnvironment.losesImportSelection {
            importSelectionGate.invalidate()
        }
        #endif
        let importedHike: Hike
        let placesPastLimit: Int
        // Typed, so the catch below can't quietly widen to `any Error` and
        // start swallowing something this screen has no message for.
        do throws(HikeImportFailure) {
            let choice = gpxTrackChoice
            let kept = try await HikeImport.hikes(from: url, into: modelContext) { tracks, unplaced in
                await choice.ask(fileName: url.lastPathComponent, tracks: tracks, unplacedWaypoints: unplaced)
            }
            // `hikes` is never empty on success — a file that became nothing
            // throws — so this is the first of what the hiker chose.
            guard let first = kept.hikes.first else { return .refused(.file(.multipleTracks)) }
            importedHike = first
            placesPastLimit = kept.unannouncedPlacesPastLimit
        } catch {
            if reportsOutcome, error != .file(.multipleTracks) { importReport.failure = error }
            return .refused(error)
        }
        if reportsOutcome, placesPastLimit > 0 {
            importReport.placeNotice = HikeImportPlaceNotice(
                files: [.init(fileName: url.lastPathComponent, placesPastLimit: placesPastLimit)]
            )
        }
        let outcome = HikeImportOutcome.imported(importedHike, placesPastLimit: placesPastLimit)

        // The imported row remains persisted when another action won the
        // selection race; only its stale attempt to take over the map and
        // sheet is dropped.
        guard importSelectionGate.permits(
            token: selectionToken,
            selectedHikeID: selectedHike?.id,
            path: sheet.path,
            currentRecordingHikeID: currentRecordingHikeID,
            recordingPresented: sheet.isRecordingPresented
        ) else { return outcome }
        selectedHike = importedHike
        // The selection draws the imported route; expanding reveals it.
        sheet.makeRoomForTheMap()
        return outcome
    }
}
