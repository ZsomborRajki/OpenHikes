//
//  OfflineCountryDownloader.swift
//  OpenHikes
//
//  A country's files come down in a background `URLSession`, one request a
//  file however many tiles it holds, so a download carries on while the app
//  is suspended and after it is quit. The session waits for Wi-Fi by itself:
//  it is refused cellular, expensive and constrained paths, which is what
//  ``TileNetworkPolicy`` says of every `.speculative` fetch. A file that
//  failed part of the way is asked for again from where it stopped, with the
//  resume data the session hands back and the `Range` the tile server
//  honours.
//
//  The session moves each finished file into the store's staging directory
//  before its callback returns, because the system deletes it after that;
//  ``OfflineCountries`` checks it and installs it. When the system wakes the
//  app only to finish a download, the app's scene hands the wake to
//  ``BackgroundCountryDownloader/handleBackgroundEvents()``, and the next
//  launch installs what landed.
//

import Foundation
import os
import Synchronization

/// One file of one area's download, as a task carries it.
nonisolated struct OfflineCountryDownloadKey: Hashable, Sendable {
    let country: String
    let build: String
    let role: OfflineCountryManifest.Role

    /// What the task is labelled with, so a relaunch knows what it carries.
    var taskDescription: String { [country, build, role.rawValue].joined(separator: " ") }

    init(country: String, build: String, role: OfflineCountryManifest.Role) {
        self.country = country
        self.build = build
        self.role = role
    }

    init?(taskDescription: String) {
        let parts = taskDescription.split(separator: " ").map(String.init)
        guard parts.count == 3, let kind = OfflineCountryManifest.Role(rawValue: parts[2]) else { return nil }
        self.init(country: parts[0], build: parts[1], role: kind)
    }

    /// The file's name, as the manifest's path ends.
    var fileName: String {
        let infix = switch role {
        case .basemap: ""
        case .extras: "extras-"
        case .detail: "detail-"
        case .detailExtras: "detail-extras-"
        case .trails: "trails-"
        case .elevation: "elevation-"
        }
        return "\(country)-\(infix)\(build)" + OfflineCountryManifest.File.fileExtension
    }
}

/// One transfer of one file: the file, and the session task bringing it.
///
/// The file alone does not say which transfer an event is from. Cancelling
/// an area and downloading it again asks for the same files of the same
/// build under the same key, and the cancelled task can still finish, or
/// report, after its replacement has begun. The task's identifier is what
/// tells them apart, here and in the model.
nonisolated struct OfflineCountryTransfer: Hashable, Sendable {
    let key: OfflineCountryDownloadKey
    /// The session task's `taskIdentifier`, which a background session keeps
    /// across a relaunch and gives no other task of its own.
    let task: Int
}

/// What a download tells the countries' model, on the main actor.
nonisolated enum OfflineCountryDownloadEvent: Sendable {
    /// It stopped: with resume data where the session kept any, and
    /// `cancelled` when that was asked for.
    case failed(OfflineCountryTransfer, resumeData: Data?, cancelled: Bool)
    /// The file is whole in the staging directory, at the URL given.
    case finished(OfflineCountryTransfer, URL)
    /// How many bytes of the file have come so far.
    case wrote(OfflineCountryTransfer, Int64)
}

@MainActor
protocol OfflineCountryDownloading: AnyObject {
    /// Where events go. Set once, by the model.
    var onEvent: ((OfflineCountryDownloadEvent) -> Void)? { get set }

    /// Starts bringing `key`'s file, and answers the task's identifier, which
    /// every event about this transfer carries.
    @discardableResult func start(
        _ key: OfflineCountryDownloadKey,
        from url: URL,
        stagingAt staged: URL,
        resumeData: Data?
    ) -> Int
    func cancel(country: String)
    /// Stops the one file `key` names, and leaves its area's others
    /// running: what a try made again for fewer files no longer asks for.
    func cancel(_ key: OfflineCountryDownloadKey)
    /// The files still coming down, after a relaunch, with what each has
    /// written so far.
    func running() async -> [OfflineCountryDownloadKey: Int64]
}

