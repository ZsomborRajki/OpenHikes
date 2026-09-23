//
//  TrailStopList.swift
//  OpenHikes
//
//  The stops, as Apple Maps lists them: a grabber on every stop at all times,
//  and a swipe that deletes one.
//
//  ## Why UIKit
//
//  SwiftUI's `List` cannot have both. Its grabbers exist only in edit mode, and
//  edit mode takes the swipe actions away — the maker spent one build in
//  permanent edit mode and lost *Delete* to it. Outside edit mode `.onMove`
//  does nothing on a drag (see the hike library's *Reorder Hikes*), iOS 27's
//  `reorderable()` inside a `List` drew no grabber and never reached its
//  `reorderContainer` in any arrangement tried, and a drag gesture of our own
//  on a handle lost the drag to the list's scroll view. A `UICollectionView`
//  list has what Maps has: a reorder accessory that is shown, and works,
//  outside editing, beside the trailing swipe actions.
//
//  So the stops are one `List` row holding a collection view that does not
//  scroll and is exactly as tall as its rows, each row the same
//  ``TrailStopRowView`` in a `UIHostingConfiguration`. *Add Stop* stays a
//  `List` row underneath: it neither moves nor deletes.
//
//  ## Render isolation
//
//  `updateUIView` reads ``TrailDraft/slots`` and nothing else, so it runs when a
//  row comes, goes or moves. Names, distances and notices are read by the rows
//  inside their hosting configurations, which observe the draft on their own —
//  the argument ``TrailStopRowView``'s header makes, unchanged.
//

import SwiftUI
import UIKit

struct TrailStopList: UIViewRepresentable {
    let draft: TrailDraft
    /// Opens the search sheet on a row.
    var onSearch: (TrailStopSlot) -> Void
    /// A drop: the stop that was dragged, and the stop it now sits in front
    /// of, or `nil` for the end.
    var onMove: (_ stop: UUID, _ before: UUID?) -> Void
    /// VoiceOver's *Move Up* and *Move Down* on a stop.
    var onStep: (UUID, AccessibilityAdjustmentDirection) -> Void
    /// The trailing swipe's *Delete*.
    var onDelete: (UUID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UICollectionView {
        let coordinator = context.coordinator
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        // The stems cross every join — see ``TrailStopRowView``'s header.
        configuration.showsSeparators = false
        // The `List` card behind shows through, as it does behind *Add Stop*.
        configuration.backgroundColor = .clear
        configuration.trailingSwipeActionsConfigurationProvider = { [weak coordinator] indexPath in
            coordinator?.swipeActions(at: indexPath)
        }
        let view = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration)
        )
        view.backgroundColor = .clear
        // The `List` around it scrolls; this is exactly as tall as its rows.
        view.isScrollEnabled = false
        // A row is a `Button` that opens the search, so the cell has nothing
        // to select and no highlight to draw over it.
        view.allowsSelection = false
        coordinator.install(in: view)
        return view
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        context.coordinator.list = self
        context.coordinator.show(draft.slots, of: draft)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: UICollectionView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let coordinator = context.coordinator
        let rowHeight = coordinator.rowHeight(for: view.traitCollection)
        return CGSize(width: width, height: rowHeight * CGFloat(coordinator.rowCount))
    }
}

extension TrailStopList {
    final class Coordinator {
        /// The latest of the view's values, for the closures and the draft.
        var list: TrailStopList?
        private var dataSource: UICollectionViewDiffableDataSource<Int, String>?
        /// What the rows were last built from, so a row can be found by its
        /// identifier.
        private var slots: [TrailStopSlot] = []
        /// The draft those rows read. The open fields' identifiers are the
        /// same in every draft, so a new one has to be noticed by itself.
        private weak var shownDraft: TrailDraft?

        /// Every row's height, and so the list's: rows × this.
        ///
        /// Worked out rather than measured, because measuring means laying the
        /// cells out, and a cell's `UIHostingConfiguration` cannot update its
        /// SwiftUI graph from inside `sizeThatFits` — SwiftUI is mid-update
        /// there and aborts. So each row is *given* this height rather than
        /// asked for one, and the two cannot disagree.
        private var givenRowHeight = (UIFont.preferredFont(forTextStyle: .body).lineHeight
            + 2 * TrailStopRowView.rowPadding).rounded()

        var rowCount: Int { slots.count }

        /// From the card's trailing edge to the grabber's, measured off the
        /// same Apple Maps screenshot as ``TrailStopRowView/railWidth``.
        private static let grabberMargin: CGFloat = 21.5

        func install(in view: UICollectionView) {
            typealias Registration = UICollectionView.CellRegistration<UICollectionViewListCell, String>
            let registration = Registration { [weak self] cell, _, id in
                self?.configure(cell, for: id)
            }
            let source = UICollectionViewDiffableDataSource<Int, String>(
                collectionView: view
            ) { collectionView, indexPath, id in
                collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
            }
            // An open field is not a stop yet, so it has no place in the order.
            // It never shares the list with a second point, so nothing can be
            // dropped past one either.
            source.reorderingHandlers.canReorderItem = { [weak self] id in
                self?.slot(id)?.waypointIndex != nil
            }
            source.reorderingHandlers.didReorder = { [weak self] transaction in
                self?.commit(transaction)
            }
            dataSource = source
        }

