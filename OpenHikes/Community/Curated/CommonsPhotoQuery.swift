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
        let fields = Metadata.allCases.map(\.rawValue).joined(separator: "|")
        return get([
            URLQueryItem(name: "pageids", value: ids),
            URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "iiprop", value: "url|mime|size|timestamp|extmetadata"),
            URLQueryItem(name: "iiurlwidth", value: String(thumbnailWidth)),
            URLQueryItem(name: "iiextmetadatafilter", value: fields),
        ])
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
        let answer = try JSONDecoder().decode(ImageInfoAnswer.self, from: data)
        if let error = answer.error { throw failure(for: error) }
        return (answer.query?.pages ?? []).compactMap { page in
            guard let pageID = page.pageid, let info = page.imageinfo.first else { return nil }
            return file(pageID: pageID, info: info, timeZone: timeZone)
        }
    }

    private static func failure(for error: APIError) -> CommonsPhotoFailure {
        busyCodes.contains(error.code) ? .busy : .refused(code: error.code)
    }

    private static func file(pageID: Int, info: ImageInfo, timeZone: TimeZone) -> CommonsFile? {
        let field = { (name: Metadata) in info.extmetadata[name.rawValue]?.text }
        guard info.mime == photographType,
              (info.width ?? 0) >= minimumWidth,
              field(.restrictions)?.isEmpty ?? true,
              let thumbnail = info.thumburl.flatMap(URL.init(string:)),
              let source = info.descriptionurl.flatMap(URL.init(string:)),
              let licenceName = field(.licenceName).flatMap(CommonsLicence.accepted),
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
                licence: HikePhotoLicence(
                    name: licenceName,
                    url: field(.licenceURL).flatMap(CommonsText.link),
                    sourceURL: source
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
        case licenceName = "LicenseShortName"
        case licenceURL = "LicenseUrl"
        case restrictions = "Restrictions"
    }
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
nonisolated struct CommonsFile: Equatable, Sendable {
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
        case .busy: "Wikimedia Commons is busy."
        case .refused(let code): "Wikimedia Commons refused the request: \(code)."
        case .server(let statusCode): "Wikimedia Commons answered \(statusCode)."
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
    }

    /// One page of the answer. A page id that does not exist comes back with
    /// no `imageinfo` at all, which reads as no file rather than as a failed
    /// answer.
    struct Page: Decodable {
        let pageid: Int?
        let imageinfo: [ImageInfo]

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            imageinfo = try container.decodeIfPresent([ImageInfo].self, forKey: .imageinfo) ?? []
            pageid = try container.decodeIfPresent(Int.self, forKey: .pageid)
        }

        enum CodingKeys: String, CodingKey {
            case imageinfo = "imageinfo"
            case pageid = "pageid"
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
    let thumburl: String?
    let timestamp: String?
    let width: Int?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        descriptionurl = try container.decodeIfPresent(String.self, forKey: .descriptionurl)
        extmetadata = (try? container.decodeIfPresent([String: Metadatum].self, forKey: .extmetadata)) ?? [:]
        mime = try container.decodeIfPresent(String.self, forKey: .mime)
        thumburl = try container.decodeIfPresent(String.self, forKey: .thumburl)
        timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
        width = try container.decodeIfPresent(Int.self, forKey: .width)
    }

    enum CodingKeys: String, CodingKey {
        case descriptionurl = "descriptionurl"
        case extmetadata = "extmetadata"
        case mime = "mime"
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
