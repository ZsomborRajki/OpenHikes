//
//  MapModesSheet.swift
//  OpenHikes
//
//  *Map Modes*: which map is drawn, chosen on the map it changes, as in Apple
//  Maps. A row of cards, the selected map's summary, the *Hiking Routes*
//  choice drawn over whichever map that is, and every card's credits along
//  the bottom.
//
//  It was a section of Settings, where a tap changed a map nobody could see:
//  Settings covers it. Here the sheet is only as tall as its cards, so the
//  map above it turns over as they are tapped.
//
//  The button that opens it is in the map's own pill, over the "my location"
//  button — see `MapCoordinator+TrackingButton.swift` — and the sheet is
//  presented from inside the map sheet's contents, for the reason
//  ``MapScreenAlerts`` gives: a modal attached beside a sheet that is never
//  dismissed is never presented at all. ``MapModesPresentation`` carries the
//  tap from one to the other, and ``MapControlModals`` says which sheet
//  presents it.
//

import SwiftUI

extension View {
    /// Attaches *Map Modes* to `presenter`: the map sheet's contents, not the
    /// view that presents the sheet, or a place card over them — see
    /// ``MapControlModals``.
    func mapModesSheet(
        _ modals: MapControlModals,
        from presenter: MapControlModals.Presenter,
        entitlement: MapEntitlementStore,
        locationManager: LocationManager
    ) -> some View {
        modifier(
            MapModesSheetModifier(
                modals: modals,
                presenter: presenter,
                entitlement: entitlement,
                locationManager: locationManager
            )
        )
    }
}

private struct MapModesSheetModifier: ViewModifier {
    let modals: MapControlModals
    let presenter: MapControlModals.Presenter
    let entitlement: MapEntitlementStore
    let locationManager: LocationManager

    func body(content: Content) -> some View {
        content.sheet(isPresented: modals.binding(modals.mapModes.isPresentedBinding, for: presenter)) {
            MapModesView(
                entitlement: entitlement,
                locationManager: locationManager,
                onClose: modals.mapModes.dismiss
            )
        }
    }
}

struct MapModesView: View {
    let entitlement: MapEntitlementStore
    /// Read once, by the cards, for the ground their previews show.
    let locationManager: LocationManager
    let onClose: () -> Void

    @AppStorage(SettingsKey.tileProviderID) private var tileProviderID = TileProvider.default.id
    @AppStorage(SettingsKey.showsHikingRoutes) private var showsHikingRoutes = SettingsDefault.showsHikingRoutes
    @State private var showPaywall = false
    /// How tall the contents stand, which is how tall the sheet is: nothing
    /// under the credits, and as much of the map as that leaves above them.
    @State private var contentHeight = Self.estimatedHeight

    /// What the sheet opens at for the one pass before it has been measured.
    private static let estimatedHeight: CGFloat = 320
    private static let horizontalMargin: CGFloat = 16
    private static let topPadding: CGFloat = 14
    private static let bottomPadding: CGFloat = 8
    private static let noteSpacing: CGFloat = 6
    private static let headerSpacing: CGFloat = 8

    /// The provider the map is really drawing with, which is not always the
    /// stored one — see ``TileProvider/renderable(id:entitlement:)``. The
    /// ring, the summary and the credits follow this: Stadia's credits over
    /// OpenStreetMap tiles would be wrong twice over.
    ///
    /// Reads `entitlement.state` rather than letting `renderable` default to
    /// the process-wide answer, so this recomputes when StoreKit resolves.
    private var selectedProvider: TileProvider {
        TileProvider.renderable(id: tileProviderID, entitlement: entitlement.state)
    }

    /// The map's credits and the layer's, then every source the sheet shows
    /// a picture of — see ``TileAttribution/mapModes(selected:showsHikingRoutes:cards:)``.
    /// A card is drawn only from a source whose key resolved.
    private var credits: TileAttribution {
        TileAttribution.mapModes(
            selected: selectedProvider,
            showsHikingRoutes: showsHikingRoutes,
            cards: TileProvider.all.filter(Secrets.canLoadTiles)
        )
    }

    var body: some View {
        // Scrolls only where the contents outgrow the screen, which takes an
        // accessibility text size: the sheet is otherwise exactly their height.
        ScrollView {
            VStack(spacing: 0) {
                header
                MapStylePicker(
                    tileProviderID: $tileProviderID,
                    selected: selectedProvider,
                    entitlement: entitlement,
                    locationManager: locationManager,
                    showPaywall: { showPaywall = true }
                )
                HikingRoutesPicker(showsHikingRoutes: $showsHikingRoutes)
                footer
            }
            .padding(.top, Self.topPadding)
            .padding(.bottom, Self.bottomPadding)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                contentHeight = height
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.height(contentHeight)])
        // A sheet stays a sheet in landscape, for the reason the place cards
        // give: over the whole map, it would hide the map being chosen.
        .presentationCompactAdaptation(.none)
        // And in a wide window it is a card as tall as its contents, where
        // the system's own form would leave most of itself empty.
        .presentationSizing(.form.fitted(horizontal: false, vertical: true))
        // Presented from inside this sheet, which is itself presented from
        // inside `MapSheet` — the repository's rule about where a modal has
        // to live applies at every level.
        .sheet(isPresented: $showPaywall) {
            MapPaywallView(store: entitlement)
        }
    }

    /// The title in the middle and the ✕ at the trailing edge, as Maps has
    /// them. The button is the place cards', which copy the same app.
    private var header: some View {
        // A row rather than an overlay on the title, so it is as tall as the
        // button and the ✕ stands inside the sheet's top edge. An unseen copy
        // of the button holds the leading side, so the title stays centered
        // and wraps between the two at the largest text sizes rather than
        // running under the ✕.
        HStack(alignment: .center, spacing: Self.headerSpacing) {
            closeButton
                .hidden()
                .accessibilityHidden(true)
            Text("Map Modes")
                .font(.headline)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("map-modes-title")
                .frame(maxWidth: .infinity)
            closeButton
                .accessibilityIdentifier("map-modes-close")
        }
        .padding(.horizontal, Self.horizontalMargin)
    }

    private var closeButton: some View {
        Button("Close", systemImage: "xmark", action: onClose)
            .glassButtonStyle()
            .placeCardControl()
    }

    /// What the glyphs on the cards mean, then the credits, last of all:
    /// where Maps puts its own.
    private var footer: some View {
        VStack(spacing: Self.noteSpacing) {
            if TileProvider.all.contains(where: { !Secrets.canLoadTiles($0) }) {
                // A sentence a hiker can act on, and — under `#if DEBUG` —
                // the one a contributor needs.
                Text("Maps marked \u{201C}Needs API key\u{201D} aren’t available in this build.")
                #if DEBUG
                // Verbatim: only a contributor reads it, so it is not for
                // translation, and Xcode's own catalog sync leaves
                // `#if DEBUG` code out and deleted the key on every build.
                Text(verbatim: "Adding one is a build-time step — see Secrets.example.plist in the project.")
                #endif
            }
            if !entitlement.isEntitled, TileProvider.all.contains(where: \.requiresPaidAccess) {
                Text("Maps with a lock need OpenHikes Pro.")
            }
            TileAttributionView(attribution: credits)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Self.horizontalMargin)
    }
}

#Preview("Map Modes") {
    MapModesView(
        entitlement: MapEntitlementStore(currentEntitlements: { false }),
        locationManager: LocationManager(),
        onClose: { /* a preview has nothing to close */ }
    )
}
