//
//  OfflineCountryDownload.swift
//  OpenHikes
//
//  One area's download in progress: the files it is for — the whole area,
//  or only the zoom 15 *Extra Detail* adds to one already down — how far it
//  has come, which are whole in the staging directory, and what the session
//  handed back to resume the rest from. An object of its own, observed by its row alone,
//  so a progress tick re-runs that row and nothing above it (*Render
//  isolation, in practice* in AGENTS.md). ``OfflineCountries`` owns every one
//  and is the only caller of what changes it.
//

import Foundation
import Observation

@MainActor
@Observable
final class OfflineCountryDownload {
    enum Phase: Equatable {
        /// Started, with no Wi-Fi to come down over yet.
        case waitingForWiFi
        case downloading
        /// Every file is down, and its SHA-256 is being checked.
        case checking
        case failed(OfflineCountries.Failure)
    }

    let country: OfflineCountryManifest.Country
    /// What it brings down.
    let files: [OfflineCountryManifest.File]
    private(set) var phase: Phase
    private(set) var writtenBytes: Int64 = 0

    @ObservationIgnored private var written: [OfflineCountryManifest.Role: Int64] = [:]
    /// The files that are whole, where they wait to be checked.
    @ObservationIgnored private(set) var staged: [OfflineCountryManifest.Role: URL] = [:]
    /// What the session kept of a file that stopped part of the way.
    @ObservationIgnored private(set) var resumeData: [OfflineCountryManifest.Role: Data] = [:]
    /// The files a transfer is still out for, which trying again after
    /// another file failed leaves to it rather than asking for twice.
    @ObservationIgnored private(set) var inFlight: Set<OfflineCountryManifest.Role> = []

    init(country: OfflineCountryManifest.Country, files: [OfflineCountryManifest.File], phase: Phase) {
        self.country = country
        self.files = files
        self.phase = phase
    }

    nonisolated deinit { /* intentionally empty */ }

    /// What it costs, in bytes.
    var byteCount: Int64 { files.reduce(0) { $0 + $1.byteCount } }

    /// What has yet to come down, which is the room it still needs: the
    /// rest is on the volume already.
    var remainingBytes: Int64 { max(byteCount - writtenBytes, 0) }

    /// The room it is still taking: what has yet to come down while it
    /// runs, and once it has failed, what the transfers still out for it
    /// are bringing, because one file failing stops none of the others.
    var owedBytes: Int64 {
        guard hasFailed else { return remainingBytes }
        return files.reduce(0) { owed, file in
            inFlight.contains(file.role) ? owed + max(file.byteCount - (written[file.role] ?? 0), 0) : owed
        }
    }

    /// How much of it has come down, from 0 to 1.
    var fraction: Double {
        byteCount > 0 ? min(Double(writtenBytes) / Double(byteCount), 1) : 0
    }

    /// Whether it brings zoom 15.
    var hasDetail: Bool { files.contains(where: \.role.isDetail) }

    var hasFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    /// Whether every one of its files is down.
    var isStaged: Bool { files.allSatisfy { staged[$0.role] != nil } }

    func set(_ phase: Phase) {
        self.phase = phase
    }

    /// Takes over what an earlier try at the same build got down of the
    /// same files, so trying again asks only for the rest.
    func resume(from previous: OfflineCountryDownload) {
        guard previous.country == country else { return }
        let roles = Set(files.map(\.role))
        resumeData = previous.resumeData.filter { roles.contains($0.key) }
        staged = previous.staged.filter { roles.contains($0.key) }
        written = previous.written.filter { roles.contains($0.key) }
        inFlight = previous.inFlight.intersection(roles)
        sumWritten()
    }

    /// A transfer is out for the file in `role`.
    func began(_ role: OfflineCountryManifest.Role) {
        inFlight.insert(role)
    }

    /// `bytes` of the file in `role` have come down so far.
    func wrote(_ bytes: Int64, of role: OfflineCountryManifest.Role) {
        written[role] = bytes
        sumWritten()
        if phase == .waitingForWiFi { phase = .downloading }
    }

    /// `file` is whole, at `url`.
    func landed(_ file: OfflineCountryManifest.File, at url: URL) {
        inFlight.remove(file.role)
        staged[file.role] = url
        written[file.role] = file.byteCount
        sumWritten()
    }

    /// The file in `role` stopped, with what to resume it from where the
    /// session kept any. Where it kept none, nothing of the file is left,
    /// and the next try brings all of it again.
    func stopped(_ role: OfflineCountryManifest.Role, resumeData data: Data?) {
        inFlight.remove(role)
        resumeData[role] = data
        if data == nil {
            written[role] = 0
            sumWritten()
        }
        phase = .failed(.connection)
    }

    /// The file in `role` came down and is not the one the manifest
    /// describes, so it is asked for again from the start.
    func discard(_ role: OfflineCountryManifest.Role) {
        forget(role)
        phase = .failed(.damaged)
    }

    /// Nothing of the file in `role` is left where it was staged, so the
    /// next try asks for all of it, rather than checking a path with no
    /// file at it.
    func forget(_ role: OfflineCountryManifest.Role) {
        staged[role] = nil
        written[role] = 0
        resumeData[role] = nil
        sumWritten()
    }

    private func sumWritten() {
        writtenBytes = written.values.reduce(0, +)
    }
}
