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
//  ## Why the keys are worked out before the sort and not during it
//
//  Because three of the four readings are expensive and a sort asks for each of
//  them *n log n* times. `walkCount` is a SwiftData relationship; climb is
//  behind a sidecar fetch; and a locale-aware `compare` allocates on every
//  call. Sorting a two-hundred-hike library by name that way is some sixteen
//  hundred locale comparisons on the main actor, inside a body pass, every
//  time the list is drawn.
//
//  So each hike is measured once — ``key(for:)`` — and the sort runs on plain
//  `Double`s and `String`s. The readings drop from *n log n* to *n*, and what
//  is left is comparisons of numbers.
//

import Foundation

public enum HikeListSort: String, CaseIterable, Identifiable {
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

    public var id: String { rawValue }

    /// The order the menu offers these in, which is not the order they are
    /// declared in — declaration is alphabetical because the lint rule asks
    /// for it, and a menu that opened with *Most Climb* at the top would be
    /// sorted for the compiler rather than for a hiker. Newest is first
    /// because it is the default and the one most often being returned to.
    public static let menuOrder: [Self] = [
        .newest, .alphabetical, .longest, .mostWalked, .hilliest,
    ]

    /// What the menu says, phrased as the answer rather than the field: a
    /// hiker picking an order is asking "show me the long ones", not naming a
    /// column.
    public var title: String {
        switch self {
        case .newest: "Newest First"
        case .alphabetical: "Name"
        case .longest: "Longest"
        case .mostWalked: "Most Walked"
        case .hilliest: "Hilliest"
        }
    }

    public var symbol: String {
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
    public var needsElevation: Bool {
        switch self {
        case .hilliest: true
        case .newest, .alphabetical, .longest, .mostWalked: false
        }
    }

    /// Everything this order needs from one hike, read once.
    ///
    /// `name` is empty for every order but ``alphabetical``, and `figure` is
    /// `nil` for the two that sort on something else — filling either for an
    /// order that does not read it would pay a relationship fault or a fold
    /// for nothing.
    public struct Key {
        /// Bigger is earlier. `nil` for a figure nothing has worked out, which
        /// sorts last.
        public let figure: Double?
        /// Folded for comparison — see ``HikeListSort/key(for:)``.
        public let name: String
        /// The order underneath every other one.
        public let date: Date

        public init(figure: Double?, name: String, date: Date) {
            self.figure = figure
            self.name = name
            self.date = date
        }
    }

    /// Measures one hike for this order.
    public func key(for hike: Hike) -> Key {
        switch self {
        case .newest:
            Key(figure: nil, name: "", date: hike.date)
        case .alphabetical:
            // Folded once here rather than compared with a locale n log n
            // times: case and diacritics are removed so *Écrins* files under E
            // where a hiker looks for it, and what is left compares as plain
            // text. `.current` because the folding of a letter is a question
            // about the reader's language, not about the string.
            Key(
                figure: nil,
                name: hike.displayTitle.folding(
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                    locale: .current
                ),
                date: hike.date
            )
        case .longest:
            Key(figure: hike.distanceMeters, name: "", date: hike.date)
        case .mostWalked:
            Key(figure: Double(hike.walkCount), name: "", date: hike.date)
        case .hilliest:
            Key(figure: hike.verticalMeters, name: "", date: hike.date)
        }
    }

    /// Whether `first` comes before `second`, reading nothing but the keys.
    ///
    /// Ties fall back to the newest, which is the order underneath all of
    /// these: two hikes of the same length, or two that have never been
    /// walked, are still one walk older than the other.
    public func precedes(_ first: Key, _ second: Key) -> Bool {
        if self == .alphabetical {
            if first.name != second.name { return first.name < second.name }
            return first.date > second.date
        }
        switch (first.figure, second.figure) {
        case let (left?, right?):
            return left == right ? first.date > second.date : left > right
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return first.date > second.date
        }
    }
}

public extension Hike {
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
