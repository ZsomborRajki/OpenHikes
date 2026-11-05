import Observation

/// User choices that outlive the portrait sheet / landscape panel host.
/// The navigation session retains this object until the hike is popped.
@Observable
final class HikeDetailInteraction {
    var segment = HikeDetailSegment.details
    var isEditingTitle = false
    var titleDraft = ""
    /// The hike's line, read off the main actor: here because the session
    /// keeps this for as long as any screen about the hike is on the path, and
    /// the screens pushed over the detail read the same line — see
    /// ``ShownLine``.
    let line = ShownLine()
}
