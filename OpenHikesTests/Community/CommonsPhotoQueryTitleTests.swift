//
//  CommonsPhotoQueryTitleTests.swift
//  OpenHikesTests
//
//  Asking Commons about files by name, the way a saved copy is downloaded
//  again: the name a copy's page gives, the question that names several at
//  once, and its answer read back to the names asked — which Commons spells
//  its own way. See ``CommonsPhotoRefetch``.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Commons files asked for by name")
struct CommonsPhotoQueryTitleTests {
    private static func queryItems(of request: URLRequest) -> [String: String] {
        let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }) { first, _ in first }
    }

    // MARK: - The name a page gives

    @Test("a file's page gives the file's name, decoded and without its namespace")
    func pageGivesTheName() throws {
        let page = try #require(
            URL(string: "https://commons.wikimedia.org/wiki/File:Matterhorn_from_Domh%C3%BCtte_-_2%26more.jpg")
        )
        #expect(CommonsPhotoQuery.fileTitle(of: page) == "Matterhorn_from_Domhütte_-_2&more.jpg")
    }

    @Test(
        "an address that is not a file's page on Commons gives no name",
        arguments: [
            "https://commons.wikimedia.org/wiki/Category:Matterhorn",
            "https://commons.wikimedia.org/wiki/File:",
            "https://en.wikipedia.org/wiki/File:Matterhorn.jpg",
            "http://commons.wikimedia.org/wiki/File:Matterhorn.jpg",
            "https://commons.wikimedia.org/w/index.php?title=File:Matterhorn.jpg",
        ]
    )
    func otherAddressesGiveNoName(_ address: String) throws {
        let page = try #require(URL(string: address))
        #expect(CommonsPhotoQuery.fileTitle(of: page) == nil)
    }

    // MARK: - The question

    @Test("one question names every file in the File namespace, and asks what a preview asks")
    func questionNamesEveryFile() {
        let items = Self.queryItems(of: CommonsPhotoQuery.imageInfo(ofFilesTitled: ["Lac_glacier.jpg", "A+b.jpg"]))
        #expect(items["titles"] == "File:Lac_glacier.jpg|File:A+b.jpg")
        #expect(items["prop"] == "imageinfo")
        #expect(items["iiurlwidth"] == String(CommonsPhotoQuery.thumbnailWidth))
        #expect(items["redirects"] == nil)
    }

    @Test("a question names no more files than the API answers at once")
    func questionIsCapped() {
        let titles = (0..<(CommonsPhotoQuery.imageInfoBatch + 10)).map { "\($0).jpg" }
        let named = Self.queryItems(of: CommonsPhotoQuery.imageInfo(ofFilesTitled: titles))["titles"]
        #expect(named?.split(separator: "|").count == CommonsPhotoQuery.imageInfoBatch)
    }

    @Test("a single file asked for by name is the same question")
    func singleFileIsTheSameQuestion() {
        #expect(
            CommonsPhotoQuery.imageInfo(ofFileTitled: "Lac glacier.jpg").url
                == CommonsPhotoQuery.imageInfo(ofFilesTitled: ["Lac glacier.jpg"]).url
        )
    }

    // MARK: - The answer

    /// What Commons answered, measured against the live service in 2026: a
    /// missing file, a name that cannot be a page, a drawing, a photograph
    /// spelled with spaces where it was asked for with underscores, and a page
    /// the answer lists with nothing about it.
    private static let answer = Data(
        #"""
        {"batchcomplete":true,"query":{
            "normalized":[{"fromencoded":false,"from":"File:Lac_glacier.jpg","to":"File:Lac glacier.jpg"}],
            "pages":[
                {"ns":6,"title":"File:Gone.jpg","missing":true,"imagerepository":""},
                {"title":"File:Bad<name.jpg","invalidreason":"Invalid characters.","invalid":true},
                {"pageid":2,"ns":6,"title":"File:Diagram.svg","imageinfo":[{
                    "timestamp":"2020-06-01T10:00:00Z","width":3000,"mime":"image/svg+xml",
                    "thumburl":"https://upload.wikimedia.org/thumb/2/960px-Diagram.svg.png",
                    "descriptionurl":"https://commons.wikimedia.org/wiki/File:Diagram.svg",
                    "extmetadata":{"LicenseShortName":{"value":"CC BY 4.0"}}}]},
                {"pageid":1,"ns":6,"title":"File:Lac glacier.jpg","imageinfo":[{
                    "timestamp":"2020-06-01T10:00:00Z","width":3000,"mime":"image/jpeg",
                    "thumburl":"https://upload.wikimedia.org/thumb/1/960px-Lac_glacier.jpg",
                    "descriptionurl":"https://commons.wikimedia.org/wiki/File:Lac_glacier.jpg",
                    "extmetadata":{"Artist":{"value":"A hiker"},"LicenseShortName":{"value":"CC BY-SA 4.0"}}}]},
                {"ns":6,"title":"File:Unsaid.jpg"}
            ]
        }}
        """#.utf8
    )

    private static let asked = ["Lac_glacier.jpg", "Gone.jpg", "Bad<name.jpg", "Diagram.svg", "Unsaid.jpg", "Never.jpg"]

    @Test("a photograph is matched to the name it was asked by, through Commons' own spelling of it")
    func photographIsMatchedThroughItsSpelling() throws {
        let answers = try CommonsPhotoQuery.files(named: Self.asked, from: Self.answer)
        guard case .file(let file) = answers["Lac_glacier.jpg"] else {
            Issue.record("Expected the photograph, got \(String(describing: answers["Lac_glacier.jpg"]))")
            return
        }
        #expect(file.thumbnailURL.absoluteString == "https://upload.wikimedia.org/thumb/1/960px-Lac_glacier.jpg")
        #expect(file.credit.author == "A hiker")
        #expect(file.credit.license.name == "CC BY-SA 4.0")
    }

    @Test("a file Commons does not have, cannot have, or may not be shown is refused")
    func filesThatCannotBeShownAreRefused() throws {
        let answers = try CommonsPhotoQuery.files(named: Self.asked, from: Self.answer)
        #expect(answers["Gone.jpg"] == .refused)
        #expect(answers["Bad<name.jpg"] == .refused)
        #expect(answers["Diagram.svg"] == .refused)
    }

    @Test("a name the answer says nothing about is not answered")
    func unsaidNamesAreNotAnswered() throws {
        let answers = try CommonsPhotoQuery.files(named: Self.asked, from: Self.answer)
        #expect(answers["Unsaid.jpg"] == nil)
        #expect(answers["Never.jpg"] == nil)
        #expect(answers.count == 4)
    }

    @Test("an error answer is read the way every other Commons error is")
    func errorAnswerIsAFailure() {
        let busy = Data(#"{"error":{"code":"maxlag","info":"Waiting for a database server."}}"#.utf8)
        #expect(throws: CommonsPhotoFailure.busy) {
            try CommonsPhotoQuery.files(named: ["Lac_glacier.jpg"], from: busy)
        }
    }
}
