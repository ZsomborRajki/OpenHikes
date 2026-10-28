//
//  CommonsPhotoTextTests.swift
//  OpenHikesTests
//
//  The three things a Commons file page says in words — its licence, who took
//  it, and when — read the way ``CommonsLicense``, ``CommonsText`` and
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
    func acceptedLicenses(name: String) {
        #expect(CommonsLicense.accepted(name) == name)
    }

    @Test(
        "a licence asking for more than a credit and a link is left out",
        arguments: ["GFDL", "GFDL 1.2", "FAL", "CC BY-NC 4.0", "CC BY-SA-ND 2.0", "", "Copyrighted"]
    )
    func refusedLicenses(name: String) {
        #expect(CommonsLicense.accepted(name) == nil)
    }

    @Test("a licence name arrives trimmed")
    func licenseIsTrimmed() {
        #expect(CommonsLicense.accepted("  CC BY-SA 4.0\n") == "CC BY-SA 4.0")
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

    /// An escaped entity is one entity, decoded once: `&amp;lt;` is the text
    /// `&lt;`, never `<`.
    @Test("an escaped entity is decoded once")
    func escapedEntityIsDecodedOnce() {
        #expect(CommonsText.plain("Gruber &amp;lt;Studio&amp;gt;") == "Gruber &lt;Studio&gt;")
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
    func licenseLinks() {
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

    @Test(
        "impossible days and incomplete fields use the upload time rather than a manufactured capture time",
        arguments: [
            "2026-02-29",
            "1900-02-29 12:34:56",
            "2026-02-30 12:34:56",
            "2026-02-31 12:34:56",
            "2026-04-31 12:34:56",
            "2026-02-30T12:34:56Z",
            "2026-02-broken-28 12:34:56",
            "2026--02-28 12:34:56",
            "2026:02-28 12:34:56",
            "2026-02-28 12:broken:56",
            "2026-02-28 broken:34:56",
            "2026-02-28 12:34:broken",
            "2026-02-28 12::56",
            "2026-02-28 :34:56",
            "2026-02-28 12:34:",
            "2026-02-28 12:34",
            "2026-02-28 12",
            "2026-02-28T",
            "2026-02-28 broken",
            "2026-02-28 12:34:56:78",
            "2026-02-28 12:34:56 UTC",
        ]
    )
    func invalidCaptureUsesUpload(text: String) {
        #expect(CommonsDate.date(from: text, in: Self.utc) == nil)
        #expect(
            Self.components(CommonsDate.capturedAt(text, uploaded: "2006-12-27T09:44:05Z", timeZone: Self.utc))
                == DateComponents(year: 2006, month: 12, day: 27, hour: 9, minute: 44, second: 5)
        )
    }

    @Test(
        "an ISO offset dates the complete clock independently of the fallback zone",
        arguments: [
            "2026-02-28T12:34:56Z",
            "2026-02-28T14:34:56+02:00",
            "2026-02-28T07:04:56-05:30",
            "<time datetime=\"2026-02-28T14:34:56+02:00\">28 February 2026</time>",
        ]
    )
    func explicitOffset(text: String) throws {
        let elsewhere = try #require(TimeZone(secondsFromGMT: 9 * 60 * 60))
        #expect(
            Self.components(CommonsDate.date(from: text, in: elsewhere))
                == DateComponents(year: 2026, month: 2, day: 28, hour: 12, minute: 34, second: 56)
        )
    }

    @Test(
        "an unsupported or malformed zone-bearing shape uses the upload time",
        arguments: [
            "2026-02-28T12:34:56+25:00",
            "2026-02-28T12:34:56+02:60",
            "2026-02-28T12:34:56+02",
            "2026-02-28T12:34:56+02:",
            "2026-02-28T12:34:56.123Z",
            "2026-02-28T12:34:56UTC",
        ]
    )
    func unsupportedOffsetUsesUpload(text: String) {
        #expect(CommonsDate.date(from: text, in: Self.utc) == nil)
        #expect(
            Self.components(CommonsDate.capturedAt(text, uploaded: "2006-12-27T09:44:05Z", timeZone: Self.utc))
                == DateComponents(year: 2006, month: 12, day: 27, hour: 9, minute: 44, second: 5)
        )
    }

    @Test("a real leap day and the deliberate leap-second rollover remain readable")
    func calendarExceptions() {
        #expect(
            Self.components(CommonsDate.date(from: "2000-02-29", in: Self.utc))
                == DateComponents(year: 2000, month: 2, day: 29, hour: 0, minute: 0, second: 0)
        )
        #expect(
            Self.components(CommonsDate.date(from: "2016-12-31T23:59:60Z", in: Self.utc))
                == DateComponents(year: 2017, month: 1, day: 1, hour: 0, minute: 0, second: 0)
        )
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
