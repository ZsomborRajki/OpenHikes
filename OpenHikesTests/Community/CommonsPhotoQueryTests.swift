//
//  CommonsPhotoQueryTests.swift
//  OpenHikesTests
//
//  What this app asks Wikimedia Commons, and what it keeps of the answers.
//
//  The answers below are shaped on what the live service returned while the
//  feature was built — `formatversion=2`, a page per file, `extmetadata` as
//  objects carrying a `value` — and each file in them is one of the reasons a
//  photograph is left out: the wrong type, a licence this app cannot honour, a
//  use restriction, a frame too small to be a view. What is asserted is that
//  exactly the photograph left standing comes back, with the credit it is
//  owed.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Commons photo query")
struct CommonsPhotoQueryTests {
    private static let utc = TimeZone(identifier: "UTC") ?? .gmt
    private static let area = CommunitySearchArea(
        coordinate: CLLocationCoordinate2D(latitude: 47.6094, longitude: 13.072),
        radiusMeters: 1099.2
    )

    private static func queryItems(of request: URLRequest) -> [String: String] {
        let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }) { first, _ in first }
    }

    // MARK: - The requests

    @Test("a geosearch asks for files whose camera stood inside the circle")
    func geosearchRequest() {
        let request = CommonsPhotoQuery.geosearch(around: Self.area)
        let items = Self.queryItems(of: request)

        #expect(request.url?.host() == "commons.wikimedia.org")
        #expect(items["action"] == "query")
        #expect(items["list"] == "geosearch")
        #expect(items["gscoord"] == "47.6094|13.072")
        #expect(items["gsradius"] == "1100", "rounded up, so the circle never shrinks")
        #expect(items["gsnamespace"] == "6", "files, not articles")
        #expect(items["gsprimary"] == "primary", "where the camera stood, not where the subject is")
        #expect(items["gslimit"] == "500")
        #expect(items["format"] == "json")
        #expect(items["formatversion"] == "2")
    }

    /// Without an identifying User-Agent the service allows ten requests a
    /// minute, and its policy asks for a way to reach whoever sends them.
    @Test("every request introduces itself the way the rest of the app does")
    func everyRequestIsIdentified() throws {
        let thumbnail = try #require(URL(string: "https://upload.wikimedia.org/a/b/960px-c.jpg"))
        for request in [
            CommonsPhotoQuery.geosearch(around: Self.area),
            CommonsPhotoQuery.imageInfo(of: [1, 2]),
            CommonsPhotoQuery.download(thumbnail),
        ] {
            #expect(request.value(forHTTPHeaderField: "User-Agent") == TileCache.userAgent)
            #expect(request.timeoutInterval == CommonsPhotoQuery.timeoutInterval)
        }
    }

    @Test("an imageinfo request asks for a standard thumbnail width and the five fields read")
    func imageInfoRequest() {
        let items = Self.queryItems(of: CommonsPhotoQuery.imageInfo(of: [11, 22, 33]))

        #expect(items["pageids"] == "11|22|33")
        #expect(items["prop"] == "imageinfo")
        #expect(items["iiurlwidth"] == "960")
        #expect(
            Set((items["iiextmetadatafilter"] ?? "").split(separator: "|").map(String.init))
                == ["Artist", "DateTimeOriginal", "LicenseShortName", "LicenseUrl", "Restrictions"]
        )
    }

    @Test("an imageinfo request names no more files than the API answers at once")
    func imageInfoIsBatched() {
        let items = Self.queryItems(of: CommonsPhotoQuery.imageInfo(of: Array(1...80)))
        #expect(items["pageids"]?.split(separator: "|").count == CommonsPhotoQuery.imageInfoBatch)
    }

    // MARK: - Status codes

    @Test("a 429 is busy, any other failure is the server's, and a 200 is the body")
    func statusCodes() throws {
        #expect(throws: CommonsPhotoFailure.busy) {
            try CommonsPhotoQuery.body(of: Data(), statusCode: 429)
        }
        #expect(throws: CommonsPhotoFailure.server(statusCode: 503)) {
            try CommonsPhotoQuery.body(of: Data(), statusCode: 503)
        }
        #expect(try CommonsPhotoQuery.body(of: Data("{}".utf8), statusCode: 200) == Data("{}".utf8))
    }

    // MARK: - Geosearch answers

    @Test("a geosearch answer is read as candidates, nearest the centre first")
    func geosearchAnswer() throws {
        let answer = Data(
            """
            {"batchcomplete":true,"query":{"geosearch":[
                {"pageid":1834639,"ns":6,"title":"File:Purtschellerhaus MQ.jpg","lat":47.60946,"lon":13.072,
                    "dist":6.7,"primary":true},
                {"pageid":91192792,"ns":6,"title":"File:Hoher Göll.jpg","lat":47.610584,"lon":13.07116,
                    "dist":145.9,"primary":true}
            ]}}
            """.utf8
        )

        let candidates = try CommonsPhotoQuery.candidates(from: answer)

        #expect(candidates.map(\.pageID) == [1_834_639, 91_192_792])
        #expect(candidates.first?.latitude == 47.60946)
    }

    @Test("a busy search is busy, and any other error is a refusal naming its code")
    func geosearchErrors() {
        #expect(throws: CommonsPhotoFailure.busy) {
            try CommonsPhotoQuery.candidates(
                from: Data(#"{"error":{"code":"cirrussearch-too-busy-error","info":"Search is busy"}}"#.utf8)
            )
        }
        #expect(throws: CommonsPhotoFailure.refused(code: "badvalue")) {
            try CommonsPhotoQuery.candidates(from: Data(#"{"error":{"code":"badvalue","info":"x"}}"#.utf8))
        }
    }

    @Test("an area with nothing in it is no candidates rather than a failure")
    func emptyGeosearch() throws {
        let empty = Data(#"{"batchcomplete":true,"query":{"geosearch":[]}}"#.utf8)
        #expect(try CommonsPhotoQuery.candidates(from: empty).isEmpty)
    }

    // MARK: - Imageinfo answers

    /// One page per reason a file is left out, and one that is kept. The last
    /// two are left out for where their thumbnail is, not what it is: off
    /// Wikimedia's image servers, and over plain HTTP.
    private static let imageInfoAnswer = Data(
        #"""
        {"batchcomplete":true,"query":{"pages":[
            {"pageid":1,"ns":6,"title":"File:Kept.jpg","imageinfo":[{
                "timestamp":"2007-03-24T18:36:20Z","width":2592,"height":1944,
                "thumburl":"https://thumb.wikimedia.org/wikipedia/commons/thumb/kept/960px-Kept.jpg",
                "descriptionurl":"https://commons.wikimedia.org/wiki/File:Kept.jpg","mime":"image/jpeg",
                "extmetadata":{
                    "Artist":{"value":"<a href=\"//commons.wikimedia.org/wiki/User:Anna\">User:Anna</a>"},
                    "DateTimeOriginal":{"value":"2006-11-26 10:20:30"},
                    "LicenseShortName":{"value":"CC BY-SA 3.0"},
                    "LicenseUrl":{"value":"//creativecommons.org/licenses/by-sa/3.0/"},
                    "Restrictions":{"value":""}}}]},
            {"pageid":2,"ns":6,"title":"File:Map.png","imageinfo":[{
                "timestamp":"2007-03-24T18:36:20Z","width":2000,"mime":"image/png",
                "thumburl":"https://upload.wikimedia.org/thumb/map/960px-Map.png",
                "descriptionurl":"https://commons.wikimedia.org/wiki/File:Map.png",
                "extmetadata":{"LicenseShortName":{"value":"CC BY-SA 4.0"}}}]},
            {"pageid":3,"ns":6,"title":"File:Gfdl.jpg","imageinfo":[{
                "timestamp":"2007-03-24T18:36:20Z","width":2000,"mime":"image/jpeg",
                "thumburl":"https://upload.wikimedia.org/thumb/g/960px-Gfdl.jpg",
                "descriptionurl":"https://commons.wikimedia.org/wiki/File:Gfdl.jpg",
                "extmetadata":{"LicenseShortName":{"value":"GFDL"}}}]},
            {"pageid":4,"ns":6,"title":"File:Person.jpg","imageinfo":[{
                "timestamp":"2007-03-24T18:36:20Z","width":2000,"mime":"image/jpeg",
                "thumburl":"https://upload.wikimedia.org/thumb/p/960px-Person.jpg",
                "descriptionurl":"https://commons.wikimedia.org/wiki/File:Person.jpg",
                "extmetadata":{"LicenseShortName":{"value":"CC BY 4.0"},"Restrictions":{"value":"personality"}}}]},
            {"pageid":5,"ns":6,"title":"File:Tiny.jpg","imageinfo":[{
                "timestamp":"2007-03-24T18:36:20Z","width":320,"mime":"image/jpeg",
                "thumburl":"https://upload.wikimedia.org/tiny.jpg",
                "descriptionurl":"https://commons.wikimedia.org/wiki/File:Tiny.jpg",
                "extmetadata":{"LicenseShortName":{"value":"CC0"}}}]},
            {"pageid":6,"ns":6,"title":"File:Bare.jpg","imageinfo":[{
                "timestamp":"2007-03-24T18:36:20Z","width":2000,"mime":"image/jpeg",
                "thumburl":"https://upload.wikimedia.org/thumb/b/960px-Bare.jpg",
                "descriptionurl":"https://commons.wikimedia.org/wiki/File:Bare.jpg","extmetadata":[]}]},
            {"pageid":7,"ns":6,"title":"File:Gone.jpg","missing":true},
            {"pageid":8,"ns":6,"title":"File:Elsewhere.jpg","imageinfo":[{
                "timestamp":"2007-03-24T18:36:20Z","width":2000,"mime":"image/jpeg",
                "thumburl":"https://images.example.org/960px-Elsewhere.jpg",
                "descriptionurl":"https://commons.wikimedia.org/wiki/File:Elsewhere.jpg",
                "extmetadata":{"LicenseShortName":{"value":"CC0"}}}]},
            {"pageid":9,"ns":6,"title":"File:Plain.jpg","imageinfo":[{
                "timestamp":"2007-03-24T18:36:20Z","width":2000,"mime":"image/jpeg",
                "thumburl":"http://upload.wikimedia.org/plain.jpg",
                "descriptionurl":"https://commons.wikimedia.org/wiki/File:Plain.jpg",
                "extmetadata":{"LicenseShortName":{"value":"CC0"}}}]}
        ]}}
        """#.utf8
    )

    @Test("only a photograph under a licence this app can honour, with no restriction, is kept")
    func onlyUsablePhotographsAreKept() throws {
        let files = try CommonsPhotoQuery.files(from: Self.imageInfoAnswer, timeZone: Self.utc)
        #expect(files.map(\.pageID) == [1])
    }

    @Test("the kept photograph carries its author, its licence and both links")
    func keptPhotographIsCredited() throws {
        let file = try #require(try CommonsPhotoQuery.files(from: Self.imageInfoAnswer, timeZone: Self.utc).first)

        #expect(file.thumbnailURL.absoluteString == "https://thumb.wikimedia.org/wikipedia/commons/thumb/kept/960px-Kept.jpg")
        #expect(file.credit.author == "Anna")
        #expect(file.credit.licence.name == "CC BY-SA 3.0")
        #expect(file.credit.licence.url?.absoluteString == "https://creativecommons.org/licenses/by-sa/3.0/")
        #expect(file.credit.licence.sourceURL.absoluteString == "https://commons.wikimedia.org/wiki/File:Kept.jpg")
    }

    @Test("the kept photograph is dated by its camera rather than by its upload")
    func keptPhotographIsDatedByItsCamera() throws {
        let file = try #require(try CommonsPhotoQuery.files(from: Self.imageInfoAnswer, timeZone: Self.utc).first)
        let expected = try #require(CommonsDate.date(from: "2006-11-26 10:20:30", in: Self.utc))
        #expect(file.capturedAt == expected)
    }

    @Test("an imageinfo error is read the way a geosearch error is")
    func imageInfoErrors() {
        #expect(throws: CommonsPhotoFailure.busy) {
            try CommonsPhotoQuery.files(from: Data(#"{"error":{"code":"maxlag","info":"lagged"}}"#.utf8))
        }
    }
}
