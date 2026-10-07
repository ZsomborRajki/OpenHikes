//
//  WalkShareEditor.swift
//  OpenHikes
//
//  The share card, full screen, with the two boxes free to move.
//
//  The photograph fills the screen and the card is the screen's shape, so
//  what the hiker arranges is exactly the picture that is sent — the export
//  draws this same canvas at this same size, only with more pixels. There is
//  no settings screen: what a box can change is on a small bar that appears
//  when that box is tapped, and goes when the photograph is.
//

import SwiftUI

struct WalkShareEditor: View {
    let model: WalkShareEditorModel

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            WalkShareCanvas(size: size) {
                WalkShareEditablePhoto(model: model, size: size)
            } box: { widget in
                WalkShareEditableBox(widget: widget, model: model, size: size)
            }
            .onChange(of: size, initial: true) { _, size in model.setCanvasSize(size) }
        }
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            WalkShareBoxControls(model: model)
        }
        .background(.black)
        .navigationTitle("Share Hike")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                WalkShareButton(model: model)
            }
        }
    }
}

/// The share item, in a view of its own so a settled layout rebuilds this
/// button and not the editor around it.
private struct WalkShareButton: View {
    let model: WalkShareEditorModel

    var body: some View {
        ShareLink(
            item: model.shareImage,
            preview: SharePreview(
                model.card.figures.title,
                icon: Image(systemName: "photo")
            )
        ) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .accessibilityLabel("Share hike card")
        .disabled(model.canvasSize == .zero)
        .accessibilityIdentifier("walk-share-send")
    }
}

/// What the selected box can change, on a bar along the bottom of the screen.
private struct WalkShareBoxControls: View {
    let model: WalkShareEditorModel

    var body: some View {
        if let widget = model.selection {
            HStack(spacing: 12) {
                stylePicker(for: widget)
                switch widget {
                case .stats: figuresMenu
                case .route: colorPicker
                }
            }
            .padding(10)
            .glassSurface(.regular, in: .capsule)
            .padding(.horizontal)
            // Clear of the wordmark, which the hiker should still see.
            .padding(.bottom, 32)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityIdentifier("walk-share-controls")
        }
    }

    private func stylePicker(for widget: WalkShareWidget) -> some View {
        let style = widget == .stats ? model.layout.statsStyle : model.layout.routeStyle
        return Picker("Style", selection: Binding(get: { style }, set: { model.setStyle($0, of: widget) })) {
            Text("Card").tag(WalkShareBoxStyle.card)
            Text(widget == .stats ? "Text" : "Line").tag(WalkShareBoxStyle.bare)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .accessibilityIdentifier("walk-share-style")
    }

    private var colorPicker: some View {
        Picker(
            "Line Color",
            selection: Binding(get: { model.layout.lineColor }, set: { model.setLineColor($0) })
        ) {
            Text("White").tag(WalkShareLineColor.white)
            Text("Trail").tag(WalkShareLineColor.trail)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .accessibilityIdentifier("walk-share-line-color")
    }

    /// Which figures the box prints. At the limit the ones not shown are
    /// disabled, and the last one shown cannot be switched off, which is the
    /// rule ``WalkShareLayout/toggling(_:)`` keeps whatever the menu does.
    private var figuresMenu: some View {
        let shown = model.layout.shownStats
        return Menu {
            ForEach(WalkShareStat.menuOrder, id: \.self) { stat in
                let isOn = shown.contains(stat)
                Toggle(
                    stat.label,
                    systemImage: stat.symbol,
                    isOn: Binding(get: { isOn }, set: { _ in model.toggle(stat) })
                )
                .disabled(isOn ? shown.count == 1 : shown.count >= WalkShareStat.maximumShown)
            }
        } label: {
            Label("Figures", systemImage: "list.bullet")
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 6)
        }
        .menuActionDismissBehavior(.disabled)
        .accessibilityIdentifier("walk-share-figures")
    }
}
