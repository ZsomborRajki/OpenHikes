//
//  CommonsPhotoSource.swift
//  OpenHikes
//
//  Wikimedia Commons, asked for the photographs taken along a curated route.
//
//  ## Asked on open, never for a list
//
//  The rule the route's heights and its surface analysis already follow, and
//  for the same reason: a nearby search offers twenty-five routes and a hiker
//  opens one. So nothing here runs until a curated hike's preview has its
//  route, and the answer goes with the screen — see
//  ``CommunityHikeView/loadCommonsPhotos(along:)``. A hiker who saves the
//  trail keeps copies, credited, under the licences they came with.
//
//  ## One question at a time
//
//  The geosearches go out one after another rather than together. Wikimedia's
//  robot policy asks for one request in flight to the Action API, and a busy
//  answer — which the geosearch gives about one time in ten even at one a
//  second — is asked once more after a pause rather than hammered. A stretch
//  that still cannot be asked costs its own photographs and nothing else; the
//  rest of the route is shown. The thumbnails are the exception, and only
//  because the rule is the API's: they come from Wikimedia's image servers, a
//  few at a time — see ``WikimediaCommonsSource/parallelDownloads``.
//
//  ## What is sent
//
//  The middle and the radius of each stretch of a public OpenStreetMap route,
//  a list of page ids, and the app's User-Agent. Not the hiker's position, not
//  who they are: a route in Bavaria is asked about identically from Munich and
//  from Sydney. Over Low Data Mode nothing is sent at all — a dozen photographs
//  are megabytes a hiker who turned that on did not ask to spend — and the
//  preview draws the route without them, as it does for any failure here.
//

import Foundation
import OpenHikesData
import os

/// Where a curated route's photographs come from.
///
/// A protocol for the reason ``CuratedElevationSourcing`` is one: the
/// conformance below reaches a third-party API, and no suite may.
nonisolated protocol CommonsPhotoSourcing: Sendable {
    /// Openly licensed photographs taken along `route`, downloaded into
    /// `directory` and returned in walking order.
    ///
    /// The caller owns `directory` and is what eventually deletes it. A
    /// cancellation stops the downloads before another file is written into
    /// it, which is the guard the preview's discard depends on.
    @concurrent
    func photos(along route: [RouteCoordinate], downloadingInto directory: URL) async throws -> [CommonsPhoto]

    /// Openly licensed photographs whose camera stood inside `area`, leaving
    /// out any whose Commons page is in `shown`, downloaded into `directory`
    /// and returned nearest the middle of the area first.
    ///
    /// The trail maker's *Search this area* — see ``TrailDraftPhotos``. The
    /// caller owns `directory` on the terms the route's question sets.
    @concurrent
    func photos(
        in area: CommunitySearchArea,
        avoiding shown: Set<URL>,
        downloadingInto directory: URL
    ) async throws -> [CommonsPhoto]

    /// `photo` with its thumbnail downloaded again into `directory`, or `nil`
    /// when it has nowhere to be fetched from or did not arrive.
    ///
    /// For a photograph whose copy went with the answer it came in — see
    /// ``CommunityCommonsPhotos/usable(_:)``. Only the picture is fetched:
    /// what Commons says about it was already answered, and is on the value.
    @concurrent
    func download(_ photo: CommonsPhoto, into directory: URL) async throws -> CommonsPhoto?
}

nonisolated extension CommonsPhotoSourcing {
    /// Nothing, for a source with no address to fetch from: the dormant
    /// one, the seeded one, and every suite's stub that is not about this.
    @concurrent
    func download(_ photo: CommonsPhoto, into directory: URL) async -> CommonsPhoto? {
        nil
    }
}

/// A source that answers nothing, for every launch that has not opted in.
///
/// What ``MergedCommunityTransport`` holds unless the composition root hands
/// it the real one, so a caller that has not thought about it cannot reach
/// Wikimedia from a suite. See ``OpenHikesModel/makeCommunityTransport()``.
nonisolated struct DormantCommonsPhotoSource: CommonsPhotoSourcing {
    @concurrent
    func photos(along route: [RouteCoordinate], downloadingInto directory: URL) async -> [CommonsPhoto] {
        []
    }

    @concurrent
    func photos(
        in area: CommunitySearchArea,
        avoiding shown: Set<URL>,
        downloadingInto directory: URL
    ) async -> [CommonsPhoto] {
        []
    }
}

