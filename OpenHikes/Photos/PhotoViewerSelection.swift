import Foundation

/// The last real page, retained while this gallery route is on the stack.
/// Scroll geometry remains local to each host and restores from this value
/// after mounting; removing a host must not erase the selected photo.
final class PhotoViewerSelection {
    var currentID: UUID?
}
