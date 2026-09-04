//
//  HikeTitle.swift
//  OpenHikes
//
//  What a hike may be called, and the one place that decides it.
//
//  A title is the only free text this app carries from a person or a file into
//  a payload with a hard ceiling. `HikeActivityAttributes` shares ActivityKit's
//  4 KB with everything else on the Lock Screen panel, and the shared package's
//  `HikeActivityTests` defends a worst case built on a 128-character name — a
//  bound that test named as its own rather than the app's, because the app had
//  none. This is the app's.
//
//  Bounded where the name is *entered* rather than where it is spent, which is
//  the whole argument. Absorbing it downstream means every future consumer of a
//  title — a payload, a widget snapshot, a shared-store write — has to
//  rediscover that the field is unbounded and defend itself, and one of them
//  will not. A GPX arriving through `Documents/Inbox` was chosen by its sender
//  and read unattended, so "nobody would type that" is not a bound; it is a
//  guess about the half of the input that a person actually looks at.
//
//  Truncation is deliberately silent. The cut lands past the point where a
//  title is still a title, and a person who has just named their walk should
//  not be handed an error about a limit they were never going to reach.
//

import Foundation

nonisolated enum HikeTitle {
    /// The longest name a hike may be given, counted in the characters a
    /// person would count rather than in bytes.
    ///
    /// 128 to match the worst case `HikeActivityTests` already defends, so
    /// that test's ceiling stops being a hypothesis about what a title might
    /// cost and starts being the most one can. Characters rather than bytes
    /// because that is the unit the limit is *about* — the emoji and CJK
    /// worst case is exactly what that test measures in bytes on the other
    /// side of this bound, and it does so against this number.
    static let maximumCharacters = 128

    /// The same bound in the unit the payload is actually rationed in.
    ///
    /// Both bounds are needed and neither implies the other. A `Character` is
    /// a grapheme cluster, and a grapheme cluster has no length limit — a base
    /// letter followed by ten thousand combining marks is *one* character and
    /// forty kilobytes, so a character count alone bounds nothing about what
    /// the Lock Screen has to carry. That is not a shape anybody types; it is
    /// exactly the shape a file arrives in, which is the input this bound
    /// exists for.
    ///
    /// 512 = 128 × 4, four bytes being what a single-scalar emoji costs in
    /// UTF-8. So the two bounds bite together on the worst case a person can
    /// actually produce, and the byte one alone bites on the rest.
    static let maximumUTF8Bytes = maximumCharacters * 4

    /// A name as it should be stored: trimmed, bounded, and `nil` when there
    /// is nothing left worth storing.
    ///
    /// `nil` rather than `""` because that is the distinction ``Hike``
    /// draws — see ``Hike/displayTitle``, which falls back to the original
    /// title only when `customName` is absent or empty.
    static func bounded(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        // `prefix` counts `Character`s, so the cut lands on a grapheme
        // boundary and cannot split a flag or a skin-toned emoji into
        // unpaired scalars.
        var name = trimmed.count > maximumCharacters
            ? String(trimmed.prefix(maximumCharacters))
            : trimmed
        // At most `maximumCharacters` iterations, each dropping a whole
        // grapheme cluster, whatever it weighs. Deliberately not a `utf8`
        // prefix: that is the version of this that stores half an emoji.
        while name.utf8.count > maximumUTF8Bytes {
            name.removeLast()
        }
        // Trimmed again because a cut can expose trailing whitespace that was
        // interior a moment ago, and can leave nothing at all when the first
        // character alone outweighs the budget.
        let bounded = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return bounded.isEmpty ? nil : bounded
    }

    /// The name an imported track gets: its own `<name>` when it has a usable
    /// one, otherwise the file it arrived in.
    ///
    /// Both halves go through ``bounded(_:)``, because both are the sender's:
    /// a GPX with a megabyte `<name>` and a GPX named by a megabyte filename
    /// are the same file with the text moved.
    ///
    /// Its own function rather than an expression inside the importer so the
    /// composition — which source wins, and that neither escapes the bound —
    /// is something a suite can drive without assembling an `OpenHikesModel`.
    static func imported(trackName: String?, fileURL: URL) -> String {
        bounded(trackName)
            ?? bounded(fileURL.deletingPathExtension().lastPathComponent)
            ?? ""
    }
}
