import Observation

/// User choices that outlive the portrait sheet / landscape panel host.
/// The navigation session retains this object until the hike is popped.
@Observable
final class HikeDetailInteraction {
    var segment = HikeDetailSegment.details
    var isEditingTitle = false
    var titleDraft = ""
}
