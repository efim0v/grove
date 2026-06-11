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
public struct GlassCard: ViewModifier {
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    public init() {}

    @ViewBuilder
    public func body(content: Content) -> some View {
        if isSnapshotRender {
            content
                .background(.white.opacity(0.06), in: .rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.15)))
        } else {
            content
                .background(.black.opacity(0.28), in: .rect(cornerRadius: 12))
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
        }
    }
}

extension View {
    public func glassCard() -> some View {
        modifier(GlassCard())
    }
}
