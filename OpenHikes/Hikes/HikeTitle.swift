//
//  HikeTitle.swift
//  OpenHikes
//
//  What a hike may be called, and the one place that decides it.
//
//  A title was the *first* free text this app carried from a person or a file
//  into a payload with a hard ceiling, and for a while it was the only one that
//  was bounded at all. `HikeActivityAttributes` shares ActivityKit's
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
//  That argument outgrew the title, which is why the mechanics now live in
//  ``BoundedText`` and this file keeps only the bound it makes the case for.
//  The prediction above came true in the ordinary way: a GPX carries a
//  description, an author and a keyword list beside the name, and not one of
//  the three was defended by anybody.
//
//  Truncation is deliberately silent. The cut lands past the point where a
//  title is still a title, and a person who has just named their walk should
//  not be handed an error about a limit they were never going to reach.
//

import Foundation

nonisolated enum HikeTitle {
    /// The longest name a hike may be given, counted in the characters a
    /// person would count.
    ///
    /// 128 to match the worst case `HikeActivityTests` already defends, so
    /// that test's ceiling stops being a hypothesis about what a title might
    /// cost and starts being the most one can. Characters rather than bytes
    /// because that is the unit the limit is *about* — the emoji and CJK
    /// worst case is exactly what that test measures in bytes on the other
    /// side of this bound, and it does so against this number.
    ///
    /// Read off ``TextBound/title`` rather than spelled again, and re-exported
    /// here rather than left there because the payload argument above is made
    /// about *this* name: the shared package's suite checks itself against
    /// this number, and a title's callers should not have to know which bound
    /// in the list is theirs.
    static let maximumCharacters = TextBound.title.characters

    /// The same bound in the unit the payload is actually rationed in: 512,
    /// four bytes per character being what a single-scalar emoji costs in
    /// UTF-8. ``BoundedText`` carries why both bounds are needed and why
    /// neither implies the other.
    static let maximumUTF8Bytes = TextBound.title.utf8Bytes

    /// A name as it should be stored: trimmed, bounded, and `nil` when there
    /// is nothing left worth storing.
    ///
    /// `nil` rather than `""` because that is the distinction ``Hike``
    /// draws — see ``Hike/displayTitle``, which falls back to the original
    /// title only when `customName` is absent or empty.
    static func bounded(_ raw: String?) -> String? {
        BoundedText.bounded(raw, to: .title)
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

    /// The name a trail drawn on the map gets: what the hiker typed, otherwise
    /// the day they drew it.
    ///
    /// Here rather than inside ``TrailDraftSave`` for the reason
    /// ``imported(trackName:fileURL:)`` is here rather than inside
    /// `HikeImport`: which source wins is a decision, a suite should be able
    /// to drive it without a `ModelContainer`, and this file is where a new
    /// way of naming a hike has to arrive — a title is bounded where it is
    /// entered, and the maker's field is a new place to enter one.
    ///
    /// The date fallback rather than an empty string, and for the reason the
    /// watch's is: an empty name leaves two unnamed trails indistinguishable
    /// in a list, and a drawn trail has no file and no track name to fall back
    /// on the way an import does.
    static func drawn(name: String?, madeOn date: Date) -> String {
        bounded(name) ?? bounded(
            "Trail, " + date.formatted(date: .abbreviated, time: .shortened)
        ) ?? ""
    }

    /// The name a walk recorded on the watch gets: the trail it was walked
    /// along, otherwise the day it was walked on.
    ///
    /// Here rather than inside `WatchWalkImport` for the reason
    /// ``imported(trackName:fileURL:)`` is here rather than inside
    /// `HikeImport`: which source wins is a decision, a suite should be able
    /// to drive it without a `ModelContainer`, and a name arriving from
    /// another device is the sender's exactly as a GPX `<name>` is.
    ///
    /// The date fallback rather than an empty string, because this name is
    /// also the only thing distinguishing two free recordings in a list —
    /// where an import at least has the file it came from to fall back to.
    static func watchRecording(trailName: String?, recordedAt: Date) -> String {
        bounded(trailName) ?? bounded(
            "Watch Hike, " + recordedAt.formatted(date: .abbreviated, time: .shortened)
        ) ?? ""
    }
}

/// What a name typed into a field means for the hike behind it.
///
/// Its own type, and a small one, because the rule is easy to get subtly wrong
/// in three separate ways and a `View` is not a place a suite can ask about
/// any of them.
///
/// *Unchanged* is not the same as *empty*. ``Hike/displayTitle`` falls back to
/// ``Hike/title`` when there is no custom name, so a field seeded with the
/// displayed name and left alone would, written back naively, turn a hike's
/// own title into a custom name that happens to match it — a mirrored write
/// that changes nothing anybody can see and costs a sync.
///
/// *Cleared* is not the same as *unchanged* either. Emptying the field means
/// "go back to what this hike was called", which is `customName = nil` rather
/// than `customName = ""`, and is the one case that has to write a `nil` on
/// purpose.
///
/// Both go through ``HikeTitle/bounded(_:)``, so a name entered here is
/// bounded where every other name entering this app is — see that type for why
/// both bounds are load-bearing.
nonisolated enum HikeTitleEdit: Equatable {
    /// Put this on the hike as its custom name, or `nil` to take the custom
    /// name off and fall back to the original title.
    case renamed(String?)
    /// The field says what the hike already says. Write nothing.
    case unchanged

    static func of(_ draft: String, against displayTitle: String) -> Self {
        let bounded = HikeTitle.bounded(draft)
        return (bounded ?? "") == displayTitle ? .unchanged : .renamed(bounded)
    }
}
