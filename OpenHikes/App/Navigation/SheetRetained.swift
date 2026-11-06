//
//  SheetRetained.swift
//  OpenHikes
//
//  What the screens on the sheet's stack keep, for as long as their routes
//  are on it — and for the pop that takes one off.
//
//  A turn of the phone moves the sheet's contents between the sheet and the
//  side panel, which builds every screen on it again in the other host and
//  takes its `@State` with the old one. So what a screen must not lose there —
//  a hike's chosen segment, a gallery's page, a form, a search, a visit — is
//  an object ``SheetPresentation`` keeps for it, made the first time the
//  screen asks and let go when its route leaves the path.
//
//  **A pop asks once more, after the route has gone.** `MapSheet` builds every
//  pushed screen in one closure that reads the path — how deep a screen is
//  decides whose claim on the map is in force — so a change of path builds
//  each of them again, the one sliding out included. A lookup that kept
//  nothing for the route by then made a new, empty object, and the screen slid
//  out reset: a shared hike's preview showing *Loading route…* (#1349),
//  *Places Around Trail* with nothing found, *Add Place* back to its kind's
//  name, and the hike's own screen, whose `.equatable()` compares its
//  interaction by identity, drawn once more on a new one (#1352). So what a
//  change of path lets go of is kept aside until the next change, and handed
//  to a screen that asks for it in between. A route pushed again is a change
//  of path, and that empties the aside first, so the push starts over.
//

/// One kind of object, kept per key while the path holds the key.
///
/// A value rather than a class: ``SheetPresentation`` holds one of these per
/// kind of object, untracked, so a screen's lookup subscribes nobody to
/// anything.
struct SheetRetained<Key: Hashable, Value: AnyObject> {
    private var kept: [Key: Value] = [:]
    /// What the last change of path let go of, for the screens it is taking
    /// away. See this file's header.
    private var released: [Key: Value] = [:]

    /// The object kept for `key`, or the one its route has just left with, or
    /// else a new one, kept from now on.
    mutating func value(for key: Key, making make: () -> Value) -> Value {
        if let value = kept[key] ?? released[key] { return value }
        let value = make()
        kept[key] = value
        return value
    }

    /// Lets go of every key the path no longer holds, keeping it aside until
    /// the next call. Called on every change of path.
    ///
    /// - Returns: What was let go of, for the caller to stop whatever it still
    ///   has running.
    @discardableResult mutating func release(keeping isOnPath: (Key) -> Bool) -> [Value] {
        released = kept.filter { !isOnPath($0.key) }
        kept = kept.filter { isOnPath($0.key) }
        return Array(released.values)
    }
}
