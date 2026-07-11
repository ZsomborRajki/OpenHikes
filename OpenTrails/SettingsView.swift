//
//  SettingsView.swift
//  OpenTrails
//
//  The profile/settings sheet reached from the button next to the search bar.
//  Hosts a (future) Apple sign-in and the map tile-provider selector.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(SettingsKey.tileProviderID) private var tileProviderID = TileProvider.default.id

    private var selectedProvider: TileProvider {
        TileProvider.provider(id: tileProviderID)
    }

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                mapProviderSection
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not signed in")
                        .font(.headline)
                    Text("Sign in to sync your hikes across devices.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

            appleSignInPlaceholder
        } header: {
            Text("Account")
        }
    }

    /// A disabled preview of Sign in with Apple — wired up in a future release.
    private var appleSignInPlaceholder: some View {
        HStack {
            Label("Sign in with Apple", systemImage: "apple.logo")
                .font(.body.weight(.medium))
            Spacer()
            Text("Coming soon")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
        }
        .foregroundStyle(.primary)
        .opacity(0.55)
        .allowsHitTesting(false)
    }

    // MARK: - Map tiles

    private var mapProviderSection: some View {
        Section {
            ForEach(TileProvider.all) { provider in
                providerRow(provider)
            }
        } header: {
            Text("Map Tiles")
        } footer: {
            Text(selectedProvider.attribution)
        }
    }

    private func providerRow(_ provider: TileProvider) -> some View {
        let isSelected = provider.id == tileProviderID
        return Button {
            tileProviderID = provider.id
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(provider.name)
                            .font(.body.weight(.medium))
                        if provider.supportsBulkDownload {
                            Text("Offline")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.green.opacity(0.18), in: Capsule())
                        }
                    }
                    Text(provider.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

#Preview {
    SettingsView()
}
