//
//  MapTipPlacement.swift
//  OpenHikes
//
//  Where on the map the main screen's tip belongs at this moment, if anywhere.
//
//  Decided from what the map can see rather than from TipKit, so a suite can
//  ask every case without a tip store. The card itself — what it is made of,
//  and why it is a card and not a popover — is `MapTipCards.swift`'s.
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
    ///   - libraryIsKnownEmpty: Whether the hiker's list has loaded and holds
    ///     nothing — see ``AppTips/Library``.
    ///   - pillIsOffered: Whether the leading pill is on the map, which it is
    ///     while nothing is pushed.
    ///   - areaSearchIsIdle: Whether *Search this area* is on the map and not
    ///     in the middle of a search.
    init?(tipID: String?, libraryIsKnownEmpty: Bool, pillIsOffered: Bool, areaSearchIsIdle: Bool) {
        switch tipID {
        case let id? where id == RecordHikeTip.tipID || id == MakeTrailTip.tipID:
            // Known to be empty, not merely not known to hold anything: a
            // hiker with hikes is never shown these, not even for the moment
            // before the list has loaded.
            guard libraryIsKnownEmpty, pillIsOffered else { return nil }
            self = .abovePill(tipID: id)
        case let id? where id == SearchThisAreaTip.tipID:
            // Idle, so the tip arrives with the first answer rather than over
            // the spinner that is still fetching it.
            guard areaSearchIsIdle else { return nil }
            self = .underAreaSearch
        default:
            // The *Community* tab's tip is drawn by the sheet, under the
            // picker it is about — see ``CommunityTabTipView`` — and nothing
            // else in this group is the map's.
            return nil
        }
    }
}
