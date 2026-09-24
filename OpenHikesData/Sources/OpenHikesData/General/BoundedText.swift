//
//  BoundedText.swift
//  OpenHikes
//
//  How long a piece of free text may be, and the one place that decides it.
//
//  ``HikeTitle`` made this argument first and made it for one field: bound the
//  text where a person or a file *enters* it, rather than leaving every later
//  consumer to rediscover that the field is unbounded and defend itself,
//  "and one of them will not". That has since happened. A GPX file carries a
//  description, an author and a keyword list beside the name, and all three
//  went into the store trimmed and otherwise unexamined; a hiker publishing a
//  walk types a name into the share form that nothing measured. Those are the
//  same field shape as a title and they reach further than one — a mirrored
//  SwiftData column, and for the description a record in the **public**
//  database that everybody reads.
//
//  So the rule moved here and ``HikeTitle`` keeps only the bound it argues
//  for. The mechanics are the ones it worked out and are unchanged:
//
//  **Two bounds, and neither implies the other.** A `Character` is a grapheme
//  cluster and a grapheme cluster has no length limit — a base letter followed
//  by ten thousand combining marks is *one* character and forty kilobytes — so
//  a character count alone bounds nothing about what has to be stored or sent.
//  A byte count alone is the version that stores half an emoji. Both, applied
//  in that order, bite together.
//
//  **Truncation is silent.** The cut lands well past the point where the text
//  is still doing its job, and somebody who has just described their walk
//  should not be handed an error about a limit they were never going to reach.
//  The unattended half is the half this is really for: a file that arrived
//  through `Documents/Inbox` was chosen by its sender, and "nobody would type
//  that" is not a bound.
//

import Foundation

/// A ceiling on one kind of free text, in the two units that both have to
/// hold.
nonisolated public struct TextBound: Equatable, Sendable {
    /// Counted in the characters a person would count.
    public let characters: Int
    /// The same ceiling in the unit storage and payloads are rationed in.
    /// Four bytes per character, four being what a single-scalar emoji costs
    /// in UTF-8, so the two bite together on the worst case somebody can
    /// actually type and the byte one alone bites on the rest.
    public var utf8Bytes: Int { characters * 4 }

    public init(characters: Int) {
        self.characters = characters
    }
}

nonisolated extension TextBound {
    // Spelled as named constants rather than inline, so each number is read
    // beside the paragraph that argues for it and none of them is a literal
    // in a call. Each `Self(characters:)` below is the bound; each number
    // here is the figure.
    private static let titleCharacters = 128
    private static let creditCharacters = 64
    private static let notesCharacters = 4096
    private static let keywordsCharacters = 256

    /// A hike's name. 128 to match the worst case the shared package's
    /// `HikeActivityTests` already defends, so that test's ceiling is the most
    /// a title can cost rather than a hypothesis about it. See ``HikeTitle``,
    /// which owns the argument and the call sites.
    public static let title = Self(characters: titleCharacters)

    /// A person's name, as a credit: a GPX file's `metadata/author`, and the
    /// name a hiker publishes a walk under.
    ///
    /// Half a title, because it is shown in half the room — `CommunityHikeRow`
    /// spends one line on "5.2 km · by Anna · 3 photos" — and because a
    /// display name is not prose. Long enough that no real name is cut.
    public static let credit = Self(characters: creditCharacters)

    /// Prose about a walk: a GPX `<desc>`, `<cmt>` or `metadata/desc`, and the
    /// description that travels with a shared hike.
    ///
    /// Generous on purpose, because this one has something to say — several
    /// paragraphs of route notes is an ordinary thing for a trail file to
    /// carry, and a bound that cut those would lose what the hiker imported
    /// the file for. The ceiling is about the failure at the other end: the
    /// column is mirrored, a `CKRecord`'s non-asset payload is capped at 1 MB
    /// by CloudKit, and a description that took a hike past it would make the
    /// row permanently unmirrorable with nothing but a sync diagnostic to say
    /// so. 16 KB is two orders of magnitude inside that and still far more
    /// than anybody writes.
    public static let notes = Self(characters: notesCharacters)

    /// A GPX file's `metadata/keywords`: a comma-separated list, not a
    /// sentence. Room for a few dozen of them.
    public static let keywords = Self(characters: keywordsCharacters)
}

/// Trims and bounds free text.
nonisolated public enum BoundedText {
    /// `raw` trimmed and cut to `bound`, or `nil` when there is nothing left
    /// worth storing.
    ///
    /// `nil` rather than `""` because that is the distinction the callers
    /// draw: an absent description and an empty one are the same thing, and
    /// the optional is what says so once.
    public static func bounded(_ raw: String?, to bound: TextBound) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        // `prefix` counts `Character`s, so the cut lands on a grapheme
        // boundary and cannot split a flag or a skin-toned emoji into
        // unpaired scalars.
        var text = trimmed.count > bound.characters
            ? String(trimmed.prefix(bound.characters))
            : trimmed
        // At most `bound.characters` iterations, each dropping a whole
        // grapheme cluster, whatever it weighs. Deliberately not a `utf8`
        // prefix: that is the version of this that stores half an emoji.
        while text.utf8.count > bound.utf8Bytes {
            text.removeLast()
        }
        // Trimmed again because a cut can expose trailing whitespace that was
        // interior a moment ago, and can leave nothing at all when the first
        // character alone outweighs the budget.
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// The same, for a caller that has nowhere to put an absent value.
    ///
    /// The share form's name field is the one: it is a `String` bound to a
    /// `TextField`, where "blank" is already the way a hiker says they would
    /// rather not be credited, so an optional there would be a second
    /// spelling of the same answer.
    public static func boundedOrEmpty(_ raw: String?, to bound: TextBound) -> String {
        bounded(raw, to: bound) ?? ""
    }
}
