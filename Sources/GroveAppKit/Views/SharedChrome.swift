import SwiftUI

/// Chrome shared by the kept screens (Stats, Stats settings, session cards).
/// Lived in the usage dashboard until the limits/usage panel left for Brow.
let cardAccent = Palette.primary

struct CardLabel: View {
    let title: String
    let systemImage: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).foregroundStyle(cardAccent)
            Text(title).foregroundStyle(.primary)
        }
        .font(.caption.weight(.semibold))
    }
}

/// `claude-opus-4-8` → `opus-4-8`, for the session meta line.
func shortModelName(_ id: String) -> String {
    id.hasPrefix("claude-") ? String(id.dropFirst("claude-".count)) : id
}