/// Wikimedia Commons, through its public API.
nonisolated struct WikimediaCommonsSource: CommonsPhotoSourcing {
    /// The seam a suite replaces — the shape ``StadiaElevationSource`` takes,
    /// and for the same reason: nothing here may reach the network from a
    /// test.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)
    /// How a busy answer is waited out, replaced in a suite so the retry costs
    /// no wall-clock time.
    typealias Pause = @Sendable (Duration) async throws -> Void

    /// How long a busy geosearch is left before it is asked once more.
    static let busyRetryDelay = Duration.seconds(2)

    /// How many thumbnails are downloaded at once.
    ///
    /// The one-at-a-time rule is the Action API's; the thumbnails come from
    /// Wikimedia's image servers, which a browser showing a gallery asks in
    /// parallel. One at a time, measured against the live service, kept a
    /// dozen photographs off the screen for seventeen seconds — and none of
    /// them is drawn until the last has landed.
    static let parallelDownloads = 4

    /// How many geosearches in a row may fail to reach Commons at all before
    /// the rest of a route's stretches are not asked.
    ///
    /// Each is `CommonsPhotoQuery`'s fifteen-second timeout, and a route has up
    /// to ``CommonsTrailPhotos/maximumAreas`` of them one after another — four
    /// minutes of a spinner on a weak signal. A route that could not reach
    /// Commons for two stretches in a row will not reach it for the third.
    static let unreachableLimit = 2

    private static let logger = Logger(subsystem: "OpenHikes", category: "Community")

    /// Ephemeral, uncached and refused over Low Data Mode — see this file's
    /// header. The User-Agent goes on every request too, but a header the
    /// session adds on its own is the one a redirect cannot lose.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsConstrainedNetworkAccess = false
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = ["User-Agent": TileCache.userAgent]
        return URLSession(configuration: configuration)
    }()

    private let transport: Transport
    private let pause: Pause
    /// What earlier searches learned about each file, or `nil` to keep
    /// nothing — see ``CommonsPhotoStore``.
    private let store: CommonsPhotoStore?

    /// - Parameter store: `nil` keeps nothing, which is what a suite about the
    ///   wire format wants and why it is the default here. The composition
    ///   root hands the live source the one in `Caches` — see
    ///   ``OpenHikesModel/makeTrailPhotoSource()``.
    init(transport: Transport? = nil, pause: Pause? = nil, store: CommonsPhotoStore? = nil) {
        self.transport = transport ?? { request in
            let (data, response) = try await Self.session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        self.pause = pause ?? { try await Task.sleep(for: $0) }
        self.store = store
    }

    @concurrent
    func photos(along route: [RouteCoordinate], downloadingInto directory: URL) async throws -> [CommonsPhoto] {
        guard route.count > 1 else { return [] }
        let profile = RouteProfile(route: route)
        var found: [CommonsPhotoCandidate] = []
        var unreachable = 0
        for area in CommonsTrailPhotos.areas(along: route) {
            try Task.checkCancellation()
            let search = try await candidates(around: area)
            found += search.files
            unreachable = search.reachedCommons ? 0 : unreachable + 1
            if unreachable >= Self.unreachableLimit {
                Self.logger.info("Commons is unreachable, the remaining stretches are not asked")
                break
            }
        }
        let length = profile.totalDistanceMeters
        // Twice through the spread, because the metadata decides between the
        // two: the first picks a batch of files standing on the line to ask
        // about, the second picks the ones to show from those that turned out
        // to be photographs under a licence this app can honour.
        let shortlist = CommonsTrailPhotos.spread(
            CommonsTrailPhotos.placed(found, on: profile),
            limit: CommonsPhotoQuery.imageInfoBatch,
            over: length
        )
        guard !shortlist.isEmpty else { return [] }
        try Task.checkCancellation()
        // Asked about by where the camera stood rather than the pin on the
        // line, which is what ``CommonsPhotoStore`` files a page under.
        let cameras = Dictionary(found.map { ($0.pageID, $0) }) { first, _ in first }
        let files = try await files(for: shortlist.compactMap { cameras[$0.pageID] })
        let chosen = CommonsTrailPhotos.chosen(
            shortlist.filter { files[$0.pageID] != nil },
            authors: files.compactMapValues(\.credit.author),
            limit: CommonsTrailPhotos.photoLimit,
            over: length
        )
        return try await download(chosen.map(\.spot), described: files, into: directory)
    }

    /// One geosearch over the area rather than one per stretch, because the
    /// area *is* one circle — the one the maker's pill was tapped over, and
    /// never wider than ``CommonsTrailPhotos/maximumRadiusMeters``. Then the
    /// same two steps the route takes, spread over a grid rather than along a
    /// line — see ``CommonsAreaPhotos``.
    @concurrent
    func photos(
        in area: CommunitySearchArea,
        avoiding shown: Set<URL>,
        downloadingInto directory: URL
    ) async throws -> [CommonsPhoto] {
        let asked = CommonsAreaPhotos.asked(area)
        let found = try await candidates(around: asked).files
        let shortlist = CommonsAreaPhotos.spread(found, in: asked, limit: CommonsPhotoQuery.imageInfoBatch)
        guard !shortlist.isEmpty else { return [] }
        try Task.checkCancellation()
        // What is already on the map is left out after the metadata rather
        // than before it: the page is what names a photograph, and the
        // geosearch knows only page ids. So a second tap over the same valley
        // offers the next photographs along rather than the same ones again.
        let files = try await files(for: shortlist)
            .filter { !shown.contains($0.value.credit.licence.sourceURL) }
        let chosen = CommonsAreaPhotos.chosen(
            shortlist.filter { files[$0.pageID] != nil },
            authors: files.compactMapValues(\.credit.author),
            limit: CommonsAreaPhotos.photoLimit,
            in: asked
        )
        return try await download(chosen, described: files, into: directory)
    }

    @concurrent
    func download(_ photo: CommonsPhoto, into directory: URL) async throws -> CommonsPhoto? {
        guard let thumbnail = photo.thumbnailURL,
              // A name of its own rather than the page's, so a copy fetched
              // again never lands on a file a search may still be reading.
              let url = try await fetch(thumbnail, into: directory, named: "commons-\(UUID().uuidString).jpeg")
        else { return nil }
        var again = photo
        again.fileURL = url
        return again
    }
}

