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
    // v1.2.1 fix 3: the whole scale bumped to match macOS/iOS 26 (the old
    // 18/16/10 read as pre-26). The spec named card 22 / field 14 / floor 8;
    // panel follows to 26 so the concentric ordering (panel > card > field)
    // the system is built on keeps holding.

    /// Full-screen panel states (the menu-bar panel content).
    static let panel: CGFloat = 16
    /// Cards/sections (GlassCard chrome).
    static let card: CGFloat = 12
    /// Text fields, picker chips, log wells.
    static let field: CGFloat = 8

    /// Concentric radius for an element inset inside a rounded parent,
    /// floored at 8 so tight insets never collapse to sharp corners.
    static func nested(parent: CGFloat, inset: CGFloat) -> CGFloat {
        max(8, parent - inset)
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
