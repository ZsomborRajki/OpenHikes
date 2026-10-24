//
//  CreationTipsAudience.swift
//  OpenHikes
//
//  Whether the two tips about making a hike, *Record a Hike* and *Make a
//  Trail*, are for this hiker.
//
//  The owner's rule is that an existing hiker is never told how to make a
//  hike, and the list is the only witness to who is existing: TipKit cannot
//  tell a first install from an update. So the two are for a list with
//  nothing in it, and they retire together the first time it holds a hike,
//  rather than merely not being drawn, so the ordered queue moves on — see
//  ``AppTips``.
//
//  With one exception, and it is the hike the first tip asks for. A hiker who
//  does what *Record a Hike* says starts a recording, and the list is not
//  empty after that. Read as an existing hiker's, that retired *Make a Trail*
//  before it was ever drawn, and a discarded first walk left an empty list
//  with both tips gone for good. So a hiker who taps one of the pill's buttons
//  while their list is empty is a new hiker making their first hike. That is
//  decided once, and ``AppTips`` keeps it in TipKit's own store beside the
//  tips: from then on nothing the list holds retires them, and each goes when
//  it is closed or its button is used. Until then, a hike in the list is the
//  evidence of an existing hiker, however it got there: an import, a walk
//  from the watch, or a recording started by Siri.
//
//  A recording in progress is not a hike in the list yet. Its draft row is
//  inserted the moment it starts, and a discard takes it away again — see
//  ``holdsAHike(_:)``.
//
//  What this cannot see is a list still on its way. On a new phone, hikes
//  synced through iCloud arrive with the mirror's first import, and until
//  then the list reads as empty: an existing hiker is shown *Record a Hike*
//  until the first one lands and retires both. One who taps the pill before
//  then is taken for a new hiker, and is shown *Make a Trail* too.
//
//  A value, so a suite can walk every path without a tip store.
//

import OpenHikesData

nonisolated struct CreationTipsAudience: Equatable {
    /// What the hiker's list was last seen to hold.
    nonisolated enum Library: Equatable {
        case empty
        case hasHikes
        /// Not yet reported, which the two tips about making a hike treat as
        /// *not empty* until a new hiker is known: an existing hiker never
        /// sees them, not even for the moment before the list has loaded.
        case notLoaded
    }

    /// What the list was last reported to hold.
    private(set) var library = Library.notLoaded
    /// Whether this hiker began their first hike from the map's pill — kept
    /// by ``AppTips`` and handed back to every launch, so it is decided once.
    private(set) var isNewHiker: Bool

    init(isNewHiker: Bool) {
        self.isNewHiker = isNewHiker
    }

    /// Whether the map may draw the two now: a new hiker's, or a list known
    /// to be empty.
    var wantsTips: Bool { isNewHiker || library == .empty }

    /// Hears what the list holds, and answers whether the two retire for good:
    /// the first time it holds a hike, unless this is a new hiker.
    mutating func libraryDidLoad(holdsAHike: Bool) -> Bool {
        let reported = holdsAHike ? Library.hasHikes : .empty
        guard library != reported else { return false }
        library = reported
        return holdsAHike && !isNewHiker
    }

    /// Hears that one of the pill's two buttons was tapped, and answers
    /// whether that has just made this a new hiker, for ``AppTips`` to keep.
    ///
    /// Only on a list known to be empty. A list that holds a hike has already
    /// retired the two, and one not yet loaded could be an existing hiker's.
    mutating func pillUsed() -> Bool {
        guard library == .empty, !isNewHiker else { return false }
        isNewHiker = true
        return true
    }

    /// Whether `hikes` holds a hike, for ``libraryDidLoad(holdsAHike:)``.
    ///
    /// A recording in progress is not one. Its draft is a real row with
    /// `isRecording` set, inserted the moment a recording starts, whether from
    /// the pill or from Siri, and a discard deletes it again. It stops at the
    /// first finished hike, so a list read newest first costs a row or two.
    @MainActor
    static func holdsAHike(_ hikes: [Hike]) -> Bool {
        hikes.contains { !$0.isRecording }
    }
}