@MainActor
final class BackgroundCountryDownloader: OfflineCountryDownloading {
    /// One per process: a background session's identifier may be open once.
    static let shared = BackgroundCountryDownloader()

    /// The background session's identifier, which the scene names to be
    /// woken for it.
    nonisolated static let sessionIdentifier = (Bundle.main.bundleIdentifier ?? "OpenHikes") + ".offline-countries"

    var onEvent: ((OfflineCountryDownloadEvent) -> Void)?
    private let callbacks: SessionCallbacks
    private let session: URLSession
    /// The tasks this launch started, by file, so a cancel reaches them at
    /// once. The session lists its tasks only asynchronously, and a listing
    /// that answered after the same area was asked for again would cancel
    /// the new download too, whose cancellation the model does not hear.
    private var started: [OfflineCountryDownloadKey: URLSessionDownloadTask] = [:]

    private init() {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.allowsCellularAccess = false
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        configuration.sessionSendsLaunchEvents = true
        // Asked for now, by the hiker, so the system is not to wait for a
        // better time of its own choosing.
        configuration.isDiscretionary = false
        configuration.httpAdditionalHeaders = ["User-Agent": TileCache.userAgent]
        let delegate = SessionCallbacks()
        callbacks = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        delegate.deliver = { [weak self] event in
            onMainActor { self?.onEvent?(event) }
        }
    }

    @discardableResult func start(
        _ key: OfflineCountryDownloadKey,
        from url: URL,
        stagingAt staged: URL,
        resumeData: Data?
    ) -> Int {
        let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
        task.taskDescription = key.taskDescription
        // Before the task runs, so its first callback finds it the file's
        // current transfer, and any earlier one's finds it is not.
        callbacks.stage(key, task: task.taskIdentifier, at: staged)
        started = started.filter { $0.value.state != .completed }
        started[key] = task
        task.resume()
        return task.taskIdentifier
    }

    func cancel(country: String) {
        // First, so whatever any of its tasks says from now on is dropped.
        callbacks.cancel(country: country)
        cancelTasks { $0.country == country }
    }

    func cancel(_ key: OfflineCountryDownloadKey) {
        // First, as for an area.
        callbacks.cancel(key)
        cancelTasks { $0 == key }
    }

    /// Cancels the session's tasks for the files `isMeant` picks.
    private func cancelTasks(for isMeant: @escaping @Sendable (OfflineCountryDownloadKey) -> Bool) {
        for (key, task) in started where isMeant(key) {
            task.cancel()
            started[key] = nil
        }
        // What an earlier launch started is the session's alone to list,
        // and whatever this one starts meanwhile is left to run.
        session.getAllTasks { [self] tasks in
            onMainActor { [self] in
                let current = Set(started.values.map(\.taskIdentifier))
                for task in tasks where !current.contains(task.taskIdentifier)
                    && task.taskDescription.flatMap(OfflineCountryDownloadKey.init).map(isMeant) == true {
                    task.cancel()
                }
            }
        }
    }

    func running() async -> [OfflineCountryDownloadKey: Int64] {
        let tasks = await session.allTasks
        var running: [OfflineCountryDownloadKey: Int64] = [:]
        for task in tasks where task.state == .running || task.state == .suspended {
            guard let key = task.taskDescription.flatMap(OfflineCountryDownloadKey.init) else { continue }
            running[key] = task.countOfBytesReceived
        }
        return running
    }

    /// Waits for the session to deliver what it has, for a launch the
    /// system made only to finish a download.
    func handleBackgroundEvents() async {
        await callbacks.eventsDelivered()
    }

