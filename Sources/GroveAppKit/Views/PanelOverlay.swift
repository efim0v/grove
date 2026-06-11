import SwiftUI

/// In-panel replacement for `.sheet`. A real AppKit sheet is a SECOND key
/// window, and the MenuBarExtra(.window) panel auto-hides the moment it stops
/// being key — so with Settings open, any click inside the sheet dismissed the
/// whole panel. These modifiers render the "sheet" INSIDE the panel: a dimming
/// layer (tap closes) with the sheet view centered on top. No second window is
/// ever created.
///
/// The overlay never renders in snapshot scenes (SnapshotMode draws the sheet
/// views STANDALONE, and snapshot rendering dispatches no actions that could
/// present it), so it deliberately adds no ScrollView of its own; sheet
/// content keeps its existing \.isSnapshotRender-gated scrolling.
struct PanelOverlayModifier<Item: Identifiable, SheetContent: View>: ViewModifier {
    @Binding var item: Item?
    @ViewBuilder let sheetContent: (Item) -> SheetContent

    func body(content: Content) -> some View {
        content
            .overlay {
                if let presented = item {
                    ZStack {
                        Color.black.opacity(0.45)
                            .onTapGesture { item = nil }
                        sheetContent(presented)
                            .glassCard()
                            .frame(maxWidth: 520, maxHeight: 460)
                    }
                    .transition(AnyTransition.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .animation(.easeOut(duration: 0.15), value: item?.id)
    }
}

/// Adapter so the Bool variant reuses the item-based modifier: a stable id
/// keeps the show/hide animation value flipping nil <-> 0.
private struct PanelOverlayPresentedUnit: Identifiable {
    let id = 0
}

extension View {
    /// `.sheet(item:)` stand-in rendered inside the panel (see
    /// PanelOverlayModifier). Tapping the dimming layer sets `item` to nil.
    func panelOverlay<Item: Identifiable, C: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> C
    ) -> some View {
        modifier(PanelOverlayModifier(item: item, sheetContent: content))
    }

    /// `.sheet(isPresented:)` stand-in rendered inside the panel.
    func panelOverlay<C: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> C
    ) -> some View {
        panelOverlay(item: Binding<PanelOverlayPresentedUnit?>(
            get: { isPresented.wrappedValue ? PanelOverlayPresentedUnit() : nil },
            set: { isPresented.wrappedValue = $0 != nil }
        )) { _ in content() }
    }
}
