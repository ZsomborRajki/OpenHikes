//
//  TrailWidgetDeepLink.swift
//  OpenHikesShared
//
//  The URL a widget tap hands back to the app, and the parser that turns it
//  back into a destination — a hike, the live recording, or the live
//  recording's Stop. Both halves live here so the widget can't format a link
//  the app doesn't recognise.
//
//  The Stop is the Live Activity's: a button on the Lock Screen can ask
//  nothing, and the app's Stop asks first — a name, with *Discard Recording*
//  and *Keep Recording* beside it — so the panel's Stop opens the app with
//  that question up rather than ending anything itself. A build from before
//  it reads the link as one it does not know, and only opens.
//
//  No URL scheme registration is needed for this to work: the system already
//  knows which app owns a widget and routes `widgetURL` straight to it. The
//  scheme is only a label — declare it in an Info.plist if these links ever
//  need to be openable from outside the app (Safari, another app, a shortcut).
//

import Foundation

public enum TrailWidgetDeepLink {
    public enum Destination: Equatable, Sendable {
        case hike(UUID)
        case recording
        /// The live recording, with Stop's question asked.
        case stopRecording
    }

    public static let scheme = "openhikes"
    private static let hikeHost = "hike"
    private static let recordingHost = "recording"
    private static let stopPath = "/stop"

    /// Link to a specific hike's detail view.
    public static func url(hikeID: UUID) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = hikeHost
        components.path = "/\(hikeID.uuidString)"
        return components.url
    }

    public static func recordingURL() -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = recordingHost
        return components.url
    }

    /// Link to the live recording, asking Stop's question once it is open.
    public static func stopRecordingURL() -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = recordingHost
        components.path = stopPath
        return components.url
    }

    public static func destination(from url: URL) -> Destination? {
        guard url.scheme == scheme else { return nil }
        switch url.host {
        case hikeHost:
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            return .hike(id)

        case recordingHost:
            switch url.path {
            case "": return .recording
            case stopPath: return .stopRecording
            default: return nil
            }

        default: return nil
        }
    }

    /// The hike a link points at, or `nil` for anything this doesn't
    /// recognise — including links from a future version, which should open
    /// the app rather than be acted on wrongly.
    public static func hikeID(from url: URL) -> UUID? {
        guard case .hike(let id) = destination(from: url) else { return nil }
        return id
    }
}
