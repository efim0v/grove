import SwiftUI
import AppKit

/// The app's accent palette — ONE source of truth for every accent / status /
/// capacity color. Semantics:
/// - `primary` (blue): the MAIN accent. Buttons, card icons, all charts' main
///   color, growth / additions, "on track" / plenty capacity, the running status.
/// - `negative` (pink): the antonym to growth — deletions, decline, critical /
///   near-limit capacity.
/// - `mid` (yellow): the waiting session status and tight / mid capacity.
/// - `neutral` (gray): no-data / closed / idle.
///
/// Hex values are parsed via `Color(hex:)` (ProjectAccent.swift) so the palette
/// stays declared with its source-of-truth hex strings.
enum Palette {
    static let primary = Color(hex: "#3478F6")!   // blue 52,120,246
    static let negative = Color(hex: "#E45C9C")!  // pink 228,92,156
    static let mid = Color(hex: "#F6C844")!       // yellow 246,200,68
    static let neutral = Color.gray               // no-data / closed

    /// A continuous "heat" ramp across the brand palette for activity/intensity
    /// (0…1): calm = blue (primary), mid = yellow, hot = pink (negative). Derived
    /// from the palette colors themselves (no hardcoded channels) so charts pick up
    /// any future palette change. Used by the multi-colour daily-usage bars.
    static func heat(_ t: Double) -> Color {
        let u = min(max(t, 0), 1)
        return u < 0.5 ? primary.blended(to: mid, u / 0.5)
                       : mid.blended(to: negative, (u - 0.5) / 0.5)
    }
}

extension Color {
    /// Linear RGB interpolation toward `other` by `t` (0…1), via sRGB components.
    /// Lets brand ramps be built FROM the Palette instead of copying its channels,
    /// keeping one source of truth (memory: prefer robust over copy-and-sync).
    func blended(to other: Color, _ t: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let b = NSColor(other).usingColorSpace(.sRGB) ?? NSColor(other)
        let u = CGFloat(min(max(t, 0), 1))
        return Color(.sRGB,
                     red:   Double(a.redComponent   + (b.redComponent   - a.redComponent)   * u),
                     green: Double(a.greenComponent + (b.greenComponent - a.greenComponent) * u),
                     blue:  Double(a.blueComponent  + (b.blueComponent  - a.blueComponent)  * u),
                     opacity: Double(a.alphaComponent + (b.alphaComponent - a.alphaComponent) * u))
    }
}

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

    /// Full-screen panel/window corners (continuous "squircle"). The window is a
    /// transparent Liquid Glass surface, so it carries a generous Apple-26 radius.
    static let panel: CGFloat = 17
    /// Cards/sections (GlassCard chrome) — the gray content substrates. ~20%
    /// rounder than the previous 10.5 for a more pronounced iOS-26 squircle.
    static let card: CGFloat = 12.6
    /// Text fields, picker chips, log wells.
    static let field: CGFloat = 10.2

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
