import SwiftUI

/// Reads search-only state below the map sheet's render boundary.
struct MapSearchControls: View {
    let session: MapSearchSession
    let community: CommunityBrowser
    let onScopeChange: (MapSearchScope) -> Void
    let onAreaChoice: (CommunityAreaChoice) -> Void
    let onChoosePlace: () -> Void

    private var availableScopes: [MapSearchScope] {
        MapSearchScope.displayOrder.filter { $0 != .community || community.hasTransport }
    }

    var body: some View {
        RenderSignpost.mark("MapSearchControlsBody")
        return VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(availableScopes) { scope in
                        Button { onScopeChange(scope) } label: {
                            Text(scope.title)
                                .font(.subheadline)
                                .fixedSize()
                                .minimumTapTarget()
                        }
                        .buttonStyle(.bordered)
                        .tint(session.scope == scope ? .accentColor : .secondary)
                        .accessibilityAddTraits(session.scope == scope ? [.isSelected] : [])
                        .accessibilityIdentifier("search-scope-\(scope.rawValue)")
                    }
                }
            }
            if session.scope == .community {
                ViewThatFits(in: .horizontal) {
                    HStack { areaMenu; refreshButton }
                    VStack(alignment: .leading) { areaMenu; refreshButton }
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var areaMenu: some View {
        Menu {
            Button("This map", systemImage: "map") { onAreaChoice(.map) }
            Button("Near me", systemImage: "location") { onAreaChoice(.nearMe) }
            Button("Choose a place…", systemImage: "mappin.and.ellipse", action: onChoosePlace)
            Button("Anywhere", systemImage: "globe") { onAreaChoice(.anywhere) }
        } label: {
            Label("Area: \(community.areaChoice.title)", systemImage: "mappin.and.ellipse")
                .font(.subheadline)
                .minimumTapTarget()
        }
        .accessibilityIdentifier("community-search-area")
    }

    @ViewBuilder private var refreshButton: some View {
        if community.canSearchThisArea {
            Button("Search this area") { onAreaChoice(.map) }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("community-search-this-area")
        }
    }
}
