//
//  CommonsPhotoQuery.swift
//  OpenHikes
//
//  What this app asks Wikimedia Commons about a curated route, and how it
//  reads what comes back.
//
//  ## Two questions, and why the second waits for the first
//
//  **Where were photographs taken near this stretch?** `list=geosearch`
//  answers it with nothing but a page id and the camera's position for each
//  geotagged file, nearest the circle's centre first, five hundred at most.
//  That is cheap enough to ask about every stretch of a route, and it is all
//  ``CommonsTrailPhotos`` needs to throw away everything not standing on the
//  line and choose a few that are spread along it.
//
//  **What are these files?** `prop=imageinfo` asked about the chosen ones
//  only — fifty page ids to a request — for the thumbnail, the type, the
//  licence, the author and the date. Asking it of every candidate would fetch
//  the metadata of hundreds of photographs to show a dozen; asking it first is
//  impossible, because it is the positions that decide which files matter.
//
//  ## What Commons asks of a client, as of 2026
//
//  Measured against the live service while this was built, and each is
//  load-bearing rather than courtesy.
//
//  - **An identifying User-Agent with a way to make contact**, or a limit of
//    ten requests a minute. ``TileCache/userAgent`` already is one — the app's
//    name and its public repository — so it is sent here as everywhere else.
//  - **Only standard thumbnail widths.** A thumbnail URL hotlinked at 400
//    pixels answered HTTP 400; at 500, 960, 1280 and 1920 it answered 200.
//    ``thumbnailWidth`` is one of those steps, and the URL is the one the API
//    hands back rather than one assembled here, so a change of steps costs a
//    rounded-up thumbnail rather than a broken one.
//  - **The geosearch can be too busy.** It answered
//    `cirrussearch-too-busy-error` on 11 of 115 requests made one a second, so
//    a busy answer is an ordinary outcome with its own failure and its own
//    retry — see ``WikimediaCommonsSource``.
//
//  ## What is kept, and what is not
//
//  JPEGs, at least ``minimumWidth`` wide, under a licence whose terms this app
//  can honour by crediting and linking — every Creative Commons licence
//  Commons accepts, CC0 and the public domain — and carrying no use
//  restrictions. Everything else is left out rather than shown with a caveat:
//  an aerial survey tile, a map drawn as a PNG, a scanned document and a
//  photograph of an identifiable person flagged for consent are all on Commons
//  near trails, and none of them is a picture of the walk.
//

import CoreLocation
import Foundation
import OpenHikesData

