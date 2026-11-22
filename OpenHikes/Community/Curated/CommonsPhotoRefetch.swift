//
//  CommonsPhotoRefetch.swift
//  OpenHikes
//
//  A saved hike's Wikimedia Commons photographs, downloaded again where this
//  device does not hold their files.
//
//  A copy of a Commons photograph is saved with the trail it was shown on —
//  see ``CommunityImport`` and ``TrailDraftPhotoCopy`` — and its file, like
//  every photograph's, stays on the device that saved it: mirroring carries
//  the row and not the pixels (*Settled decisions* in `AGENTS.md`). For the
//  hiker's own photographs that is the end of it, because nothing else holds
//  them. A Commons copy is the one photograph something else does hold, under
//  the licence it was copied with. Before this, a reinstall or the hiker's
//  other device showed its credit over a page saying the picture was on
//  another device, with nothing to press but the trash.
//
//  ## What is asked, and when
//
//  The file's name, read from the page the copy keeps
//  (``HikePhotoLicense/sourceURL``), and then the thumbnail Commons answers
//  with, at the width the copy was saved at
//  (``CommonsPhotoQuery/thumbnailWidth``). Asked when the picture is shown —
//  a hike's strip, its gallery, a photo pin on the map — which is never for
//  a list: no list draws a photograph. Over Low Data Mode nothing is sent.
//
//  ## One question at a time
//
//  Wikimedia's robot policy asks for one request in flight to the Action API,
//  and a hike's strip asks for every tile at once. So the names wait here,
//  and each question takes every name waiting when it is sent, up to
//  ``CommonsPhotoQuery/imageInfoBatch``: a strip of a dozen missing
//  photographs is one question or two rather than twelve. The thumbnails then
//  come from Wikimedia's image servers a few at a time, as a preview's do.
//
//  ## What is not done
//
//  The credit is not rewritten. A copy keeps the author and licence it was
//  saved under, which is what it was shared under, and a Creative Commons
//  licence cannot be taken back from a copy already made. A file Commons no
//  longer offers is said to be gone, and left for the hiker to remove.
//

import Foundation
import OpenHikesData
import os

/// What asking Commons again for one saved copy's picture came to.
nonisolated enum CommonsPictureAnswer: Equatable, Sendable {
    /// The thumbnail's bytes, an image.
    case picture(Data)
    /// Commons answered, and no longer offers this file — see
    /// ``CommonsFileAnswer/refused``.
    case refused
    /// Nothing came back to go on: no connection, Low Data Mode, a busy or
    /// failed answer, a download cut short. Worth asking again later.
    case unanswered
}

