//
//  HikeListSort.swift
//  OpenHikes
//
//  The orders a library can be put in, and what each one reads.
//
//  Two of these are free and four are not, which is the whole reason this is a
//  type rather than a closure. Date, name and length are stored on ``Hike``;
//  how many times a trail has been walked is a relationship to count; and climb
//  and descent are not stored anywhere at all — ``Hike/routeStatistics`` walks
//  every point of a route to work them out, and doing that for a whole library
//  on every redraw is the thing its own documentation warns against. They are
//  cached instead: see ``HikeListMetrics``.
//
//  A hike whose figure is missing sorts last rather than as zero. Zero is a
//  claim — a flat walk — and "not worked out yet" is not one.
//

import Foundation

enum HikeListSort: String, CaseIterable, Identifiable {
    case alphabetical = "alphabetical"
    /// Climb *and* descent together, as one order rather than two.
    ///
    /// They are the same number on a loop and on an out-and-back — you come
    /// down what you went up — so two entries would have offered a hiker the
    /// same list twice. Where they do differ, a point-to-point that mostly
    /// falls, the descent is still what makes the day hard, so adding them is
    /// truer than picking one.
    case hilliest = "hilliest"
    case longest = "longest"
    case mostWalked = "mostWalked"
    /// The order this app has always drawn, and the one it goes back to.
    case newest = "newest"

    var id: String { rawValue }

    /// The order the menu offers these in, which is not the order they are
    /// declared in — declaration is alphabetical because the lint rule asks
    /// for it, and a menu that opened with *Most Climb* at the top would be
    /// sorted for the compiler rather than for a hiker. Newest is first
    /// because it is the default and the one most often being returned to.
    static let menuOrder: [Self] = [
        .newest, .alphabetical, .longest, .mostWalked, .hilliest,
    ]

    /// What the menu says, phrased as the answer rather than the field: a
    /// hiker picking an order is asking "show me the long ones", not naming a
    /// column.
    var title: String {
        switch self {
        case .newest: "Newest First"
        case .alphabetical: "Name"
        case .longest: "Longest"
        case .mostWalked: "Most Walked"
        case .hilliest: "Hilliest"
        }
    }

    var symbol: String {
        switch self {
        case .newest: "calendar"
        case .alphabetical: "textformat.abc"
        case .longest: "ruler"
        case .mostWalked: "figure.hiking"
        case .hilliest: "mountain.2"
        }
    }

    /// Whether this order needs figures nothing has worked out yet.
    ///
    /// Only ``hilliest`` does, and asking for it is what sets the cache
    /// filling. Everything else reads what a hike already carries.
    var needsElevation: Bool {
        switch self {
        case .hilliest: true
        case .newest, .alphabetical, .longest, .mostWalked: false
        }
    }

    /// Whether `first` comes before `second` in this order.
    ///
    /// Ties fall back to the newest, which is the order underneath all of
    /// these: two hikes of the same length, or two that have never been
    /// walked, are still one walk older than the other.
    func sorts(_ first: Hike, before second: Hike) -> Bool {
        switch self {
        case .newest:
            first.date > second.date
        case .alphabetical:
            Self.compareNames(first, second)
        case .longest:
            Self.compare(first.distanceMeters, second.distanceMeters, first, second)
        case .mostWalked:
            Self.compare(Double(first.walkCount), Double(second.walkCount), first, second)
        case .hilliest:
            Self.compare(first.verticalMeters, second.verticalMeters, first, second)
        }
    }

    /// Case- and diacritic-insensitive, so *Écrins* files under E where a
    /// hiker looks for it rather than after Z.
    private static func compareNames(_ first: Hike, _ second: Hike) -> Bool {
        let order = first.displayTitle.compare(
            second.displayTitle,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: nil,
            locale: .current
        )
        if order == .orderedSame { return first.date > second.date }
        return order == .orderedAscending
    }

    /// Bigger first, with a missing figure last and the newest breaking ties.
    private static func compare(
        _ first: Double?,
        _ second: Double?,
        _ firstHike: Hike,
        _ secondHike: Hike
    ) -> Bool {
        switch (first, second) {
        case let (left?, right?):
            left == right ? firstHike.date > secondHike.date : left > right
        case (.some, nil): true
        case (nil, .some): false
        case (nil, nil): firstHike.date > secondHike.date
        }
    }
}

extension Hike {
    /// Everything this walk goes up and down, added.
    ///
    /// `nil` until both halves have been measured — see
    /// ``HikeLocalState/climbMeters``. Half a figure is not a smaller figure,
    /// it is an unfinished one, and sorting on it would put a hike wherever
    /// the measured half happened to land.
    var verticalMeters: Double? {
        guard let climbMeters, let descentMeters else { return nil }
        return climbMeters + descentMeters
    }

    /// How many walks this trail has a record of.
    ///
    /// Read through the relationship rather than stored, which means faulting
    /// it once per hike the first time a library is sorted this way. That is
    /// the cost of an order a hiker asked for, paid once — the alternative is
    /// a counter on the row that every writer of a walk has to remember to
    /// keep, and the first one that forgets makes the list quietly wrong.
    var walkCount: Int { walks?.count ?? 0 }
}