nonisolated enum CommonsPhotoQuery {
    /// The MediaWiki Action API on Commons.
    static let endpoint = URL(string: "https://commons.wikimedia.org/w/api.php")!

    /// The thumbnail width asked for, in pixels — one of the standard steps
    /// Commons serves; see this file's header.
    ///
    /// 960 and not 1280: a dozen photographs at 960 are about two and a half
    /// megabytes for a screen a hiker may leave in a second, measured at
    /// 220 KB a frame against 390 KB at 1280, and the gallery shows them a
    /// phone's width across.
    static let thumbnailWidth = 960

    /// The narrowest original kept. Smaller than this is an icon, a crop or a
    /// scan of something, not a view.
    static let minimumWidth = 640

    /// How many page ids one `imageinfo` request may name — the API's own
    /// limit for a client without a bot flag.
    static let imageInfoBatch = 50

    /// How many files one geosearch returns at most — the same limit.
    static let geosearchLimit = 500

    /// How long the client waits for an answer, in seconds. Commons answers in
    /// well under one; a request still open after this is one to give up on
    /// rather than one to keep a preview waiting for.
    static let timeoutInterval: TimeInterval = 15

    /// The only type of file kept: a photograph. See this file's header.
    static let photographType = "image/jpeg"

    /// The hosts a thumbnail is downloaded from: Wikimedia's image servers,
    /// as the API names them. Measured in 2026, a thumbnail is served from
    /// `thumb.wikimedia.org` and an original narrower than
    /// ``thumbnailWidth`` from `upload.wikimedia.org`.
    ///
    /// Checked rather than trusted, because the privacy policy names these two
    /// as the only addresses a photograph is fetched from, and a URL the API
    /// hands back is the one thing here this app did not build itself.
    static let imageHosts: Set<String> = ["thumb.wikimedia.org", "upload.wikimedia.org"]

    /// The `File:` namespace, where every image on Commons lives.
    private static let fileNamespace = 6
    private static let successRange = 200..<300
    private static let rateLimitedCode = 429

    /// The error codes that mean *ask again shortly* rather than *no*.
    private static let busyCodes: Set<String> = [
        "cirrussearch-too-busy-error",
        "maxlag",
        "ratelimited",
    ]

    // MARK: - The requests

    /// Every geotagged file whose camera stood inside `area`.
    ///
    /// `gsprimary=primary` because the primary coordinate on a Commons file is
    /// where the camera was, which is what a pin on a trail claims; the
    /// secondary one is where the subject is, and a summit photographed from
    /// the valley would otherwise stand on the summit.
    static func geosearch(around area: CommunitySearchArea) -> URLRequest {
        get([
            URLQueryItem(name: "list", value: "geosearch"),
            URLQueryItem(name: "gscoord", value: "\(area.latitude)|\(area.longitude)"),
            URLQueryItem(name: "gsradius", value: String(Int(area.radiusMeters.rounded(.up)))),
            URLQueryItem(name: "gsnamespace", value: String(fileNamespace)),
            URLQueryItem(name: "gsprimary", value: "primary"),
            URLQueryItem(name: "gslimit", value: String(geosearchLimit)),
        ])
    }

    /// The thumbnail, type, size, date and licence of up to
    /// ``imageInfoBatch`` files.
    static func imageInfo(of pageIDs: [Int]) -> URLRequest {
        let ids = pageIDs.prefix(imageInfoBatch).map(String.init).joined(separator: "|")
        return get([URLQueryItem(name: "pageids", value: ids)] + imageInfoFields)
    }

    /// The same details of the one file named `title` — the way a Wikidata
    /// item names its image, without the namespace. See
    /// ``WikidataPlaceSource``. The answer is read by ``files(from:timeZone:)``
    /// like any other, so the file has to pass every check a geotagged one does.
    static func imageInfo(ofFileTitled title: String) -> URLRequest {
        imageInfo(ofFilesTitled: [title])
    }

    /// The same details of up to ``imageInfoBatch`` files named in `titles`,
    /// in one request: the files saved hikes no longer hold, asked about
    /// again by name — see ``CommonsPhotoRefetch``. The answer is read by
    /// ``files(named:from:timeZone:)``.
    ///
    /// No `redirects`: a file renamed on Commons leaves a redirect behind,
    /// and `imageinfo` follows a file redirect by itself, answering under the
    /// name it was asked by. Measured against the live service in 2026.
    static func imageInfo(ofFilesTitled titles: [String]) -> URLRequest {
        let named = titles.prefix(imageInfoBatch).map { "\(fileNamespacePrefix)\($0)" }
        return get([URLQueryItem(name: "titles", value: named.joined(separator: "|"))] + imageInfoFields)
    }

    /// The name of the file on the Commons page at `page`, without its
    /// namespace — what ``imageInfo(ofFilesTitled:)`` asks about — or `nil`
    /// for an address that is not a file's page on Commons.
    ///
    /// The page is all a saved copy keeps of where it came from
    /// (``HikePhotoLicense/sourceURL``): the `descriptionurl` Commons
    /// answered with, which it spells `https://commons.wikimedia.org/wiki/`
    /// then `File:` and the name, percent-encoded. A file name cannot hold a
    /// `/`, so the rest of the path is the whole name.
    static func fileTitle(of page: URL) -> String? {
        guard page.scheme == "https", page.host() == endpoint.host() else { return nil }
        let path = page.path(percentEncoded: false)
        let prefix = articlePath + fileNamespacePrefix
        guard path.hasPrefix(prefix), path.count > prefix.count else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// Every revision of the file named `title`, up to ``imageInfoBatch`` of
    /// them, each with its SHA-1 and its thumbnail at ``thumbnailWidth``:
    /// where a saved copy pinned to a revision the file has since moved past
    /// finds its own picture — see ``HikePhotoLicense/fileSHA1``. Read by
    /// ``thumbnail(ofRevision:from:)``.
    ///
    /// An earlier revision keeps a thumbnail of its own, under
    /// `upload.wikimedia.org/…/archive/`, measured against the live service
    /// in 2026.
    static func revisions(ofFileTitled title: String) -> URLRequest {
        get([
            URLQueryItem(name: "titles", value: "\(fileNamespacePrefix)\(title)"),
            URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "iiprop", value: "url|sha1"),
            URLQueryItem(name: "iiurlwidth", value: String(thumbnailWidth)),
            URLQueryItem(name: "iilimit", value: String(imageInfoBatch)),
        ])
    }

    /// Where Commons serves its pages, and the namespace a file's page is in.
    private static let articlePath = "/wiki/"
    private static let fileNamespacePrefix = "File:"

    /// What every `imageinfo` question asks for about a file.
    private static var imageInfoFields: [URLQueryItem] {
        [
            URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "iiprop", value: "url|mime|size|timestamp|sha1|extmetadata"),
            URLQueryItem(name: "iiurlwidth", value: String(thumbnailWidth)),
            URLQueryItem(
                name: "iiextmetadatafilter",
                value: Metadata.allCases.map(\.rawValue).joined(separator: "|")
            ),
        ]
    }

    /// A thumbnail's bytes, asked for the way every other request here is.
    static func download(_ url: URL) -> URLRequest {
        identified(URLRequest(url: url))
    }

    private static func get(_ items: [URLQueryItem]) -> URLRequest {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            // Arrays rather than objects keyed by page id, and plain booleans.
            URLQueryItem(name: "formatversion", value: "2"),
        ] + items
        // `URLComponents` leaves a `+` as it is, and MediaWiki reads one in a
        // query as a space, so a file named with one would be asked about
        // under another name. Only a file's name can carry one — see
        // ``imageInfo(ofFileTitled:)``.
        let query = components?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components?.percentEncodedQuery = query
        // The endpoint is a literal and every value is percent-encoded by
        // `URLComponents`, so this cannot fail; the fallback keeps the type
        // honest rather than force-unwrapped.
        var request = URLRequest(url: components?.url ?? endpoint)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return identified(request)
    }

    private static func identified(_ request: URLRequest) -> URLRequest {
        var request = request
        request.timeoutInterval = timeoutInterval
        // What Wikimedia's User-Agent policy asks for by name: the app and a
        // way to reach whoever maintains it. See ``TileCache/userAgent``.
        request.setValue(TileCache.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    // MARK: - The answers

    /// The body of a successful response, or the failure its status was.
    static func body(of data: Data, statusCode: Int) throws -> Data {
        if statusCode == rateLimitedCode { throw CommonsPhotoFailure.busy }
        guard successRange.contains(statusCode) else {
            throw CommonsPhotoFailure.server(statusCode: statusCode)
        }
        return data
    }

    /// The geotagged files a geosearch found, nearest the centre first.
    static func candidates(from data: Data) throws -> [CommonsPhotoCandidate] {
        let answer = try JSONDecoder().decode(GeoSearchAnswer.self, from: data)
        if let error = answer.error { throw failure(for: error) }
        return (answer.query?.geosearch ?? []).compactMap { hit in
            let candidate = CommonsPhotoCandidate(pageID: hit.pageid, latitude: hit.lat, longitude: hit.lon)
            return CLLocationCoordinate2DIsValid(candidate.coordinate) ? candidate : nil
        }
    }

    /// The files an `imageinfo` answer describes that this app may show — see
    /// this file's header for what is left out.
    ///
    /// - Parameter timeZone: The zone a capture time with none of its own is
    ///   read in, as a camera's EXIF time is.
    static func files(from data: Data, timeZone: TimeZone = .current) throws -> [CommonsFile] {
        try imageInfo(from: data, timeZone: timeZone).files
    }

    /// The files an `imageinfo` answer describes that this app may show, and
    /// every page it answered about at all — what ``CommonsPhotoStore`` may
    /// write down as *not one this app may show*. See ``CommonsImageInfo``.
    static func imageInfo(from data: Data, timeZone: TimeZone = .current) throws -> CommonsImageInfo {
        let answer = try JSONDecoder().decode(ImageInfoAnswer.self, from: data)
        if let error = answer.error { throw failure(for: error) }
        let pages = answer.query?.pages ?? []
        return CommonsImageInfo(
            files: pages.compactMap { page in
                guard let pageID = page.pageid, let info = page.imageinfo.first else { return nil }
                return file(pageID: pageID, info: info, timeZone: timeZone)
            },
            // A thumbnail Commons failed to make this once is not an answer
            // about the file, so a page answered with one is asked about again.
            answered: Set(pages.compactMap { page in
                page.missing || page.imageinfo.first.map({ $0.thumberror == nil }) == true ? page.pageid : nil
            })
        )
    }

    /// What an answer to ``imageInfo(ofFilesTitled:)`` says about each of
    /// `titles`, keyed by the name as it was asked.
    ///
    /// A name the answer says nothing about is left out, for the reason
    /// ``CommonsImageInfo`` leaves such a page out of `answered`: it was asked
    /// and not answered, which is not a *no*. Commons spells a name back the
    /// way it files it — spaces for underscores, a capital first letter — and
    /// lists which name became which under `normalized`, which is how each
    /// page is matched to the name it was asked by.
    static func files(
        named titles: [String],
        from data: Data,
        timeZone: TimeZone = .current
    ) throws -> [String: CommonsFileAnswer] {
        let answer = try JSONDecoder().decode(ImageInfoAnswer.self, from: data)
        if let error = answer.error { throw failure(for: error) }
        let renamed = Dictionary((answer.query?.normalized ?? []).map { ($0.from, $0.to) }) { first, _ in first }
        let pages = Dictionary(
            (answer.query?.pages ?? []).compactMap { page in page.title.map { ($0, page) } }
        ) { first, _ in first }
        var answers: [String: CommonsFileAnswer] = [:]
        for title in titles {
            let asked = fileNamespacePrefix + title
            guard let page = pages[renamed[asked] ?? asked] else { continue }
            if let pageID = page.pageid, let info = page.imageinfo.first {
                // A thumbnail Commons failed to make is a failure of the
                // moment rather than a *no*: the file is still there.
                guard info.thumberror == nil else { continue }
                answers[title] = file(pageID: pageID, info: info, timeZone: timeZone)
                    .map(CommonsFileAnswer.file) ?? .refused
            } else if page.missing || page.invalid {
                answers[title] = .refused
            }
        }
        return answers
    }

    /// The thumbnail of the revision whose SHA-1 is `sha1`, in an answer to
    /// ``revisions(ofFileTitled:)``.
    ///
    /// Refused when the file has gone, or has no revision by that hash any
    /// more — deleted, hidden, or further back than the answer reaches — and
    /// not answered when the answer says nothing usable this time.
    static func thumbnail(ofRevision sha1: String, from data: Data) throws -> CommonsRevisionAnswer {
        let answer = try JSONDecoder().decode(ImageInfoAnswer.self, from: data)
        if let error = answer.error { throw failure(for: error) }
        guard let page = answer.query?.pages.first else { return .unanswered }
        if page.missing || page.invalid { return .refused }
        guard !page.imageinfo.isEmpty else { return .unanswered }
        guard let revision = page.imageinfo.first(where: { $0.sha1 == sha1 }) else { return .refused }
        guard revision.thumberror == nil else { return .unanswered }
        return shownThumbnail(revision.thumburl).map(CommonsRevisionAnswer.thumbnail) ?? .refused
    }

    /// A thumbnail address the API handed back, if it is one this app fetches
    /// from: HTTPS, on one of ``imageHosts``.
    private static func shownThumbnail(_ address: String?) -> URL? {
        guard let url = address.flatMap(URL.init(string:)),
              url.scheme == "https",
              url.host().map(imageHosts.contains) == true
        else { return nil }
        return url
    }

    private static func failure(for error: APIError) -> CommonsPhotoFailure {
        busyCodes.contains(error.code) ? .busy : .refused(code: error.code)
    }

    private static func file(pageID: Int, info: ImageInfo, timeZone: TimeZone) -> CommonsFile? {
        let field = { (name: Metadata) in info.extmetadata[name.rawValue]?.text }
        guard info.mime == photographType,
              (info.width ?? 0) >= minimumWidth,
              field(.restrictions)?.isEmpty ?? true,
              let thumbnail = shownThumbnail(info.thumburl),
              let source = info.descriptionurl.flatMap(URL.init(string:)),
              let licenseName = field(.licenseName).flatMap(CommonsLicense.accepted),
              let capturedAt = CommonsDate.capturedAt(
                  field(.dateTimeOriginal),
                  uploaded: info.timestamp,
                  timeZone: timeZone
              )
        else { return nil }
        return CommonsFile(
            pageID: pageID,
            thumbnailURL: thumbnail,
            credit: CommonsPhotoCredit(
                author: CommonsText.author(field(.artist)),
                license: HikePhotoLicense(
                    name: licenseName,
                    url: field(.licenseURL).flatMap(CommonsText.link),
                    sourceURL: source,
                    fileSHA1: info.sha1
                )
            ),
            capturedAt: capturedAt
        )
    }

    /// The `extmetadata` fields read, which is also the filter the request
    /// sends so nothing else comes back.
    enum Metadata: String, CaseIterable {
        case artist = "Artist"
        case dateTimeOriginal = "DateTimeOriginal"
        case licenseName = "LicenseShortName"
        case licenseURL = "LicenseUrl"
        case restrictions = "Restrictions"
    }
}

/// What an `imageinfo` answer said: the files this app may show, and which
/// pages it said anything about at all.
///
/// Two sets because *not one of the files* means two things. A page whose
/// details came back and fail a check — a diagram, a tile too narrow, a
/// licence this app cannot honour — is answered *no*, and stays that way for
/// as long as the file page does. A page the answer is silent about, or
/// lists with no details, was not answered: that is what an answer cut short
/// by Commons' own limits leaves, and writing it down as *no* would hide a
/// photograph that may be fine for thirty days. A page Commons calls missing
/// is answered — it is gone.
nonisolated struct CommonsImageInfo: Equatable, Sendable {
    var files: [CommonsFile]
    var answered: Set<Int>
}

/// What Commons answered about one file asked for by name — see
/// ``CommonsPhotoQuery/files(named:from:timeZone:)``.
nonisolated enum CommonsFileAnswer: Equatable, Sendable {
    /// A file this app may show, and where its thumbnail is.
    case file(CommonsFile)
    /// Commons answered, and it is not one: deleted, never there, or no
    /// longer a photograph under a licence this app can honour.
    case refused
}

/// What Commons answered about one revision of a file — see
/// ``CommonsPhotoQuery/thumbnail(ofRevision:from:)``.
nonisolated enum CommonsRevisionAnswer: Equatable, Sendable {
    /// The file, or that revision of it, is gone.
    case refused
    /// Where that revision's thumbnail is.
    case thumbnail(URL)
    /// Nothing usable came back this time.
    case unanswered
}

/// A geotagged file near a stretch of a route, before anything is known about
/// it but where its camera stood.
nonisolated struct CommonsPhotoCandidate: Equatable, Sendable {
    var pageID: Int
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// One file this app may show: a photograph, its thumbnail, its credit and
/// when it was taken.
///
/// `Codable` because ``CommonsPhotoStore`` writes it down: the answer to
/// *what is this file* changes when somebody edits the file page, which is
/// rarely enough to keep for as long as an OpenStreetMap answer is kept.
nonisolated struct CommonsFile: Codable, Equatable, Sendable {
    var pageID: Int
    var thumbnailURL: URL
    var credit: CommonsPhotoCredit
    var capturedAt: Date
}

/// Why asking Commons produced nothing usable.
///
/// Never shown to a hiker. A curated route whose photographs did not arrive
/// draws the strip it would have drawn without them — see
/// ``CommunityHikeView/loadCommonsPhotos(along:)`` — so these exist to be
/// logged and to keep the branches apart in a test.
nonisolated enum CommonsPhotoFailure: LocalizedError, Equatable {
    /// Too busy, rate-limited or lagging: worth one more try, a moment later.
    case busy
    /// The API answered with an error of its own that is not about load.
    case refused(code: String)
    case server(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .busy: String(localized: "Wikimedia Commons is busy.")
        case .refused(let code): String(localized: "Wikimedia Commons refused the request: \(code).")
        case .server(let statusCode): String(localized: "Wikimedia Commons answered \(statusCode).")
        }
    }
}

// MARK: - The wire format

nonisolated private struct APIError: Decodable {
    let code: String
}

nonisolated private struct GeoSearchAnswer: Decodable {
    struct Query: Decodable {
        let geosearch: [Hit]
    }

    struct Hit: Decodable {
        let pageid: Int
        let lat: Double
        let lon: Double
    }

    let query: Query?
    let error: APIError?
}

nonisolated private struct ImageInfoAnswer: Decodable {
    struct Query: Decodable {
        let pages: [Page]
        /// Which name asked became which name answered, for a question asked
        /// by name — see ``CommonsPhotoQuery/files(named:from:timeZone:)``.
        let normalized: [Normalization]

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pages = try container.decodeIfPresent([Page].self, forKey: .pages) ?? []
            normalized = try container.decodeIfPresent([Normalization].self, forKey: .normalized) ?? []
        }

        enum CodingKeys: String, CodingKey {
            case pages = "pages"
            case normalized = "normalized"
        }
    }

    struct Normalization: Decodable {
        let from: String
        let to: String
    }

    /// One page of the answer. A page id that does not exist comes back with
    /// no `imageinfo` at all, which reads as no file rather than as a failed
    /// answer — and is marked `missing`, which is what tells it apart from a
    /// page an answer cut short said nothing about. A name that cannot be a
    /// page at all is marked `invalid`, and has no id either.
    struct Page: Decodable {
        let pageid: Int?
        let title: String?
        let imageinfo: [ImageInfo]
        let missing: Bool
        let invalid: Bool

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            imageinfo = try container.decodeIfPresent([ImageInfo].self, forKey: .imageinfo) ?? []
            pageid = try container.decodeIfPresent(Int.self, forKey: .pageid)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            missing = try container.decodeIfPresent(Bool.self, forKey: .missing) ?? false
            invalid = try container.decodeIfPresent(Bool.self, forKey: .invalid) ?? false
        }

        enum CodingKeys: String, CodingKey {
            case imageinfo = "imageinfo"
            case pageid = "pageid"
            case title = "title"
            case missing = "missing"
            case invalid = "invalid"
        }
    }

    let query: Query?
    let error: APIError?
}

