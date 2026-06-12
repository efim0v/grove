import SwiftUI
import GroveCore

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
    /// Global remaining-capacity badge for the 5h window. nil = don't show a badge.
    /// Typed (not AnyView): the header owns the chip rendering + color grade.
    var aggregate: RateLimitModel.Aggregate? = nil
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
            if let aggregate {
                AggregateChip(window: "5h", aggregate: aggregate)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Global remaining-capacity chip: "5h 60%" color-graded by AggregateBadge.level.
/// FIX I4: when there are ZERO usage captures the aggregate has total == 0; render
/// a NEUTRAL gray "no data" chip ("5h —"), NOT a red .critical chip, so existing
/// snapshot scenes (no fixture captures) don't all turn red.
/// Internal (not private) so ProjectScreen's CUSTOM header — which doesn't use
/// ScopeHeader — can render the same chip directly in its HStack.
struct AggregateChip: View {
    let window: String
    let aggregate: RateLimitModel.Aggregate
    var body: some View {
        let badge = AggregateBadge(aggregate)   // .noData when aggregate.total == 0
        let color: Color = {
            switch badge.level {
            case .noData:   return .gray
            case .plenty:   return .green
            case .tight:    return .orange
            case .critical: return .red
            }
        }()
        let label = badge.hasData ? "\(Int((aggregate.fraction * 100).rounded()))%" : "—"
        return Text("\(window) \(label)")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
            .help(badge.hasData ? "Remaining 5h capacity across accounts"
                                : "No usage captures yet — enable Monitoring")
    }
}
