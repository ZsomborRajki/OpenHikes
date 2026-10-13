//
//  SheetPresentation+CommonsPhoto.swift
//  OpenHikes
//
//  Opening a Wikimedia Commons photograph the *Community* tab found — see
//  ``CommonsPhotoView``. Split from the presentation for length.
//

import Foundation

extension SheetPresentation {
    /// Opens a photograph's screen, on the terms ``showCommunityHike(_:)``
    /// opens a preview: the sheet makes room, the same photograph is never on
    /// the stack twice, and a different one — or a hike's preview — is
    /// replaced rather than stacked onto. Each is a jump from a pin on the
    /// same map rather than a step deeper.
    func showCommonsPhoto(_ photo: CommonsPhoto) {
        let route = SheetRoute.commonsPhoto(photo)
        guard path.last != route else { return }
        makeRoomForTheMap()
        // Built aside and assigned once — see ``path``.
        var next = path
        if let open = next.firstIndex(of: route) {
            next.removeSubrange((open + 1)...)
        } else {
            next.removeAll { $0.isCommunityPreview }
            next.append(route)
        }
        path = next
    }
}
