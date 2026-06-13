import SwiftUI

/// Apple 26 corner system: one radius per chrome level, every corner drawn
/// with the continuous (squircle) style, and nesting kept CONCENTRIC — an
/// element inset by `d` inside a rounded parent wants radius `parent - d`,
/// never an ad-hoc literal. Corner-adjacent nested elements use
/// ConcentricRectangle (resolved against the `.containerShape` GlassCard
/// declares); `nested(parent:inset:)` supplies the floor for elements too far
/// from any container corner to resolve, and the radius for plain
/// RoundedRectangle fallbacks.
enum DesignRadius {
    // Standard, restrained corners. Earlier passes over-rounded the chrome
    // (26→16 still read too round and pushed text into the curve); these are
    // conventional macOS radii — a window-like panel, lightly rounded cards,
    // barely-rounded fields — keeping the concentric ordering panel > card > field.

    /// Full-screen panel states (the menu-bar panel content). 15% softer than the
    /// 10/6/5 baseline.
    static let panel: CGFloat = 11.5
    /// Cards/sections (GlassCard chrome).
    static let card: CGFloat = 6.9
    /// Text fields, picker chips, log wells.
    static let field: CGFloat = 5.75

    /// Concentric radius for an element inset inside a rounded parent,
    /// floored at 4 so tight insets never collapse to sharp corners (and stay
    /// below `card` so a nested element never out-rounds its parent).
    static func nested(parent: CGFloat, inset: CGFloat) -> CGFloat {
        max(4, parent - inset)
    }
}

/// Capsule chrome for selection chips (tab strips, view toggles, the graph
/// repo selector): REAL Liquid Glass live; a plain translucent fill in
/// snapshot mode, because ImageRenderer draws .glassEffect-modified views
/// fully invisible offscreen (the GlassCard landmine).
struct SelectionCapsule: ViewModifier {
    @Environment(\.isSnapshotRender) private var isSnapshotRender
    let isOn: Bool
    /// Faint fill kept under unselected chips (GraphScreen's repo selector
    /// shows every repo as a chip, so idle chips stay barely visible).
    var idleOpacity: Double = 0

    @ViewBuilder
    func body(content: Content) -> some View {
        if isSnapshotRender || !isOn {
            content.background(.white.opacity(isOn ? 0.18 : idleOpacity), in: .capsule)
        } else {
            content.glassEffect(.regular.tint(.white.opacity(0.14)), in: .capsule)
        }
    }
}

extension View {
    /// Selected state = glass capsule (translucent fill in snapshots);
    /// unselected = `idleOpacity` fill. Group sibling chips in a
    /// GlassEffectContainer so their glass renders (and morphs) together.
    func selectionCapsule(isOn: Bool, idleOpacity: Double = 0) -> some View {
        modifier(SelectionCapsule(isOn: isOn, idleOpacity: idleOpacity))
    }
}

/// Pill chrome for the header search field: real Liquid Glass live, the old
/// translucent fill in snapshots (same ImageRenderer invisibility landmine).
struct SearchFieldChrome: ViewModifier {
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    @ViewBuilder
    func body(content: Content) -> some View {
        if isSnapshotRender {
            content.background(.white.opacity(0.07), in: Capsule())
        } else {
            content.glassEffect(.regular, in: .capsule)
        }
    }
}
