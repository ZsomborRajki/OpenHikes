//
//  CommunityReport.swift
//  OpenHikes
//
//  What a hiker says about somebody else's published hike, and the message
//  it turns into.
//
//  ## Why this is an email and not a record type
//
//  The obvious shape is a third public record type — a `CommunityReport` a
//  hiker creates the way they create a submission. It was not built, for two
//  reasons that both come from decisions already made elsewhere.
//
//  **Browsing is account-free, and reporting has to be too.** Public reads
//  need no Apple Account, which is why a signed-out phone can find a hike and
//  open it — see ``CommunityFailure/notSignedIn``, which is raised by writes
//  alone. Writes are the other half of that same rule: the public database
//  accepts one only from an authenticated account, so no permission on any
//  record type can let a signed-out hiker file a report. A record-backed
//  report would therefore be missing for exactly the hikers the account-free
//  flow exists for, and the App Store guideline it answers does not have an
//  exemption for them. An email composed on the device needs no account, no
//  permission and no schema.
//
//  **A report has to arrive somewhere a person looks.** The guideline asks
//  for action within 24 hours, and what makes that possible is where the
//  report lands rather than what shape it is in. A record in a database that
//  is opened when somebody remembers to open it is not that; an inbox is. The
//  same address already receives takedown requests — see `docs/privacy/`.
//
//  The cost is stated plainly: this hands off to whatever mail app the device
//  has, and the app cannot watch the message leave. So nothing here claims a
//  report was *sent*, only that it was composed and handed over — the same
//  distinction ``CommunityShareSheet`` keeps between a submission that was
//  sent and one that was published.
//
//  ## Why the record names are in the body
//
//  A takedown is a reviewer's delete, and a delete needs a record ID. The
//  listing's name is what identifies the published hike and the submission's
//  is what identifies the content behind it — deleting the first unlists the
//  hike, deleting the second removes the route and the photographs. A report
//  that named neither would be a reviewer searching a console by title.
//

import Foundation
import OpenHikesData

/// Why a hiker is reporting a published hike.
///
/// Short, and written as things a hiker can recognise on the screen in front
/// of them rather than as moderation categories. Each is a genuinely different
/// thing for a reviewer to look at: two of them are about the *pictures*, one
/// is about the route being wrong, and one is about it being somebody's home.
///
/// ``other`` is not a failure of the list. A report the hiker had to file
/// under the nearest wrong heading is a report a reviewer reads wrongly, and
/// the note beneath is where the actual complaint goes.
nonisolated enum CommunityReportReason: String, CaseIterable, Identifiable, Sendable {
    /// A route that would put somebody in danger, or one that is not the trail
    /// it says it is.
    case misleading = "misleading"
    /// Somebody else's route or photographs, published as this hiker's own.
    case notTheirs = "notTheirs"
    /// The pictures, the title or the description.
    case objectionable = "objectionable"
    case other = "other"
    /// A trail that starts at somebody's door, or a photograph of a person who
    /// did not agree to be in it — the two hazards
    /// ``CommunityShareSheet`` warns the *sharer* about, seen from the other
    /// side.
    case privacy = "privacy"

    /// The order the picker draws them in, which is not the order they are
    /// declared in.
    ///
    /// Declaration order is alphabetical because SwiftLint's
    /// `sorted_enum_cases` requires it, and alphabetical is the wrong reading
    /// order for a list somebody scans under stress: the commonest complaint
    /// belongs at the top and ``other`` belongs at the bottom, since a hiker
    /// who reaches it has already rejected every heading above. So the two
    /// orders are separated rather than one of them being bent to the other.
    static let pickerOrder: [Self] = [.objectionable, .privacy, .notTheirs, .misleading, .other]

    var id: String { rawValue }

    /// What the picker shows.
    var title: String {
        switch self {
        case .objectionable: String(localized: "Offensive or inappropriate")
        case .privacy: String(localized: "Private place or person")
        case .notTheirs: String(localized: "Published without permission")
        case .misleading: String(localized: "Dangerous or misleading route")
        case .other: String(localized: "Something else")
        }
    }

    /// What the email says, which is deliberately not what the picker says.
    ///
    /// The reviewer reads this out of context in an inbox, so it names the
    /// subject as well as the complaint.
    var reportedDescription: String {
        switch self {
        case .objectionable: "Offensive or inappropriate content"
        case .privacy: "Reveals a private place or an identifiable person"
        case .notTheirs: "Published without the owner's permission"
        case .misleading: "Dangerous or misleading route"
        case .other: "Something else"
        }
    }
}