        /// Rebuilds the rows when they changed, and only then. `updateUIView`
        /// runs whenever the screen around this does, and re-applying rows to
        /// a list mid-drag would cancel the drag under the finger.
        func show(_ slots: [TrailStopSlot], of draft: TrailDraft, force: Bool = false) {
            guard let dataSource, force || slots != self.slots || draft !== shownDraft else { return }
            let isFirst = self.slots.isEmpty
            self.slots = slots
            shownDraft = draft
            let ids = slots.map(\.id)
            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            snapshot.appendItems(ids)
            // Every surviving row, not only the new ones: a row's position is
            // its role and decides its stems, and a row added or dragged
            // changes the position of the rows around it.
            let existing = Set(dataSource.snapshot().itemIdentifiers)
            snapshot.reconfigureItems(ids.filter(existing.contains))
            dataSource.apply(snapshot, animatingDifferences: !isFirst)
        }

        /// One line of body text at the hiker's type size, and the row's
        /// padding either side of it — what ``TrailStopRowView`` would size
        /// itself to. A change of type size re-lays the list out, which asks
        /// again, and the rows are rebuilt at the new height on the next turn.
        ///
        /// Whole points, not pixels: a fractional height such as 49⅓ reaches
        /// the cell as a hair over 148 pixels, the cell rounds that up to 149,
        /// and every row comes out a third of a point taller than the list
        /// that was sized for it.
        func rowHeight(for traits: UITraitCollection) -> CGFloat {
            let line = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits).lineHeight
            let height = (line + 2 * TrailStopRowView.rowPadding).rounded()
            if height != givenRowHeight {
                givenRowHeight = height
                Task { @MainActor [weak self] in
                    guard let self, let list else { return }
                    show(list.draft.slots, of: list.draft, force: true)
                }
            }
            return height
        }

        func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
            guard
                let list,
                let id = dataSource?.itemIdentifier(for: indexPath),
                case .point(_, let stopID)? = slot(id)
            else { return nil }
            let delete = UIContextualAction(style: .destructive, title: String(localized: "Delete")) { _, _, done in
                list.onDelete(stopID)
                done(true)
            }
            delete.image = UIImage(systemName: "trash")
            return UISwipeActionsConfiguration(actions: [delete])
        }

        private func slot(_ id: String) -> TrailStopSlot? {
            slots.first { $0.id == id }
        }

        private func configure(_ cell: UICollectionViewListCell, for id: String) {
            guard let list, let position = slots.firstIndex(where: { $0.id == id }) else { return }
            let slot = slots[position]
            var onStep: ((AccessibilityAdjustmentDirection) -> Void)?
            if case .point(_, let stopID) = slot {
                onStep = { list.onStep(stopID, $0) }
            }
            cell.contentConfiguration = UIHostingConfiguration {
                TrailStopRowView(draft: list.draft, position: position, onStep: onStep) {
                    list.onSearch(slot)
                }
                .frame(height: givenRowHeight)
            }
            // No vertical margin, so the stems reach the cell's edges; the
            // leading one is the inset every other row in the card has.
            .margins(.vertical, 0)
            .margins(.leading, 16)
            .margins(.trailing, onStep == nil ? 16 : 0)
            .minSize(height: 0)
            cell.backgroundConfiguration = .clear()
            // The grabber sits where Maps' does, a few points further in than
            // a list cell's own margin would put it.
            cell.directionalLayoutMargins.trailing = Self.grabberMargin
            cell.accessories = onStep == nil ? [] : [.reorder(displayed: .always)]
        }

        /// A drop, as the draft moves by it: the stop that was dragged, and
        /// the stop it now sits in front of, or `nil` for the end.
        struct Drop: Equatable {
            let stop: UUID
            let before: UUID?
        }

        /// Reads a drop out of the list's order after it: `movedID` is the row
        /// that moved, `order` every row's identifier as they now stand, and
        /// `slots` the rows as they stood before. `nil` for a row that is not a
        /// stop. The row after it being an open field is a drop at the end —
        /// the destination field is the only one that can follow a point.
        static func drop(of movedID: String, in order: [String], slots: [TrailStopSlot]) -> Drop? {
            func stopID(_ id: String) -> UUID? {
                guard case .point(_, let stopID)? = slots.first(where: { $0.id == id }) else { return nil }
                return stopID
            }
            guard let stop = stopID(movedID), let index = order.firstIndex(of: movedID) else { return nil }
            let next = order.indices.contains(index + 1) ? order[index + 1] : nil
            return Drop(stop: stop, before: next.flatMap(stopID))
        }

        /// Hands a drop to the draft.
        ///
        /// A drag moves one row, and the difference names it as its insertion.
        /// The rows are rebuilt from the draft on the next turn whatever it
        /// did with the move: `updateUIView` would do it for a move the draft
        /// took, and nothing would for one it refused, leaving the row where
        /// the finger put it and the line where it was.
        private func commit(_ transaction: NSDiffableDataSourceTransaction<Int, String>) {
            guard let list else { return }
            let movedID = transaction.difference.insertions.lazy.compactMap { change -> String? in
                guard case .insert(_, let id, _) = change else { return nil }
                return id
            }.first
            if let movedID,
               let drop = Self.drop(of: movedID, in: transaction.finalSnapshot.itemIdentifiers, slots: slots) {
                list.onMove(drop.stop, drop.before)
            }
            Task { @MainActor [weak self] in
                guard let self, let list = self.list else { return }
                show(list.draft.slots, of: list.draft, force: true)
            }
        }
    }
}