// MARK: - The three steps

nonisolated private extension WikimediaCommonsSource {
    /// The files whose camera stood inside `area`.
    ///
    /// When the geosearch cannot be asked — busy twice, refused, offline —
    /// these are the files earlier searches on this device found there, which
    /// may be none. The failure is logged and the rest of the route goes on.
    /// See ``CommonsPhotoStore`` for why a partial answer beats none here.
    ///
    /// `reachedCommons` is `false` only when the request itself failed — a
    /// timeout, no route — and not for a busy or refused answer, which came
    /// from Commons.
    func candidates(
        around area: CommunitySearchArea
    ) async throws -> (files: [CommonsPhotoCandidate], reachedCommons: Bool) {
        do {
            let files = try await answer(CommonsPhotoQuery.geosearch(around: area)) { data in
                try CommonsPhotoQuery.candidates(from: data)
            }
            return (files, true)
        } catch let error where !(error is CancellationError) {
            let known = store?.pages(near: area, limit: CommonsPhotoQuery.geosearchLimit) ?? []
            Self.logger.info(
                """
                A Commons geosearch failed, \(known.count) files known from before: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            return (known.map(\.candidate), !(error is URLError))
        }
    }

    /// What Commons says about each of `candidates` that this app may show,
    /// keyed by page id.
    ///
    /// Only the pages ``CommonsPhotoStore`` has no answer for are asked
    /// about, and their answers are written down — the ones this app may not
    /// show as well, but only the ones Commons actually answered about; see
    /// ``CommonsImageInfo``. A request that fails costs the unknown pages and keeps
    /// the known ones; it is thrown only when nothing was known, which is how
    /// it behaved before anything was kept.
    func files(for candidates: [CommonsPhotoCandidate]) async throws -> [Int: CommonsFile] {
        var known: [Int: CommonsFile] = [:]
        var unknown: [CommonsPhotoCandidate] = []
        for candidate in candidates {
            if let page = store?.page(candidate.pageID) {
                known[candidate.pageID] = page.file
            } else {
                unknown.append(candidate)
            }
        }
        guard !unknown.isEmpty else { return known }
        let fetched: CommonsImageInfo
        do {
            fetched = try await answer(CommonsPhotoQuery.imageInfo(of: unknown.map(\.pageID))) { data in
                try CommonsPhotoQuery.imageInfo(from: data)
            }
        } catch let error where !(error is CancellationError) && !known.isEmpty {
            Self.logger.info(
                "Commons file details failed, showing known files: \(error.localizedDescription, privacy: .public)"
            )
            return known
        }
        let answered = Dictionary(fetched.files.map { ($0.pageID, $0) }) { first, _ in first }
        // Only the pages the answer spoke about. One past the batch
        // `imageInfo(of:)` sends was never asked, and one the answer is
        // silent about was asked and not answered — neither is a *no*.
        let spoken = unknown.filter { fetched.answered.contains($0.pageID) }
        store?.save(spoken.map { CommonsPage($0, file: answered[$0.pageID]) })
        return known.merging(answered) { first, _ in first }
    }

    /// Each of `chosen`'s thumbnails, written into `directory`, in the order
    /// `chosen` gave them.
    ///
    /// ``WikimediaCommonsSource/parallelDownloads`` at a time, and one failure
    /// at a time: a thumbnail that does not arrive, or arrives as something
    /// other than an image, costs itself.
    func download(
        _ chosen: [CommonsPhotoCandidate],
        described files: [Int: CommonsFile],
        into directory: URL
    ) async throws -> [CommonsPhoto] {
        let work = chosen.compactMap { spot in files[spot.pageID].map { (spot, $0) } }
        return try await withThrowingTaskGroup(of: (Int, CommonsPhoto?).self) { group in
            var queued = work.enumerated().makeIterator()
            var landed: [Int: CommonsPhoto] = [:]
            for _ in 0..<Self.parallelDownloads {
                guard let (index, (spot, file)) = queued.next() else { break }
                group.addTask { (index, try await photo(spot, described: file, into: directory)) }
            }
            while let (finished, arrived) = try await group.next() {
                landed[finished] = arrived
                if let (index, (spot, file)) = queued.next() {
                    group.addTask { (index, try await photo(spot, described: file, into: directory)) }
                }
            }
            return work.indices.compactMap { landed[$0] }
        }
    }

    /// One thumbnail, written into `directory` and pinned at `spot` — or `nil`
    /// when it did not arrive as an image or could not be written.
    ///
    /// Throws only a cancellation, and checks for one before the write: the
    /// check ``CloudKitCommunityTransport`` makes before its own copies, so a
    /// hiker who backed out has nothing written into a directory their screen
    /// has already deleted.
    func photo(
        _ spot: CommonsPhotoCandidate,
        described file: CommonsFile,
        into directory: URL
    ) async throws -> CommonsPhoto? {
        guard let url = try await fetch(file.thumbnailURL, into: directory, named: "commons-\(spot.pageID).jpeg")
        else { return nil }
        return CommonsPhoto(
            pin: CommunityPhotoPin(capturedAt: file.capturedAt, coordinate: spot.coordinate),
            fileURL: url,
            credit: file.credit,
            thumbnailURL: file.thumbnailURL
        )
    }

    /// A thumbnail written into `directory` as `name` — or `nil` when it did
    /// not arrive as an image or could not be written. Throws only a
    /// cancellation, for the reason ``photo(_:described:into:)`` gives.
    func fetch(_ thumbnail: URL, into directory: URL, named name: String) async throws -> URL? {
        try Task.checkCancellation()
        guard let data = try? await once(CommonsPhotoQuery.download(thumbnail), reading: { $0 }),
              ImageDataFormat.detect(in: data) != nil
        else { return nil }
        try Task.checkCancellation()
        let url = directory.appendingPathComponent(name, isDirectory: false)
        guard (try? Self.write(data, to: url)) != nil else { return nil }
        return url
    }

    /// One request read by `read`, asked once more after
    /// ``WikimediaCommonsSource/busyRetryDelay`` when the answer was *busy*.
    func answer<Answer>(_ request: URLRequest, reading read: (Data) throws -> Answer) async throws -> Answer {
        do {
            return try await once(request, reading: read)
        } catch CommonsPhotoFailure.busy {
            try await pause(Self.busyRetryDelay)
            return try await once(request, reading: read)
        }
    }

    func once<Answer>(_ request: URLRequest, reading read: (Data) throws -> Answer) async throws -> Answer {
        let (data, statusCode) = try await transport(request)
        return try read(CommonsPhotoQuery.body(of: data, statusCode: statusCode))
    }

    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
