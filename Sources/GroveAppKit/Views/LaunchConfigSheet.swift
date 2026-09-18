import SwiftUI
import GroveCore

/// Configures a Resume/New launch before it runs: WHERE to open (cmux or
/// Terminal), the account, the model, and the effort — then launches. The two
/// always-present dropdowns are the account and the open-target.
struct LaunchConfigSheet: View {
    @ObservedObject var state: AppState
    @State var request: LaunchRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: request.isResume ? "play.circle.fill" : "plus.circle.fill")
                    .foregroundStyle(Palette.primary)
                Text(request.isResume ? "Resume session" : "New session")
                    .font(.headline)
            }
            Text(request.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)

            row("Open in") {
                Picker("", selection: $request.target) {
                    ForEach(LaunchTarget.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            row("Account") {
                Picker("", selection: $request.account) {
                    ForEach(state.config.accounts, id: \.name) { Text($0.name).tag($0.name) }
                }.pickerStyle(.menu).labelsHidden().fixedSize()
            }
            row("Model") {
                Picker("", selection: $request.model) {
                    Text("(default)").tag(String?.none)
                    ForEach(ModelCatalog.knownModels, id: \.self) { Text($0).tag(String?.some($0)) }
                }.pickerStyle(.menu).labelsHidden().fixedSize()
            }
            row("Effort") {
                Picker("", selection: $request.effort) {
                    Text("(default)").tag(String?.none)
                    ForEach(ClaudeService.effortLevels, id: \.self) { Text($0).tag(String?.some($0)) }
                }.pickerStyle(.menu).labelsHidden().fixedSize()
            }
            row("Skip permissions") {
                Toggle("", isOn: $request.skipPermissions)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .help("Launch with --dangerously-skip-permissions for this session")
            }

            HStack {
                Button("Cancel") { state.launchRequest = nil }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(request.isResume ? "Resume" : "Launch") {
                    Task { await state.confirmLaunch(request) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Palette.primary)
            }
        }
        .padding(18)
        .frame(width: 340)
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            control()
        }
    }
}
