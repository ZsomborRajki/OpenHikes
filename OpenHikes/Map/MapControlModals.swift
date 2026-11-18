//
//  MapControlModals.swift
//  OpenHikes
//
//  What the map's own controls open, and which sheet puts each of them up.
//
//  Three things: *Map Modes* from the pill's upper half, the refused "my
//  location" button's alert from its lower half, and the forecast from the
//  weather badge. Each is raised on the map and presented from inside the map
//  sheet's contents, for the reason ``MapScreenAlerts`` gives: a modal
//  attached beside a sheet that is never dismissed is never presented.
//
//  A place card breaks that. *Places Around Trail*'s card and the trail
//  maker's leave the map live behind them, the pill and the badge included,
//  and the map sheet's contents are what present the card. So they are
//  already presenting something when one of those controls is tapped.
//  Measured on `--ui-testing` launches (#1403):
//
//  - A sheet asked for from under the card — the forecast, and *Map Modes*
//    before it went through here — waited, and came up when the card was
//    closed, over a map the hiker had moved on from.
//  - The alert came up at once, and took the card down with it.
//
//  So a card says when it is up, and while it is, it presents all three over
//  itself. The counter lives here rather than on any one of them so that a
//  fourth thing a map control opens has one place to join.
//
//  One thing has joined that no control opens: the question a walk asks once
//  its hiker has left the trail (``OffTrailQuestion``). A fix raises it, at
//  any moment, a card's included, so it is put up by whichever of the two is
//  in front, for the reason the alert above is.
//

import SwiftUI

/// What the map's own controls open, and which sheet puts each up.
///
/// A reference type the root view holds and both sides reach, as each of the
/// three was before they were gathered here: the map raises them, and the
/// sheets present them. The three never change, so reading one off this
/// object is no dependency of the body that does.
@Observable
final class MapControlModals {
    /// A sheet that can present what a map control opens.
    enum Presenter {
        /// The map sheet's contents, where nothing else is over the map.
        case mapSheet
        /// A place card that leaves the map live behind it.
        case card
    }

    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// *Map Modes*, from the pill's upper half.
    let mapModes = MapModesPresentation()
    /// Why the map cannot show where the hiker is, from the pill's lower half
    /// once location has been refused.
    let locationAccess = LocationAccessPrompt()
    /// The forecast, from the weather badge.
    let weatherDetail = WeatherDetailPresentation()

    /// How many place cards are up over the map sheet: one or none.
    private(set) var cardsInFront = 0

    func cardDidAppear() {
        cardsInFront += 1
    }

    /// Never below none, so a card that says it went twice cannot leave the
    /// next card uncounted, and the map sheet presenting from under it.
    func cardDidDisappear() {
        cardsInFront = max(0, cardsInFront - 1)
    }

    /// Whether `presenter` is the one to put up what a map control opens:
    /// the card while there is one, and the map sheet otherwise.
    func isPresenter(_ presenter: Presenter) -> Bool {
        switch presenter {
        case .mapSheet: cardsInFront == 0
        case .card: true
        }
    }

    /// Drives one of them from `presenter`: up while it is raised and
    /// `presenter` is the one to put it up. Closing it, from either, lowers
    /// the one flag.
    ///
    /// Building it reads the flag and the counter — `Binding(get:set:)`
    /// calls its getter as it is made — so the modifier that builds it in its
    /// body is their reader, and nothing above it. See *Render isolation, in
    /// practice* in the repository instructions.
    func binding(_ isRaised: Binding<Bool>, for presenter: Presenter) -> Binding<Bool> {
        Binding(
            get: { isRaised.wrappedValue && self.isPresenter(presenter) },
            set: { if !$0 { isRaised.wrappedValue = false } }
        )
    }
}

extension View {
    /// Attaches what the map's controls open to the view it can be presented
    /// from — the map sheet's contents — and hands it to the place cards
    /// presented from inside them.
    func mapControlModals(_ modals: MapControlModals, model: OpenHikesModel) -> some View {
        presentingMapControls(modals, from: .mapSheet, model: model)
            .environment(modals)
    }

    /// For a place card that leaves the map live behind it: presents what
    /// the map's controls open over the card while the card is up — see
    /// ``MapControlModals``.
    func presentsMapControlsOverCard() -> some View {
        modifier(MapControlsOverCard())
    }
}

private extension View {
    /// The three, attached to `presenter`, and the walk's off-trail question
    /// with them.
    func presentingMapControls(
        _ modals: MapControlModals,
        from presenter: MapControlModals.Presenter,
        model: OpenHikesModel
    ) -> some View {
        weatherDetailSheet(modals, from: presenter, weather: model.weatherManager)
            .mapModesSheet(
                modals,
                from: presenter,
                entitlement: model.entitlement,
                locationManager: model.locationManager,
                offlineCountries: model.offlineCountries
            )
            .locationAccessAlert(modals, from: presenter)
            .offTrailQuestionAlert(modals, from: presenter, model: model)
    }
}

/// Reads the modals and the model from the environment, so a card is handed
/// neither. Both are absent in a preview, which then presents nothing.
private struct MapControlsOverCard: ViewModifier {
    @Environment(MapControlModals.self) private var modals: MapControlModals?
    @Environment(OpenHikesModel.self) private var appModel: OpenHikesModel?

    func body(content: Content) -> some View {
        if let modals, let appModel {
            content
                .onAppear(perform: modals.cardDidAppear)
                .onDisappear(perform: modals.cardDidDisappear)
                .presentingMapControls(modals, from: .card, model: appModel)
        } else {
            content
        }
    }
}
