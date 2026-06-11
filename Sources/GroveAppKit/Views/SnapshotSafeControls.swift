import SwiftUI

/// TextField stand-in for snapshot rendering. EMPIRICAL (this machine,
/// macOS 26.4): AppKit-backed controls — NSTextField, Picker(.menu/.segmented),
/// Toggle(.checkbox), Stepper — draw as yellow/crossed error placeholders
/// under ImageRenderer. Snapshot-asserted screens therefore route text input
/// through this wrapper: a real TextField live, a static lookalike (showing
/// the bound text or the placeholder) in snapshots.
struct SnapshotSafeTextField: View {
    @Environment(\.isSnapshotRender) private var isSnapshotRender
    let title: String
    @Binding var text: String
    var monospaced: Bool = false

    var body: some View {
        if isSnapshotRender {
            Text(text.isEmpty ? title : text)
                .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
                .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: DesignRadius.field, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DesignRadius.field, style: .continuous)
                    .strokeBorder(.white.opacity(0.2)))
        } else {
            TextField(title, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
        }
    }
}

/// Static menu-Picker lookalike for snapshot rendering: Picker(.menu) is
/// AppKit-backed and draws as a yellow error placeholder under ImageRenderer,
/// so snapshot-asserted screens show this chip (current value + up/down
/// chevron) instead. LIVE screens never use it — they render real Pickers.
struct SnapshotPickerLookalike: View {
    let text: String
    var monospaced: Bool = true

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        // Capsule, not RoundedRectangle: it stands in for a Picker(.menu)
        // button, and macOS 26 menu buttons are pills.
        .background(.white.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.2)))
    }
}

/// Pure-SwiftUI stepper (NSStepper renders as an error placeholder offscreen).
struct SnapshotSafeStepper: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.callout)
            Button {
                if value > range.lowerBound { value -= 1 }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .disabled(value <= range.lowerBound)
            Text("\(value)")
                .font(.callout.monospacedDigit())
                .frame(width: 22)
            Button {
                if value < range.upperBound { value += 1 }
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.plain)
            .disabled(value >= range.upperBound)
        }
    }
}
