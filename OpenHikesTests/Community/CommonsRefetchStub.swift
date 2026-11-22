//
//  CommonsRefetchStub.swift
//  OpenHikesTests
//
//  Wikimedia Commons, answering ``CommonsPhotoRefetch``'s questions from
//  memory: every file named is there, unless the suite says it has gone,
//  and its thumbnail is a small JPEG. It writes down what it was asked, can
//  refuse every question, and can hold the first one out until told to
//  answer it — the moment the refetch's queue is about.
//

import Foundation
@testable import OpenHikes
import Synchronization

#if canImport(UIKit)
import UIKit
#endif

nonisolated final class CommonsRefetchStub: Sendable {
    private let asked = Mutex<[URL]>([])
    private let goneNames = Mutex<Set<String>>([])
    private let refusing = Mutex(false)
    private let refusingDownloads = Mutex(false)
    private let holdsFirstQuestion: Bool
    private let held = Mutex<CheckedContinuation<Void, Never>?>(nil)

    private static let answered = 200
    private static let notFound = 404
    private static let unavailable = 503
    private static let quality = 0.9

    /// - Parameter holdingFirstQuestion: Whether the first file-details
    ///   question waits for ``answerHeldQuestion()`` before it is answered.
    init(holdingFirstQuestion: Bool = false) {
        holdsFirstQuestion = holdingFirstQuestion
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

    var requests: [URL] { asked.withLock { $0 } }

    /// The file-details questions asked, each as the names it asked about.
    var questions: [[String]] { requests.map(Self.names).filter { !$0.isEmpty } }

    var downloads: Int { requests.count - questions.count }

    /// Whether the first question is out and being held.
    var isHoldingQuestion: Bool { held.withLock { $0 != nil } }

    func gone(_ name: String) { goneNames.withLock { _ = $0.insert(name) } }

    func refuseQuestions(_ refuse: Bool) { refusing.withLock { $0 = refuse } }

    func refuseDownloads(_ refuse: Bool) { refusingDownloads.withLock { $0 = refuse } }

    func answerHeldQuestion() {
        held.withLock { continuation in
            continuation?.resume()
            continuation = nil
        }
    }

    var transport: CommonsPhotoRefetch.Transport {
        { [self] request in
            let url = request.url ?? URL(filePath: "/")
            let count = asked.withLock { requests in
                requests.append(url)
                return requests.count
            }
            guard url.absoluteString.contains("prop=imageinfo") else {
                return refusingDownloads.withLock { $0 } ? (Data(), Self.notFound) : (Self.thumbnail, Self.answered)
            }
            if holdsFirstQuestion, count == 1 {
                await withCheckedContinuation { continuation in
                    held.withLock { $0 = continuation }
                }
            }
            if refusing.withLock({ $0 }) { return (Data(), Self.unavailable) }
            return (answer(naming: Self.names(in: url)), Self.answered)
        }
    }

    /// The names a file-details question asks about, or none for a request
    /// that is not one.
    private static func names(in url: URL) -> [String] {
        let titles = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "titles" }?
            .value ?? ""
        return titles.split(separator: "|").map { String($0.dropFirst("File:".count)) }
    }

    /// An answer about each of `names`, spelled as Commons spells it back:
    /// spaces for underscores, with the renaming listed under `normalized`.
    private func answer(naming names: [String]) -> Data {
        let gone = goneNames.withLock { $0 }
        let renamed = names.filter { $0.contains("_") }.map { name in
            #"{"fromencoded":false,"from":"File:\#(name)","to":"File:\#(Self.filed(name))"}"#
        }
        let pages = names.enumerated().map { index, name in
            guard !gone.contains(name) else {
                return #"{"ns":6,"title":"File:\#(Self.filed(name))","missing":true,"imagerepository":""}"#
            }
            return """
            {"pageid":\(index + 1),"ns":6,"title":"File:\(Self.filed(name))","imageinfo":[{\
            "timestamp":"2020-06-01T10:00:00Z","width":3000,"mime":"image/jpeg",\
            "thumburl":"https://upload.wikimedia.org/thumb/\(index + 1)/960px-\(index + 1).jpg",\
            "descriptionurl":"https://commons.wikimedia.org/wiki/File:\(name)",\
            "extmetadata":{"Artist":{"value":"A hiker"},"LicenseShortName":{"value":"CC BY-SA 4.0"}}}]}
            """
        }
        return Data(
            """
            {"batchcomplete":true,"query":{"normalized":[\(renamed.joined(separator: ","))],\
            "pages":[\(pages.joined(separator: ","))]}}
            """.utf8
        )
    }

    private static func filed(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ")
    }
}
