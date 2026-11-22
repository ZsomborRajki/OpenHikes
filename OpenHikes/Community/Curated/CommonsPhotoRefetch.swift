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
//  ## The same picture, or none
//
//  A file on Commons can be overwritten under the same name, and the credit a
//  copy keeps describes the revision the hiker saw. So a copy that kept that
//  revision's SHA-1 (``HikePhotoLicense/fileSHA1``) is downloaded as that
//  revision: the current one when it still is, an earlier one by its hash
//  when the file has moved on, and nothing when no revision by that hash is
//  left. A copy saved before the hash was kept is downloaded only while
//  Commons credits the file exactly as the copy does — the same author, the
//  same licence — because nothing else can say the credit still fits. See
//  ``CommonsCopy``.
//
//  ## One question at a time
//
//  Every question goes through ``CommonsRequestGate``, which the rest of the
//  app's Commons requests share. A hike's strip asks for every tile at once,
//  so the names wait here, and each question takes every name waiting when it
//  is sent, up to ``CommonsPhotoQuery/imageInfoBatch``: a strip of a dozen
//  missing photographs is one question or two rather than twelve. The
//  thumbnails come from Wikimedia's image servers, outside the gate, each
//  once however many views asked for it.
//
//  ## What is not done
//
//  The credit is not rewritten. A copy keeps the author and licence it was
//  saved under, which is what it was shared under, and a Creative Commons
//  licence cannot be taken back from a copy already made. A copy Commons can
//  no longer give is said to be gone, and left for the hiker to remove.
//

import Foundation
import OpenHikesData
import os

/// What asking Commons again for one saved copy's picture came to.
nonisolated enum CommonsPictureAnswer: Equatable, Sendable {
    /// The thumbnail's bytes, an image.
    case picture(Data)
    /// Commons answered, and can no longer give this copy's picture: the file
    /// is gone, is no longer one this app may show, or is no longer the
    /// picture the copy's credit describes.
    case refused
    /// Nothing came back to go on: no connection, Low Data Mode, a busy or
    /// failed answer, a download cut short. Worth asking again later.
    case unanswered
}

/// What a saved copy of a Commons photograph says about the file it came
/// from: the name it is asked for by, and what Commons has to say back for
/// the picture to be this copy's.
nonisolated struct CommonsCopy: Hashable, Sendable {
    /// Which revision of a file is this copy's picture.
    enum Revision: Equatable {
        /// The file's current one.
        case current
        /// An earlier one, by its SHA-1.
        case earlier(String)
        /// None that can be told to be: a copy that kept no hash, which
        /// Commons no longer credits as the copy does.
        case unlike
    }

    var title: String
    var fileSHA1: String?
    var author: String?
    var licenseName: String

    init(title: String, fileSHA1: String?, author: String?, licenseName: String) {
        self.title = title
        self.fileSHA1 = fileSHA1
        self.author = author
        self.licenseName = licenseName
    }

    /// The copy `photo` is, or `nil` for a photograph that is no copy of a
    /// Commons file — the hiker's own, or a row whose page names no file.
    init?(_ photo: HikePhoto) {
        guard let license = photo.license,
              let name = CommonsPhotoQuery.fileTitle(of: license.sourceURL)
        else { return nil }
        self.init(
            title: name,
            fileSHA1: license.fileSHA1,
            author: photo.importedAuthorName,
            licenseName: license.name
        )
    }

    /// Which revision of `file`, as Commons describes it now, is this copy's
    /// picture.
    func revision(in file: CommonsFile) -> Revision {
        if let fileSHA1 {
            return file.credit.license.fileSHA1 == fileSHA1 ? .current : .earlier(fileSHA1)
        }
        return file.credit.author == author && file.credit.license.name == licenseName ? .current : .unlike
    }
}

