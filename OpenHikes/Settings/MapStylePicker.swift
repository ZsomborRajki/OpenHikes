//
//  MapStylePicker.swift
//  OpenHikes
//
//  The map choice in Settings: one card per catalog entry, in a row that
//  scrolls sideways, each drawn from that source's own tiles over the ground
//  the hiker is standing on. The selected map's summary sits once under the
//  row rather than on every card.
//
//  Driven entirely by `TileProvider.all`, so a new source is a catalog entry
//  and nothing here — its card, its preview and its lock all follow from the
//  entry's own flags.
//

import SwiftUI
import UIKit

struct MapStylePicker: View {
    /// The stored choice, which a tap writes.
    @Binding var tileProviderID: String
    /// The provider the map is really drawing with — see
    /// ``TileProvider/renderable(id:entitlement:)``. The ring and the summary
    /// follow this, not the stored id, for the reason `SettingsView` gives.
    let selected: TileProvider
    let entitlement: MapEntitlementStore
    /// Read once, in a task, for where to draw the cards — never from a body.
    /// Its coordinate is the highest-frequency value in the app.
    let locationManager: LocationManager
    let showPaywall: () -> Void

    /// `nil` until the task below has read a position, so no card fetches
    /// for ground it is about to abandon.
    @State private var frame: TilePreviewFrame?

    /// With ``MapStyleCard``'s side, three cards and part of a fourth fit a
    /// phone's row: the part is what says the row scrolls.
    private static let cardSpacing: CGFloat = 10
    private static let horizontalMargin: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: Self.cardSpacing) {
                        ForEach(TileProvider.all) { provider in
                            card(for: provider)
                                .id(provider.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
                .contentMargins(.horizontal, Self.horizontalMargin, for: .scrollContent)
                // The selected card is not always one of the first three, and
                // a ring scrolled out of sight is a choice nobody can see.
                .onAppear { proxy.scrollTo(selected.id, anchor: .center) }
            }

            Text(selected.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Self.horizontalMargin)
                .accessibilityIdentifier("map-style-summary")
        }
        .padding(.vertical, 12)
        .task {
            // Not followed: a card is a sample of a style, and the block it
            // shows only changes at a tile boundary anyway.
            frame = TilePreviewFrame(
                around: locationManager.coordinate ?? TilePreviewFrame.fallbackCoordinate
            )
        }
    }

    /// A key-gated source whose key did not resolve is shown but not
    /// selectable: it could only draw a blank map. A locked commercial source
    /// opens the paywall instead of selecting — it *is* available, just not
    /// bought. And while StoreKit has not answered, a paid card is disabled,
    /// because the id is persisted and synced, so a tap taken in that window
    /// would outlive it on every device — see
    /// ``MapEntitlementState/tapAction(for:)``.
    private func card(for provider: TileProvider) -> some View {
        let isUsable = Secrets.canLoadTiles(provider)
        let tap = entitlement.state.tapAction(for: provider)
        return MapStyleCard(
            provider: provider,
            frame: frame,
            isSelected: provider.id == selected.id,
            isLocked: isUsable && tap == .unlock,
            isUsable: isUsable,
            isWaiting: tap == .wait
        ) {
            switch tap {
            case .allow: tileProviderID = provider.id
            case .unlock: showPaywall()
            // Unreachable while the card is disabled, and kept so the rule
            // survives that `.disabled` ever being loosened.
            case .wait: break
            }
        }
        .accessibilityHint(Self.hint(for: tap))
    }

    /// Spoken after the card, because the lock is a glyph and the disabled
    /// state of a waiting card explains itself to nobody.
    private static func hint(for tap: PaidFeatureTap) -> String {
        switch tap {
        case .allow: ""
        case .unlock: "Requires OpenHikes Pro. Opens the unlock screen."
        case .wait: "Checking your subscription."
        }
    }
}

/// One map: its preview, its name, and — when it is not yet bought — a lock.
private struct MapStyleCard: View {
    let provider: TileProvider
    let frame: TilePreviewFrame?
    let isSelected: Bool
    let isLocked: Bool
    let isUsable: Bool
    let isWaiting: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    /// Grows with Dynamic Type, so the name under it never outgrows the card.
    @ScaledMetric(relativeTo: .caption) private var side: CGFloat = 84
    @State private var preview: UIImage?
    /// Whether the last request has answered, so a card that cannot be drawn
    /// stops spinning and says so.
    @State private var hasAnswered = false

    private static let cornerRadius: CGFloat = 12
    private static let ringWidth: CGFloat = 3
    /// Between the image and the ring, so selection never moves the image.
    private static let ringGap: CGFloat = 2
    private static let disabledOpacity: Double = 0.55
    /// A hairline round every image, so a pale map does not bleed into the
    /// sheet behind it.
    private static let edgeOpacity: Double = 0.12
    private static let edgeWidth: CGFloat = 0.5
    private static let lockInset: CGFloat = 6
    private static let lockPadding: CGFloat = 5
    private static let lockBackdropOpacity: Double = 0.55

    /// What the preview depends on: the ground, and — for Apple's map only,
    /// though it is cheaper to key on it everywhere than to ask — the
    /// appearance.
    private struct Request: Hashable {
        let frame: TilePreviewFrame?
        let isDark: Bool
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                thumbnail
                    .frame(width: side, height: side)
                    .clipShape(.rect(cornerRadius: Self.cornerRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: Self.cornerRadius)
                            .strokeBorder(.primary.opacity(Self.edgeOpacity), lineWidth: Self.edgeWidth)
                    }
                    .overlay(alignment: .topTrailing) {
                        if isLocked { lock }
                    }
                    .padding(Self.ringWidth + Self.ringGap)
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: Self.cornerRadius + Self.ringWidth + Self.ringGap)
                                .strokeBorder(Color.accentColor, lineWidth: Self.ringWidth)
                        }
                    }

                Text(provider.name)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if !isUsable {
                    Text("Needs API key")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: side + 2 * (Self.ringWidth + Self.ringGap))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(isUsable && !isWaiting ? 1 : Self.disabledOpacity)
        .disabled(!isUsable || isWaiting)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(provider.name)
        .accessibilityValue(isUsable ? Text(verbatim: "") : Text("Needs API key"))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("provider-row-\(provider.id)")
        .task(id: Request(frame: frame, isDark: colorScheme == .dark)) {
            await load()
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if let preview {
            Image(uiImage: preview)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .accessibilityHidden(true)
        } else {
            Rectangle()
                .fill(.quaternary)
                .overlay {
                    if hasAnswered || !isUsable {
                        Image(systemName: "map")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
                .accessibilityHidden(true)
        }
    }

    /// Small and in the corner: the card is selling the map, and the lock
    /// only has to say there is a step before it.
    private var lock: some View {
        Image(systemName: "lock.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(Self.lockPadding)
            .background(.black.opacity(Self.lockBackdropOpacity), in: .circle)
            .padding(Self.lockInset)
            .accessibilityHidden(true)
    }

    private func load() async {
        guard let frame else { return }
        let source = TilePreviewSource(provider, apiKey: Secrets.apiKey(for: provider))
        let image = await TilePreviewRenderer.image(
            for: source,
            in: frame,
            style: colorScheme == .dark ? .dark : .light,
            side: side
        )
        guard !Task.isCancelled else { return }
        preview = image
        hasAnswered = true
    }
}
