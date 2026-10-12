//
//  CommonsPhotoTextTests.swift
//  OpenHikesTests
//
//  The three things a Commons file page says in words — its licence, who took
//  it, and when — read the way ``CommonsLicence``, ``CommonsText`` and
//  ``CommonsDate`` read them.
//
//  The shapes below are the ones the live service answered with while this was
//  built, plus the ones its documentation and its uploaders are known to
//  produce. What each case pins is a refusal as much as a reading: a licence
//  this app cannot honour, an author that is only markup and a date that is a
//  decade are all things the photograph must be left without rather than shown
//  with.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Commons photo text")
struct CommonsPhotoTextTests {
    private static let utc = TimeZone(identifier: "UTC") ?? .gmt

    private static func components(_ date: Date?) -> DateComponents? {
        guard let date else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }

    // MARK: - Licences

    @Test(
        "every Creative Commons attribution licence, CC0 and the public domain are kept",
        arguments: ["CC BY-SA 4.0", "CC BY-SA 3.0 de", "CC BY 2.0", "CC0", "CC0 1.0", "Public domain"]
    )
    func acceptedLicences(name: String) {
        #expect(CommonsLicence.accepted(name) == name)
    }

    @Test(
        "a licence asking for more than a credit and a link is left out",
        arguments: ["GFDL", "GFDL 1.2", "FAL", "CC BY-NC 4.0", "CC BY-SA-ND 2.0", "", "Copyrighted"]
    )
    func refusedLicences(name: String) {
        #expect(CommonsLicence.accepted(name) == nil)
    }

    @Test("a licence name arrives trimmed")
    func licenceIsTrimmed() {
        #expect(CommonsLicence.accepted("  CC BY-SA 4.0\n") == "CC BY-SA 4.0")
    }

    // MARK: - Authors

    /// The shape the live service answered with: a user page's link, whose
    /// text is the page title rather than the person.
    @Test("a user link is read as the user's name")
    func userLinkBecomesAName() {
        let artist = """
        <a href="//commons.wikimedia.org/wiki/User:MatthiasKabel" title="User:MatthiasKabel">User:MatthiasKabel</a>
        """
        #expect(CommonsText.author(artist) == "MatthiasKabel")
    }

    @Test("markup is stripped, entities decoded and whitespace collapsed")
    func markupBecomesText() {
        #expect(CommonsText.author("<span>Anna &amp; Bence</span>\n  <i>Gruber</i>") == "Anna & Bence Gruber")
        #expect(CommonsText.author("M&#252;ller &#x26; S&ouml;hne") == "Müller & S&ouml;hne")
    }

    @Test("an author that is only markup, or absent, names nobody")
    func emptyAuthorIsNobody() {
        #expect(CommonsText.author("<a href=\"x\"></a>") == nil)
        #expect(CommonsText.author(nil) == nil)
    }

    @Test("a paragraph is cut to a credit's length rather than refused")
    func longAuthorIsBounded() throws {
        let author = try #require(CommonsText.author(String(repeating: "Anna ", count: 100)))
        #expect(author.hasPrefix("Anna Anna"))
        #expect(author.count < 100)
    }

    // MARK: - Links

    @Test("a scheme-relative licence link is completed, and anything not on the web refused")
    func licenceLinks() {
        #expect(
            CommonsText.link("//creativecommons.org/licenses/by-sa/4.0/")?.absoluteString
                == "https://creativecommons.org/licenses/by-sa/4.0/"
        )
        #expect(
            CommonsText.link("http://creativecommons.org/licenses/by/2.0/")?.absoluteString
                == "http://creativecommons.org/licenses/by/2.0/"
        )
        #expect(CommonsText.link("javascript:alert(1)") == nil)
        #expect(CommonsText.link("   ") == nil)
    }

    // MARK: - Dates

    @Test("a camera's time is read in the zone it is asked to be read in")
    func cameraTime() {
        let date = CommonsDate.date(from: "2013-08-03 12:34:56", in: Self.utc)
        #expect(
            Self.components(date)
                == DateComponents(year: 2013, month: 8, day: 3, hour: 12, minute: 34, second: 56)
        )
    }

    @Test(
        "the shapes DateTimeOriginal comes in are all read",
        arguments: [
            "2013:08:03 12:34:56",
            "2013-08-03T12:34:56",
            "<time class=\"dtstart\" datetime=\"2013-08-03T12:34:56\">3 August 2013</time>",
        ]
    )
    func dateShapes(text: String) {
        #expect(Self.components(CommonsDate.date(from: text, in: Self.utc))?.day == 3)
        #expect(Self.components(CommonsDate.date(from: text, in: Self.utc))?.hour == 12)
    }

    @Test("a date alone is midnight of that day")
    func dateAlone() {
        #expect(
            Self.components(CommonsDate.date(from: "2006-11-26", in: Self.utc))
                == DateComponents(year: 2006, month: 11, day: 26, hour: 0, minute: 0, second: 0)
        )
    }

    @Test(
        "a reading that is not a day is refused rather than guessed at",
        arguments: ["between 1900 and 1910", "1930s", "2013-13-03", "0000:00:00 00:00:00", "2013-08-03 25:00:00", ""]
    )
    func unreadableDates(text: String) {
        #expect(CommonsDate.date(from: text, in: Self.utc) == nil)
    }

    @Test("with no readable capture time, the upload dates the photograph")
    func uploadIsTheFallback() {
        let date = CommonsDate.capturedAt("1930s", uploaded: "2006-12-27T09:44:05Z", timeZone: Self.utc)
        #expect(
            Self.components(date)
                == DateComponents(year: 2006, month: 12, day: 27, hour: 9, minute: 44, second: 5)
        )
        #expect(CommonsDate.capturedAt(nil, uploaded: nil, timeZone: Self.utc) == nil)
    }
}
