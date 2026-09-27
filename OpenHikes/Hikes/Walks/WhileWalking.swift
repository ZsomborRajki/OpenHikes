//
//  WhileWalking.swift
//  OpenHikes
//
//  Something a hike's screen shows only while that hike is being walked —
//  the progress card at the top of its History, so a walk under way is not
//  one tab away from its Pause and End.
//

import SwiftUI

/// Draws `content` only while `session` holds a walk of `hikeID`, following
/// or paused.
///
/// A view of its own because the question reads the session, and
/// ``HikeDetailView``'s body must never read it: a walk starting or pausing
/// redraws this and not the screen around it. The content is built by that
/// body and only placed here.
struct WhileWalking<Content: View>: View {
    let hikeID: UUID
    let session: TrailWalkSession
    @ViewBuilder let content: Content

    var body: some View {
        if session.isWalking(hikeID) {
            content
        }
    }
}
