import SwiftUI

/// v1.2.1 fix 4: the back affordance in scope headers is a REAL button — a
/// 28x28pt hit target (was a bare ~13pt glyph) with a hover highlight — and
/// it exists exactly ONCE: every scoped screen renders this component
/// (directly or via ScopeHeader) instead of keeping five chevron copies.
///
/// Keyboard: Esc triggers it. Esc over Cmd+[ because the panel is a state
/// machine of full-screen scopes and Esc is the native "leave this scope"
/// key for panels/popovers; Cmd+[ is a browser/editor convention that also
/// collides with text-indent shortcuts while a field is focused.
///
/// The hover highlight is live-only by nature (snapshots never hover), so no
/// isSnapshotRender gate is needed: the idle state draws opacity 0.
struct BackButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.body.weight(.medium))
                .frame(width: 28, height: 28)
                .background(.white.opacity(hovered ? 0.08 : 0), in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .keyboardShortcut(.escape, modifiers: [])
        .help("Back (esc)")
    }
}

/// Shared header for scoped screens: BackButton + headline title + optional
/// secondary subtitle. ProjectScreen keeps its richer custom header (search
/// field, tab strip, actions) but embeds the same BackButton.
struct ScopeHeader: View {
    let title: String
    var subtitle: String? = nil
    /// CreateWorkspaceScreen disables back (and with it Esc) while a creation
    /// run is in flight — leaving mid-run would orphan the progress log.
    var backDisabled = false
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            BackButton(action: onBack)
                .disabled(backDisabled)
            Text(title)
                .font(.headline)
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