    /// The session's callbacks, which arrive on its own queue.
    nonisolated private final class SessionCallbacks: NSObject, URLSessionDownloadDelegate, Sendable {
        private static let logger = Logger(subsystem: "OpenHikes", category: "OfflineCountries")
        /// How often progress is passed on, at the most.
        private static let progressInterval: Duration = .milliseconds(500)
        private static let successRange = 200..<300

        private struct State {
            var deliver: (@Sendable (OfflineCountryDownloadEvent) -> Void)?
            /// Which task each file's callbacks are taken from. Each callback
            /// asks it and records what it did under the one lock, so a start
            /// or a cancel on the main actor comes wholly before or wholly
            /// after it.
            var transfers = OfflineCountryTransfers()
            var waiters: [CheckedContinuation<Void, Never>] = []
            /// The session said it was done before anything waited for it.
            var deliveredUnawaited = false
        }

        private let state = Mutex(State())

        var deliver: (@Sendable (OfflineCountryDownloadEvent) -> Void)? {
            get { state.withLock { $0.deliver } }
            set { state.withLock { $0.deliver = newValue } }
        }

        func stage(_ key: OfflineCountryDownloadKey, task: Int, at url: URL) {
            state.withLock { $0.transfers.start(OfflineCountryTransfer(key: key, task: task), stagingAt: url) }
        }

        func cancel(country: String) {
            state.withLock { $0.transfers.cancel(country: country) }
        }

        func cancel(_ key: OfflineCountryDownloadKey) {
            state.withLock { $0.transfers.cancel(key) }
        }

        /// The transfer `task` is. ``OfflineCountryTransfers`` says whether
        /// it is its file's.
        private static func transfer(of task: URLSessionTask) -> OfflineCountryTransfer? {
            guard let key = task.taskDescription.flatMap(OfflineCountryDownloadKey.init) else { return nil }
            return OfflineCountryTransfer(key: key, task: task.taskIdentifier)
        }

        /// Puts the file at `location` at `staged`, over any file there.
        private static func move(_ location: URL, to staged: URL) throws {
            try FileManager.default.createDirectory(
                at: staged.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: staged.path) {
                try FileManager.default.removeItem(at: staged)
            }
            try FileManager.default.moveItem(at: location, to: staged)
        }

        func eventsDelivered() async {
            await withCheckedContinuation { continuation in
                let delivered = state.withLock { state in
                    defer { state.deliveredUnawaited = false }
                    if !state.deliveredUnawaited { state.waiters.append(continuation) }
                    return state.deliveredUnawaited
                }
                if delivered { continuation.resume() }
            }
        }

        private func send(_ event: OfflineCountryDownloadEvent) {
            state.withLock { $0.deliver }?(event)
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard let transfer = Self.transfer(of: downloadTask) else { return }
            let now = ContinuousClock.now
            let due = state.withLock { $0.transfers.reports(transfer, at: now, every: Self.progressInterval) }
            if due { send(.wrote(transfer, totalBytesWritten)) }
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            guard let transfer = Self.transfer(of: downloadTask) else { return }
            let key = transfer.key
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            guard Self.successRange.contains(status) else {
                Self.logger.error("Country file \(key.taskDescription, privacy: .public): HTTP \(status)")
                return
            }
            // A relaunch forgets what was staged where, and the model looks
            // for the file under its own name there.
            let fallback = OfflineCountryStore.applicationSupport().stagingDirectory.appending(path: key.fileName)
            // Now or never: the system deletes `location` once this returns,
            // and that is all that becomes of a replaced task's file, or of
            // a cancelled area's. Moved under the lock, so neither a
            // replacement starting nor a cancel, after which the model
            // deletes what was staged, falls between the question and the
            // move: a rename within the app's container.
            do {
                let staged = try state.withLock { state in
                    try state.transfers.land(transfer, fallback: fallback) { try Self.move(location, to: $0) }
                }
                if let staged { send(.finished(transfer, staged)) }
            } catch {
                let reason = String(describing: error)
                Self.logger.error("Country file \(key.taskDescription, privacy: .public): \(reason, privacy: .public)")
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            // A landed file's end has nothing more to say, and a replaced
            // task's clears nothing of its replacement's.
            guard let transfer = Self.transfer(of: task),
                  state.withLock({ $0.transfers.end(transfer) }) == .stopped
            else { return }
            let failure = error as? NSError
            let resumeData = failure?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            send(.failed(transfer, resumeData: resumeData, cancelled: failure?.code == NSURLErrorCancelled))
        }

        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            let waiters = state.withLock { state in
                defer { state.waiters = [] }
                state.deliveredUnawaited = state.waiters.isEmpty
                return state.waiters
            }
            waiters.forEach { $0.resume() }
        }
    }
}
