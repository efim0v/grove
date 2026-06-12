import SwiftUI

/// A labeled settings group: a header (+ optional subtitle) over a glass card.
/// Use one per logical section so the screens read as discrete blocks.
struct SettingsSection<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.tertiary)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .glassCard()
    }
}

/// A settings row with a fixed-width label column so controls align across
/// rows and sections. Generalizes the ad-hoc 130pt row in ProjectSettingsScreen.
struct LabeledRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.callout)
                .frame(width: 150, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}