/// Wikimedia Commons, asked for saved copies' pictures one question at a
/// time.
///
/// An actor because its whole job is the queue: every caller's name waits in
/// it, and only one question is out at once. The actor is free while a
/// question is out, so a name asked for meanwhile waits for the next one.
actor CommonsPhotoRefetch {
    /// The seam a suite replaces — ``WikimediaCommonsSource/Transport``'s
    /// shape, and for the same reason: nothing here may reach the network
    /// from a test.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

    /// Who is waiting for one name's answer.
    private typealias Waiters = [CheckedContinuation<CommonsPictureAnswer, Never>]

    private static let logger = Logger(subsystem: "OpenHikes", category: "HikePhotos")

    /// Ephemeral, uncached and refused over Low Data Mode — the configuration
    /// ``WikimediaCommonsSource`` uses, for the same service.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsConstrainedNetworkAccess = false
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = ["User-Agent": TileCache.userAgent]
        return URLSession(configuration: configuration)
    }()

    private let transport: Transport
    /// The names the next question asks about, in the order they were asked
    /// for, with who is waiting on each.
    private var queued: [String] = []
    private var waiting: [String: Waiters] = [:]
    /// The names in the question that is out now, with who is waiting on each
    /// — the ones who asked before it went and the ones who asked since.
    private var asking: [String: Waiters] = [:]
    /// Names Commons said no to, this launch: a strip scrolled back does not
    /// ask about them again.
    private var refused: Set<String> = []
    private var isAsking = false

    init(transport: Transport? = nil) {
        self.transport = transport ?? { request in
            let (data, response) = try await Self.session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    /// The thumbnail of the Commons file named `title`, as
    /// ``CommonsPhotoQuery/fileTitle(of:)`` reads it.
    ///
    /// Waits for its turn, and is not cut short by a cancellation: the file it
    /// fetches is kept, so a tile scrolled away before it arrived still finds
    /// it there the next time.
    func picture(ofFileTitled title: String) async -> CommonsPictureAnswer {
        guard !refused.contains(title) else { return .refused }
        return await withCheckedContinuation { continuation in
            if asking[title] != nil {
                asking[title]?.append(continuation)
                return
            }
            if waiting[title] == nil { queued.append(title) }
            waiting[title, default: []].append(continuation)
            guard !isAsking else { return }
            isAsking = true
            Task { await askWhileAnyWait() }
        }
    }

    /// How many asks are waiting on `title`'s answer, whether for the next
    /// question or the one out now: what a suite waits on before it lets the
    /// question already out come back.
    func waiterCount(for title: String) -> Int {
        (waiting[title]?.count ?? 0) + (asking[title]?.count ?? 0)
    }
}

// MARK: - The questions

private extension CommonsPhotoRefetch {
    /// Asks about every name waiting, a batch at a time, until none is.
    func askWhileAnyWait() async {
        while !queued.isEmpty {
            let titles = Array(queued.prefix(CommonsPhotoQuery.imageInfoBatch))
            queued.removeFirst(titles.count)
            for title in titles {
                asking[title] = waiting.removeValue(forKey: title) ?? []
            }
            let files = await files(named: titles)
            await withTaskGroup(of: (String, CommonsPictureAnswer).self) { [transport] group in
                var next = titles.makeIterator()
                func fetch(_ title: String) {
                    group.addTask { (title, await Self.picture(for: files[title], using: transport)) }
                }
                for _ in 0..<WikimediaCommonsSource.parallelDownloads {
                    guard let title = next.next() else { break }
                    fetch(title)
                }
                while let (title, answer) = await group.next() {
                    answered(title, with: answer)
                    if let title = next.next() { fetch(title) }
                }
            }
        }
        isAsking = false
    }

    /// What Commons said about each of `titles` — none of them, when it said
    /// nothing at all: no connection, busy, a failure of its own. A name left
    /// out is one to ask about again.
    func files(named titles: [String]) async -> [String: CommonsFileAnswer] {
        do {
            let (data, statusCode) = try await transport(CommonsPhotoQuery.imageInfo(ofFilesTitled: titles))
            return try CommonsPhotoQuery.files(
                named: titles,
                from: CommonsPhotoQuery.body(of: data, statusCode: statusCode)
            )
        } catch {
            Self.logger.info(
                "Asking Commons for saved photographs failed: \(error.localizedDescription, privacy: .public)"
            )
            return [:]
        }
    }

    func answered(_ title: String, with answer: CommonsPictureAnswer) {
        if answer == .refused { refused.insert(title) }
        for continuation in asking.removeValue(forKey: title) ?? [] {
            continuation.resume(returning: answer)
        }
    }

    /// One file's picture, given what the question said about it: `nil`, for
    /// a name it said nothing about, is not a *no* — see
    /// ``CommonsPhotoQuery/files(named:from:timeZone:)``.
    @concurrent
    static func picture(
        for file: CommonsFileAnswer?,
        using transport: Transport
    ) async -> CommonsPictureAnswer {
        switch file {
        case .refused:
            return .refused
        case .none:
            return .unanswered
        case .file(let file):
            guard let (data, statusCode) = try? await transport(CommonsPhotoQuery.download(file.thumbnailURL)),
                  let body = try? CommonsPhotoQuery.body(of: data, statusCode: statusCode),
                  ImageDataFormat.detect(in: body) != nil
            else { return .unanswered }
            return .picture(body)
        }
    }
}

// MARK: - For this launch

extension CommonsPhotoRefetch {
    /// Commons, or `nil` for a launch under test — UI tests included — on the
    /// terms ``OpenHikesModel/makeTrailPhotoSource()`` keeps: Wikimedia's API
    /// is run for everybody on donations, and no suite may spend it.
    static func forThisLaunch() -> CommonsPhotoRefetch? {
        guard !AppLaunchEnvironment.isRunningTests else { return nil }
        return CommonsPhotoRefetch()
    }
}