/// One hiker's report of one published hike, and the mail it composes.
///
/// A value rather than a view model, and the whole of what
/// ``CommunityReportSheet`` has to say — so what a reviewer receives can be
/// asserted without a screen, which is what `CommunityReportTests` does.
nonisolated struct CommunityReport: Equatable, Sendable {
    /// Where reports go. The address `docs/privacy/` already publishes, on
    /// purpose: a second one is a second inbox to watch, and the 24-hour
    /// commitment is only as good as the number of places it has to be kept.
    static let recipient = "zsombor.rajki@gmail.com"

    var listing: CommunityListing
    /// The contributed set this is about, when the thing being reported is one
    /// photograph on the hike rather than the hike itself.
    ///
    /// `nil` is the ordinary report and means *this hike*. A value changes
    /// which records the reviewer is pointed at and — the part that matters —
    /// which ones they are told to leave alone: a contributed photograph is
    /// somebody else's picture on a third party's trail, and a report about it
    /// must never read as a request to delete the trail.
    var contribution: CommunityPhotoAttribution?
    var reason: CommunityReportReason
    /// What the hiker typed, or empty. Trimmed on the way in by
    /// ``init(listing:reason:contribution:note:)``.
    var note: String

    init(
        listing: CommunityListing,
        reason: CommunityReportReason,
        contribution: CommunityPhotoAttribution? = nil,
        note: String = ""
    ) {
        self.listing = listing
        self.contribution = contribution
        self.reason = reason
        self.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Carries a record name so a reviewer scanning a mailbox can tell two
    /// reports apart before opening either — the contribution's when there is
    /// one, since that is the record this report is about, and the listing's
    /// otherwise.
    var subject: String {
        contribution.map { "OpenHikes photo report: \($0.contributionID)" }
            ?? "OpenHikes report: \(listing.id)"
    }

    /// Everything the reviewer needs to find the hike, judge the complaint and
    /// delete the right two records.
    ///
    /// Not localized, and that is deliberate rather than an oversight: one
    /// person reads these, in one language, and a report arriving in a
    /// language they cannot read is a report they cannot act on within 24
    /// hours. What the *hiker* reads — the picker, the footer, the
    /// confirmation — is localized; what the reviewer reads is not.
    var body: String {
        var lines = [
            contribution == nil
                ? "A hike published in OpenHikes has been reported."
                : "A photo somebody added to a hike in OpenHikes has been reported.",
            "",
            "Reported for: \(reason.reportedDescription)",
        ]
        if !note.isEmpty {
            lines.append(contentsOf: ["", "From the reporter:", note])
        }
        if let contribution {
            // The contributed records first and on their own, because they are
            // what this report is about; the hike follows as context below.
            lines.append(contentsOf: [
                "",
                "The photos",
                "Added by: \(contribution.credit ?? "(no name given)")",
                "",
                "Records to review",
                "\(CommunitySchema.contributionType): \(contribution.contributionID)",
                "\(CommunitySchema.photoSubmissionType): \(contribution.photoSubmissionID)",
                "",
                "Deleting the \(CommunitySchema.contributionType) record takes the photos off",
                "the hike; deleting the \(CommunitySchema.photoSubmissionType) record removes",
                "the photos themselves.",
                "The hike below is somebody else's and is not part of this report.",
            ])
        }
        lines.append(contentsOf: [
            "",
            contribution == nil ? "The hike" : "The hike they were added to",
            "Title: \(listing.title)",
            "Shared by: \(listing.authorName.isEmpty ? "(no name given)" : listing.authorName)",
            "Walked: \(listing.hikeDate.map(Self.reviewerDate.string(from:)) ?? "(not recorded)")",
            "Published: \(Self.reviewerDate.string(from: listing.publishedAt))",
        ])
        // A report is only ever composed about a hike somebody published —
        // ``CommunityHikeView`` does not offer the action for a curated route,
        // because there is no record for a reviewer to delete and no author to
        // answer for it. This is the guard behind that rather than instead of
        // it: if one ever arrived, the reviewer gets a report that says what it
        // is about instead of two record names that name nothing.
        // A contribution names its own two records above, and the hike below
        // is context rather than a thing to delete — so the listing's own
        // record names are deliberately not repeated for it. A curated trail
        // is the case that makes this matter: it has no records at all, and a
        // report about a photograph on one is still perfectly actionable.
        if contribution != nil { return lines.joined(separator: "\n") }
        guard let submissionID = listing.submissionID else {
            // Read off the origin rather than cut out of the id. Both halves
            // of this are facts about ``CommunityOrigin``, so they cannot come
            // apart: dropping a fixed number of characters off the front of
            // the id would be right only for as long as *no submission* and
            // *curated prefix* happened to agree, and when they stopped, a
            // reviewer would be handed an openstreetmap.org link with six
            // characters chopped off the relation id and no sign anything had
            // gone wrong.
            let upstream = listing.relationID
                .map { "https://www.openstreetmap.org/relation/\($0)" }
                ?? "(this listing names no OpenStreetMap relation: \(listing.id))"
            lines.append(contentsOf: [
                "",
                "This hike came from OpenStreetMap and was not published by anyone.",
                "There is no record to remove. Corrections belong upstream, at",
                upstream,
            ])
            return lines.joined(separator: "\n")
        }
        lines.append(contentsOf: [
            "",
            "Records to review",
            "CommunityHike: \(listing.id)",
            "CommunityHikeSubmission: \(submissionID)",
            "",
            "Deleting the CommunityHike record unlists the hike; deleting the",
            "CommunityHikeSubmission record removes the route and photographs behind it.",
        ])
        return lines.joined(separator: "\n")
    }

    /// The `mailto:` this opens, or `nil` if it could not be formed.
    var mailURL: URL? {
        Self.mailURL(subject: subject, body: body)
    }

    /// One composed message as a `mailto:` to ``recipient``, or `nil` if it
    /// could not be formed.
    ///
    /// Built by hand rather than through `URLComponents.queryItems`, which
    /// would be the obvious way and is wrong here: `&` and `=` are legal in a
    /// query component, so `URLComponents` leaves them alone — and a note
    /// containing either would end the body early and silently truncate the
    /// message.
    ///
    /// Shared with ``CommunityWithdrawal`` rather than restated there: both
    /// carry a free-text note the hiker typed, and the escaping above is the
    /// whole reason a note is safe to carry.
    static func mailURL(subject: String, body: String) -> URL? {
        guard let escapedSubject = escape(subject),
              let escapedBody = escape(body)
        else { return nil }
        return URL(string: "mailto:\(recipient)?subject=\(escapedSubject)&body=\(escapedBody)")
    }

    /// The whole message as one block, for the hiker to copy when there is no
    /// mail app to hand it to. See ``CommunityReportSheet``'s fallback.
    var plainText: String {
        Self.plainText(subject: subject, body: body)
    }

    /// One composed message as the block a hiker copies, when no mail app
    /// answered the `mailto:` above.
    ///
    /// Shared with ``CommunityWithdrawal`` for the reason ``mailURL(subject:body:)``
    /// is: what makes this worth copying is that it carries the recipient, and
    /// a second spelling that drifted would have a hiker paste a message to
    /// nobody.
    static func plainText(subject: String, body: String) -> String {
        "To: \(recipient)\nSubject: \(subject)\n\n\(body)"
    }

    /// Fixed rather than the hiker's locale, for the same reason ``body`` is
    /// not localized: this is read by one person, and two reports whose dates
    /// are formatted differently are two reports that cannot be compared.
    ///
    /// Shared with ``CommunityWithdrawal``, which quotes dates into the same
    /// inbox: two messages about the same hike whose dates disagree in format
    /// are two messages a reviewer has to stop and reconcile.
    static let reviewerDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Percent-encodes one `mailto:` parameter.
    ///
    /// A set narrower than `.urlQueryAllowed` by exactly the characters that
    /// mean something in a query string, plus `+` — which several mail clients
    /// still decode as a space, so a route description containing one would
    /// reach the reviewer altered.
    private static func escape(_ value: String) -> String? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)
    }
}
