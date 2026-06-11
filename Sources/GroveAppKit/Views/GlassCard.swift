import SwiftUI

/// True while SnapshotMode renders offscreen. ImageRenderer draws views
/// modified by .glassEffect as fully INVISIBLE (not merely flat), so glass
/// chrome must swap to a plain translucent card during snapshot rendering.
private struct SnapshotRenderKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isSnapshotRender: Bool {
        get { self[SnapshotRenderKey.self] }
        set { self[SnapshotRenderKey.self] = newValue }
    }
}

/// Card chrome used across the app: Liquid Glass over a dark translucent fill
/// ("darkened screens inside a glass window", spec §6). The dark fill sits
/// closest to the content; .glassEffect supplies the glass material behind it.
/// In snapshot mode the glass is replaced by a hairline border so the card —
/// and everything inside it — stays visible to the agent reading the PNG.
/// Corners follow the Apple 26 system (DesignRadius.card, continuous), and the
/// card declares itself as the container shape so nested ConcentricRectangle
/// elements (repo chips etc.) resolve concentric radii against it.
public struct GlassCard: ViewModifier {
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    public init() {}

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignRadius.card, style: .continuous)
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        if isSnapshotRender {
            content
                .background(.white.opacity(0.06), in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.15)))
                .containerShape(shape)
        } else {
            content
                .background(.black.opacity(0.28), in: shape)
                .glassEffect(.regular, in: shape)
                .containerShape(shape)
        }
    }
}

extension View {
    public func glassCard() -> some View {
        modifier(GlassCard())
    }
}
