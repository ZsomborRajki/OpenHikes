//
//  CommonsRefetchStub.swift
//  OpenHikesTests
//
//  Wikimedia Commons, answering ``CommonsPhotoRefetch``'s questions from
//  memory: every file named is there, credited to "A hiker" under CC BY-SA
//  4.0, its current revision hashed `current-<name>`, and its thumbnail a
//  small JPEG — unless the suite says the file has gone, is credited to
//  somebody else, keeps earlier revisions, or had its thumbnail fail. It
//  writes down what it was asked, can refuse every question, and can hold the
//  first one out until told to answer it — the moment the refetch's queue is
//  about — or hold every thumbnail download until told to let them arrive.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Synchronization

#if canImport(UIKit)
import UIKit
#endif

nonisolated final class CommonsRefetchStub: Sendable {
    static let author = "A hiker"
    static let licenseName = "CC BY-SA 4.0"

    private static let answered = 200
    private static let notFound = 404
    private static let unavailable = 503
    private static let quality = 0.9

    private let asked = Mutex<[URL]>([])
    private let goneNames = Mutex<Set<String>>([])
    private let thumbnailFailures = Mutex<Set<String>>([])
    private let otherAuthors = Mutex<[String: String]>([:])
    private let earlierRevisions = Mutex<[String: [String]]>([:])
    private let refusing = Mutex(false)
    private let refusingDownloads = Mutex(false)
    private let holdsFirstQuestion: Bool
    private let held = Mutex<CheckedContinuation<Void, Never>?>(nil)
    /// Whether downloads are held, and the ones waiting for
    /// ``releaseDownloads()``.
    private let heldDownloads: Mutex<(isHolding: Bool, waiting: [CheckedContinuation<Void, Never>])>

    /// - Parameters:
    ///   - holdingFirstQuestion: Whether the first file-details question
    ///     waits for ``answerHeldQuestion()`` before it is answered.
    ///   - holdingDownloads: Whether each thumbnail download waits for
    ///     ``releaseDownloads()`` before it arrives.
    init(holdingFirstQuestion: Bool = false, holdingDownloads: Bool = false) {
        holdsFirstQuestion = holdingFirstQuestion
        heldDownloads = Mutex((isHolding: holdingDownloads, waiting: []))
    }

    /// A small JPEG, the format every Commons copy is saved in.
    static let thumbnail: Data = {
        #if canImport(UIKit)
        let size = CGSize(width: 8, height: 8)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: quality) ?? Data()
        #else
        return Data()
        #endif
    }()

    /// The hash the stub gives the current revision of the file `name`.
    static func currentSHA1(of name: String) -> String { "current-\(name)" }

    /// Where the stub serves the thumbnail of the revision hashed `sha1`.
    static func archivedThumbnail(_ sha1: String) -> URL {
        URL(string: "https://upload.wikimedia.org/wikipedia/commons/archive/\(sha1).jpg") ?? URL(filePath: "/")
    }

    /// A saved copy of the file `name`, as ``CommunityImport`` saves one,
    /// pinned to its current revision — or to `sha1`, or to none for a copy
    /// saved before the hash was kept.
    static func copy(of name: String, pinnedTo pin: Pin = .current, author: String = author) -> HikePhoto {
        let hash: String? = switch pin {
        case .current: currentSHA1(of: name)
        case .revision(let sha1): sha1
        case .unpinned: nil
        }
        return HikePhoto(
            importedAuthorName: author,
            license: HikePhotoLicense(
                name: licenseName,
                url: URL(string: "https://creativecommons.org/licenses/by-sa/4.0"),
                sourceURL: URL(string: "https://commons.wikimedia.org/wiki/File:\(name)") ?? URL(filePath: "/"),
                fileSHA1: hash
            )
        )
    }

    /// Which revision a saved copy was made from.
    enum Pin {
        case current
        case revision(String)
        case unpinned
    }

    var requests: [URL] { asked.withLock { $0 } }

    /// The file-details questions asked, each as the names it asked about.
    var questions: [[String]] {
        requests.filter { !Self.isRevisionLookup($0) }.map(Self.names).filter { !$0.isEmpty }
    }

    /// The names asked about for their earlier revisions, in order.
    var revisionLookups: [String] {
        requests.filter(Self.isRevisionLookup).flatMap(Self.names)
    }

    /// The thumbnails downloaded, in order.
    var downloads: [URL] {
        requests.filter { $0.host() != "commons.wikimedia.org" }
    }

    /// Whether the first question is out and being held.
    var isHoldingQuestion: Bool { held.withLock { $0 != nil } }

    /// How many thumbnail downloads are out and being held.
    var heldDownloadCount: Int { heldDownloads.withLock { $0.waiting.count } }

    func gone(_ name: String) { goneNames.withLock { _ = $0.insert(name) } }

    func failThumbnail(of name: String) { thumbnailFailures.withLock { _ = $0.insert(name) } }

    func credit(_ name: String, to author: String) { otherAuthors.withLock { $0[name] = author } }

    /// Gives the file `name` earlier revisions, hashed `sha1s`, newest first.
    func keepRevisions(of name: String, _ sha1s: [String]) {
        earlierRevisions.withLock { $0[name] = sha1s }
    }

    func refuseQuestions(_ refuse: Bool) { refusing.withLock { $0 = refuse } }

    func refuseDownloads(_ refuse: Bool) { refusingDownloads.withLock { $0 = refuse } }

    func answerHeldQuestion() {
        held.withLock { continuation in
            continuation?.resume()
            continuation = nil
        }
    }

    /// Lets every held download arrive, and every later one through at once.
    func releaseDownloads() {
        let released = heldDownloads.withLock { held in
            defer { held = (isHolding: false, waiting: []) }
            return held.waiting
        }
        for continuation in released { continuation.resume() }
    }

    var transport: CommonsPhotoRefetch.Transport {
        { [self] request in
            let url = request.url ?? URL(filePath: "/")
            let count = asked.withLock { requests in
                requests.append(url)
                return requests.count
            }
            guard url.host() == "commons.wikimedia.org" else {
                await holdIfAsked()
                return refusingDownloads.withLock { $0 } ? (Data(), Self.notFound) : (Self.thumbnail, Self.answered)
            }
            if holdsFirstQuestion, count == 1 {
                await withCheckedContinuation { continuation in
                    held.withLock { $0 = continuation }
                }
            }
            if refusing.withLock({ $0 }) { return (Data(), Self.unavailable) }
            let names = Self.names(in: url)
            if Self.isRevisionLookup(url) { return (revisions(of: names.first ?? ""), Self.answered) }
            return (answer(naming: names), Self.answered)
        }
    }

    /// Waits for ``releaseDownloads()`` while downloads are held. Joined
    /// under the lock the release empties, so a download is either held
    /// before the release or never held.
    private func holdIfAsked() async {
        await withCheckedContinuation { continuation in
            let isHeld = heldDownloads.withLock { held in
                if held.isHolding { held.waiting.append(continuation) }
                return held.isHolding
            }
            if !isHeld { continuation.resume() }
        }
    }

    // MARK: - The answers

    /// An answer about each of `names`, spelled as Commons spells it back:
    /// spaces for underscores, with the renaming listed under `normalized`.
    private func answer(naming names: [String]) -> Data {
        let renamed = names.filter { $0.contains("_") }.map { name in
            #"{"fromencoded":false,"from":"File:\#(name)","to":"File:\#(Self.filed(name))"}"#
        }
        let pages = names.enumerated().map { index, name in page(name, id: index + 1) }
        return Data(
            """
            {"batchcomplete":true,"query":{"normalized":[\(renamed.joined(separator: ","))],\
            "pages":[\(pages.joined(separator: ","))]}}
            """.utf8
        )
    }

    private func page(_ name: String, id: Int) -> String {
        guard !goneNames.withLock({ $0.contains(name) }) else {
            return #"{"ns":6,"title":"File:\#(Self.filed(name))","missing":true,"imagerepository":""}"#
        }
        let picture = thumbnailFailures.withLock { $0.contains(name) }
            ? #""thumberror":"Error creating thumbnail: timed out""#
            : #""thumburl":"https://upload.wikimedia.org/thumb/\#(id)/960px-\#(Self.thumbnailName(of: name))""#
        let credit = otherAuthors.withLock { $0[name] } ?? Self.author
        return """
        {"pageid":\(id),"ns":6,"title":"File:\(Self.filed(name))","imageinfo":[{\
        "timestamp":"2020-06-01T10:00:00Z","width":3000,"mime":"image/jpeg",\
        "sha1":"\(Self.currentSHA1(of: name))",\(picture),\
        "descriptionurl":"https://commons.wikimedia.org/wiki/File:\(name)",\
        "extmetadata":{"Artist":{"value":"\(credit)"},"LicenseShortName":{"value":"\(Self.licenseName)"}}}]}
        """
    }

    /// Every revision of the file `name`, the current one first.
    private func revisions(of name: String) -> Data {
        guard !goneNames.withLock({ $0.contains(name) }) else {
            return Data(#"{"query":{"pages":[{"ns":6,"title":"File:\#(name)","missing":true}]}}"#.utf8)
        }
        let hashes = [Self.currentSHA1(of: name)] + earlierRevisions.withLock { $0[name] ?? [] }
        let revisions = hashes.map { sha1 in
            #"{"sha1":"\#(sha1)","thumburl":"\#(Self.archivedThumbnail(sha1).absoluteString)"}"#
        }
        return Data(
            """
            {"query":{"pages":[{"pageid":1,"ns":6,"title":"File:\(name)",\
            "imageinfo":[\(revisions.joined(separator: ","))]}]}}
            """.utf8
        )
    }

    private static func isRevisionLookup(_ url: URL) -> Bool {
        url.absoluteString.contains("iilimit=")
    }

    /// The names a Commons question asks about, or none for a request that
    /// is not one.
    private static func names(in url: URL) -> [String] {
        let titles = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "titles" }?
            .value ?? ""
        return titles.split(separator: "|").map { String($0.dropFirst("File:".count)) }
    }

    private static func filed(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ")
    }

    /// The file's name as a thumbnail's address spells it, so two files
    /// asked about in different questions never share a thumbnail.
    private static func thumbnailName(of name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
    }
}