/// Wikimedia Commons, asked for saved copies' pictures.
///
/// An actor because its whole job is the queue: every caller's name waits in
/// it for the next question, and the actor is free while a question is out,
/// so a name asked for meanwhile waits for the one after.
actor CommonsPhotoRefetch {
    /// The seam a suite replaces — ``WikimediaCommonsSource/Transport``'s
    /// shape, and for the same reason: nothing here may reach the network
    /// from a test.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

    /// Who is waiting for what Commons says about one name.
    private typealias Waiters = [CheckedContinuation<CommonsFileAnswer?, Never>]

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
    private let gate: CommonsRequestGate
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
    /// Thumbnails on their way, so two views showing one picture fetch it
    /// once.
    private var downloading: [URL: Task<CommonsPictureAnswer, Never>] = [:]

    /// - Parameter gate: The app's own when `nil` and this reaches the
    ///   network, and one of its own for a suite's transport — see
    ///   ``CommonsRequestGate``.
    init(transport: Transport? = nil, gate: CommonsRequestGate? = nil) {
        self.gate = gate ?? .forSource(reachingNetwork: transport == nil)
        self.transport = transport ?? { request in
            let (data, response) = try await Self.session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    /// The picture of `copy`: the revision it was made from, or nothing.
    ///
    /// Waits for its turn, and is not cut short by a cancellation: the file it
    /// fetches is kept, so a tile scrolled away before it arrived still finds
    /// it there the next time.
    func picture(of copy: CommonsCopy) async -> CommonsPictureAnswer {
        switch await details(ofFileTitled: copy.title) {
        case nil:
            return .unanswered
        case .refused:
            return .refused
        case .file(let file):
            switch copy.revision(in: file) {
            case .current:
                return await download(file.thumbnailURL)
            case .unlike:
                return .refused
            case .earlier(let sha1):
                switch await thumbnail(ofFileTitled: copy.title, revision: sha1) {
                case .thumbnail(let url): return await download(url)
                case .refused: return .refused
                case .unanswered: return .unanswered
                }
            }
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
    /// What Commons says about the file named `title` — `nil` when it said
    /// nothing this time — from the next question asked.
    func details(ofFileTitled title: String) async -> CommonsFileAnswer? {
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

    /// Asks about every name waiting, a batch at a time, until none is.
    func askWhileAnyWait() async {
        while !queued.isEmpty {
            let titles = Array(queued.prefix(CommonsPhotoQuery.imageInfoBatch))
            queued.removeFirst(titles.count)
            for title in titles {
                asking[title] = waiting.removeValue(forKey: title) ?? []
            }
            let files = await files(named: titles)
            for title in titles {
                if files[title] == .refused { refused.insert(title) }
                for continuation in asking.removeValue(forKey: title) ?? [] {
                    continuation.resume(returning: files[title])
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
            let data = try await asked(CommonsPhotoQuery.imageInfo(ofFilesTitled: titles))
            return try CommonsPhotoQuery.files(named: titles, from: data)
        } catch {
            Self.logger.info(
                "Asking Commons for saved photographs failed: \(error.localizedDescription, privacy: .public)"
            )
            return [:]
        }
    }

    /// The thumbnail of the revision of `title` whose SHA-1 is `sha1`, for a
    /// copy the file has moved past since it was saved.
    func thumbnail(ofFileTitled title: String, revision sha1: String) async -> CommonsRevisionAnswer {
        do {
            let data = try await asked(CommonsPhotoQuery.revisions(ofFileTitled: title))
            return try CommonsPhotoQuery.thumbnail(ofRevision: sha1, from: data)
        } catch {
            Self.logger.info(
                "Asking Commons for an earlier revision failed: \(error.localizedDescription, privacy: .public)"
            )
            return .unanswered
        }
    }

    /// One Action API request's body, in its turn at the gate.
    func asked(_ request: URLRequest) async throws -> Data {
        try await gate.run { [transport] in
            let (data, statusCode) = try await transport(request)
            return try CommonsPhotoQuery.body(of: data, statusCode: statusCode)
        }
    }

    /// The thumbnail at `url`, fetched once however many ask for it at once.
    func download(_ url: URL) async -> CommonsPictureAnswer {
        if let running = downloading[url] { return await running.value }
        let task = Task { [transport] in await Self.fetch(url, using: transport) }
        downloading[url] = task
        let answer = await task.value
        downloading[url] = nil
        return answer
    }

    /// The bytes at `url`, if they are an image.
    @concurrent
    static func fetch(_ url: URL, using transport: Transport) async -> CommonsPictureAnswer {
        guard let (data, statusCode) = try? await transport(CommonsPhotoQuery.download(url)),
              let body = try? CommonsPhotoQuery.body(of: data, statusCode: statusCode),
              ImageDataFormat.detect(in: body) != nil
        else { return .unanswered }
        return .picture(body)
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
