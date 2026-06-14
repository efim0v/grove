import SwiftUI
import GroveCore

/// Per-project accent color so projects (and their workspaces) are easy to tell
/// apart at a glance. Uses the project's explicit `accentColor` (hex) when set,
/// otherwise a STABLE default picked from a small Apple-system palette by the
/// project id (deterministic — the same project always gets the same hue).
enum ProjectAccent {
    /// The default palette new projects cycle through (kept legible on dark cards).
    static let palette: [Color] = [
        .green, .blue, .orange, .pink, .purple, .teal, .cyan, .indigo, .mint, .red,
    ]

    /// Hex strings matching `palette`, used when assigning a default to a new
    /// project so the choice persists in config (and the settings swatch matches).
    static let paletteHex: [String] = [
        "#34C759", "#0A84FF", "#FF9F0A", "#FF375F", "#BF5AF2",
        "#40C8E0", "#64D2FF", "#5E5CE6", "#66D4CF", "#FF453A",
    ]

    static func color(for project: ProjectConfig) -> Color {
        if let hex = project.accentColor, let c = Color(hex: hex) { return c }
        return palette[defaultIndex(project.id)]
    }

    /// A stable hex default for a freshly-added project (so it's persisted).
    static func defaultHex(for id: UUID) -> String {
        paletteHex[defaultIndex(id)]
    }

    /// Deterministic palette index from the UUID bytes (NOT hashValue, which is
    /// randomized per process).
    static func defaultIndex(_ id: UUID) -> Int {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        return bytes.reduce(0) { $0 + Int($1) } % palette.count
    }
}

extension Color {
    /// Parses "#RRGGBB" / "RRGGBB" (and "#RGB"). nil on malformed input.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}
