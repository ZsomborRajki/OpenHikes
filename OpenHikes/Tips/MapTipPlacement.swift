//
//  MapTipPlacement.swift
//  OpenHikes
//
//  Where on the map the main screen's tip belongs at this moment, if anywhere.
//
//  Decided from what the map can see rather than from TipKit, so a suite can
//  ask every case without a tip store. Which hikers the two tips about making
//  a hike are for is ``CreationTipsAudience``'s decision, handed in. The card
//  itself — what it is made of, and why it is a card and not a popover — is
//  `MapTipCards.swift`'s.
//

/// Where the main screen's due tip is drawn on the map, if anywhere.
nonisolated enum MapTipPlacement: Equatable {
    /// Above the pill on the map's leading edge, for *Record a Hike* or *Make
    /// a Trail* — carried, so a change from one to the other is a change.
    case abovePill(tipID: String)
    /// Under the *Community* tab's *Search this area* pill.
    case underAreaSearch

    /// - Parameters:
    ///   - tipID: The main group's due tip, or `nil` when none is.
    ///   - creationTipsAreWanted: Whether the two about making a hike are for
    ///     this hiker — see ``CreationTipsAudience/wantsTips``.
    ///   - pillIsOffered: Whether the leading pill is on the map, which it is
    ///     while nothing is pushed, and so whether the map is the screen the
    ///     hiker is looking at.
    ///   - areaSearchIsIdle: Whether *Search this area* is on the map and not
    ///     in the middle of a search.
    init?(tipID: String?, creationTipsAreWanted: Bool, pillIsOffered: Bool, areaSearchIsIdle: Bool) {
        switch tipID {
        case let id? where id == RecordHikeTip.tipID || id == MakeTrailTip.tipID:
            // Wanted, not merely not ruled out: a list that has not loaded yet
            // could be an existing hiker's, and an existing hiker is never
            // shown these, not even for that moment.
            guard creationTipsAreWanted, pillIsOffered else { return nil }
            self = .abovePill(tipID: id)
        case let id? where id == SearchThisAreaTip.tipID:
            // Idle, so the tip arrives with the first answer rather than over
            // the spinner that is still fetching it — and only while nothing
            // is pushed. The pill stays with its tab whatever is pushed, but a
            // pushed screen may show a tip of its own, as the recording
            // screen does, and a screen never shows two at once.
            guard areaSearchIsIdle, pillIsOffered else { return nil }
            self = .underAreaSearch
        default:
            // The *Community* tab's tip is drawn by the sheet, under the
            // picker it is about — see ``CommunityTabTipView`` — and nothing
            // else in this group is the map's.
            return nil
        }
    }
}