nonisolated private struct ImageInfo: Decodable {
    let descriptionurl: String?
    /// Read leniently: MediaWiki encodes an empty object as `[]`, and a file
    /// with no metadata is a file with no licence, which is left out on that
    /// ground rather than costing the whole answer.
    let extmetadata: [String: Metadatum]
    let mime: String?
    /// The revision's own hash, which a saved copy is pinned to — see
    /// ``HikePhotoLicense/fileSHA1``.
    let sha1: String?
    /// Why Commons made no thumbnail this time, in place of `thumburl` — see
    /// ``CommonsPhotoQuery/files(named:from:timeZone:)``.
    let thumberror: String?
    let thumburl: String?
    let timestamp: String?
    let width: Int?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        descriptionurl = try container.decodeIfPresent(String.self, forKey: .descriptionurl)
        extmetadata = (try? container.decodeIfPresent([String: Metadatum].self, forKey: .extmetadata)) ?? [:]
        mime = try container.decodeIfPresent(String.self, forKey: .mime)
        sha1 = try container.decodeIfPresent(String.self, forKey: .sha1)
        thumberror = try? container.decodeIfPresent(String.self, forKey: .thumberror)
        thumburl = try container.decodeIfPresent(String.self, forKey: .thumburl)
        timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
        width = try container.decodeIfPresent(Int.self, forKey: .width)
    }

    enum CodingKeys: String, CodingKey {
        case descriptionurl = "descriptionurl"
        case extmetadata = "extmetadata"
        case mime = "mime"
        case sha1 = "sha1"
        case thumberror = "thumberror"
        case thumburl = "thumburl"
        case timestamp = "timestamp"
        case width = "width"
    }
}

/// One `extmetadata` field. Its `value` is a string for every field asked for
/// here, and is read leniently all the same: a field that comes back as
/// something else costs that field rather than the whole answer.
nonisolated private struct Metadatum: Decodable {
    let text: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try? container.decode(String.self, forKey: .value)
    }

    enum CodingKeys: String, CodingKey {
        case value = "value"
    }
}
