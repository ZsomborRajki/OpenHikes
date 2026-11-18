//
//  OfflineCountryDownload.swift
//  OpenHikes
//
//  One country's download in progress: how far it has come, which of its
//  files are whole in the staging directory, and what the session handed back
//  to resume the rest from. An object of its own, observed by its row alone,
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
    private(set) var phase: Phase
    private(set) var writtenBytes: Int64 = 0

    @ObservationIgnored private var written: [OfflineCountryManifest.Role: Int64] = [:]
    /// The files that are whole, where they wait to be checked.
    @ObservationIgnored private(set) var staged: [OfflineCountryManifest.Role: URL] = [:]
    /// What the session kept of a file that stopped part of the way.
    @ObservationIgnored private(set) var resumeData: [OfflineCountryManifest.Role: Data] = [:]

    init(country: OfflineCountryManifest.Country, phase: Phase) {
        self.country = country
        self.phase = phase
    }

    nonisolated deinit { /* intentionally empty */ }

    /// How much of the country has come down, from 0 to 1.
    var fraction: Double {
        country.byteCount > 0 ? min(Double(writtenBytes) / Double(country.byteCount), 1) : 0
    }

    var hasFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    /// Whether every one of the country's files is down.
    var isStaged: Bool { staged.count == country.files.count }

    func set(_ phase: Phase) {
        self.phase = phase
    }

    /// Takes over what an earlier try at the same build got down, so trying
    /// again asks only for the rest.
    func resume(from previous: OfflineCountryDownload) {
        guard previous.country == country else { return }
        resumeData = previous.resumeData
        staged = previous.staged
        written = previous.written
        sumWritten()
    }

    /// `bytes` of the file in `role` have come down so far.
    func wrote(_ bytes: Int64, of role: OfflineCountryManifest.Role) {
        written[role] = bytes
        sumWritten()
        if phase == .waitingForWiFi { phase = .downloading }
    }

    /// `file` is whole, at `url`.
    func landed(_ file: OfflineCountryManifest.File, at url: URL) {
        staged[file.role] = url
        written[file.role] = file.byteCount
        sumWritten()
    }

    /// The file in `role` stopped, with what to resume it from where the
    /// session kept any.
    func stopped(_ role: OfflineCountryManifest.Role, resumeData data: Data?) {
        if let data { resumeData[role] = data }
        phase = .failed(.connection)
    }

    /// The file in `role` came down and is not the one the manifest
    /// describes, so it is asked for again from the start.
    func discard(_ role: OfflineCountryManifest.Role) {
        staged[role] = nil
        written[role] = 0
        resumeData[role] = nil
        sumWritten()
        phase = .failed(.damaged)
    }

    private func sumWritten() {
        writtenBytes = written.values.reduce(0, +)
    }
}
