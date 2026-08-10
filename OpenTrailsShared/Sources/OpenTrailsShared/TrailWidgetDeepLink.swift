//
//  TrailWidgetDeepLink.swift
//  OpenTrailsShared
//
//  The URL a widget tap hands back to the app, and the parser that turns it
//  into a hike again. Both halves live here so the widget can't format a link
//  the app doesn't recognise.
//
//  No URL scheme registration is needed for this to work: the system already
//  knows which app owns a widget and routes `widgetURL` straight to it. The
//  scheme is only a label — declare it in an Info.plist if these links ever
//  need to be openable from outside the app (Safari, another app, a shortcut).
//

import Foundation

public enum TrailWidgetDeepLink {
    public static let scheme = "opentrails"
    private static let hikeHost = "hike"

    /// Link to a specific hike's detail view.
    public static func url(hikeID: UUID) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = hikeHost
        components.path = "/\(hikeID.uuidString)"
        return components.url
    }

    /// The hike a link points at, or `nil` for anything this doesn't
    /// recognise — including links from a future version, which should open
    /// the app rather than be acted on wrongly.
    public static func hikeID(from url: URL) -> UUID? {
        guard url.scheme == scheme, url.host == hikeHost else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
}
