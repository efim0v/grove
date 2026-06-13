import SwiftUI
import GroveCore

/// Panel root: a state machine of full-screen views switched over
/// AppState.route (spec: one scope per screen, NEVER overlays). Transitions
/// slide forward (push) or backward (pop) based on the direction recorded by
/// open()/goBack(); the panel frame adapts per route and animates together
/// with the slide. The error banner (spec §7, with the "Launch cmux"
/// affordance) sits above whatever screen is active. A 15-second refresh loop
/// runs while the panel content is visible (.task is cancelled when the
/// MenuBarExtra window closes).
public struct RootView: View {
    @ObservedObject private var state: AppState
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    public init(state: AppState) {
        _state = ObservedObject(wrappedValue: state)
    }

    public var body: some View {
        VStack(spacing: 0) {
            errorBanner
            routedScreen
        }
        // The MenuBarExtra(.window) panel ALREADY wraps this content in the
        // system's Liquid Glass chrome; the dark scrim implements "darkened
        // screens inside a glass window". A root-level .glassEffect here would
        // stack glass on glass and turn muddy, so the panel keeps the system
        // material and only declares the Apple 26 container shape for
        // concentric nesting underneath.
        .background(.black.opacity(0.35))
        .containerShape(.rect(cornerRadius: DesignRadius.panel, style: .continuous))
        // Keyed on isPanelOpen: the panel hides via orderOut (which does NOT
        // cancel a plain .task), so the loop must stop itself when the panel
        // closes. In a headless render/test isPanelOpen is false, so the loop
        // never starts — no runaway refresh against the real ~/.claude.
        .task(id: state.isPanelOpen) {
            guard !isSnapshotRender, state.isPanelOpen else { return }
            await state.refresh()
            while !Task.isCancelled && state.isPanelOpen {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled || !state.isPanelOpen { break }
                await state.refresh()
            }
        }
    }

    // MARK: - Route switch with push/pop transitions and per-route size

    /// Preferred panel frame for the CURRENT route. The root scope (.projects)
    /// is a two-tab shell whose width depends on the active tab — the Charts tab
    /// is wider so account columns sit side by side.
    var currentPanelSize: (width: CGFloat, height: CGFloat?) {
        if case .projects = state.route {
            // Charts is a single ~320 column; height is adaptive so the whole
            // column fits without scrolling (the panel grows to it).
            return state.rootTab == .charts ? (344, nil) : (460, 520)
        }
        return Self.panelSize(for: state.route)
    }

    /// Height cap for the adaptive-height screens. The charts column needs more
    /// room than the default 560 so all cards fit without a scroll view.
    private var maxPanelHeight: CGFloat {
        if case .projects = state.route, state.rootTab == .charts { return 820 }
        return 560
    }

    /// Preferred panel frame per route; nil height = adaptive (the screen
    /// sizes to its content, capped at 560 in routedScreen).
    static func panelSize(for route: Route) -> (width: CGFloat, height: CGFloat?) {
        switch route {
        case .projects: return (460, 520)
        case .project: return (760, 540)
        case .createWorkspace: return (540, nil)
        case .projectSettings: return (560, 560)
        case .accounts: return (560, 480)
        case .globalSettings: return (480, 420)
        }
    }

    /// The frame/transition pair attaches to the ACTIVE branch (Group
    /// distributes modifiers), so during a transition the outgoing screen
    /// keeps ITS size while the incoming one brings the new size — the
    /// ZStack (and the MenuBarExtra window with it) animates between the two
    /// inside open()'s withAnimation.
    @ViewBuilder private var routedScreen: some View {
        let size = currentPanelSize
        ZStack(alignment: .top) {
            Group {
                switch state.route {
                case .projects:
                    RootShell(state: state)
                case .project:
                    ProjectScreen(state: state)
                case .createWorkspace:
                    CreateWorkspaceScreen(state: state,
                                          prefill: state.createPrefill ?? CreatePrefill(),
                                          onClose: { state.goBack() })
                case .projectSettings(let id):
                    ProjectSettingsScreen(state: state, projectID: id)
                case .accounts:
                    AccountsScreen(state: state)
                case .globalSettings:
                    GlobalSettingsScreen(state: state)
                }
            }
            .frame(width: size.width, height: size.height)
            .frame(maxHeight: maxPanelHeight)   // caps the height-adaptive screens
            .transition(navTransition)
        }
        // Slide transitions would otherwise draw outside the panel frame.
        .clipped()
    }

    /// Push: new screen slides in from the trailing edge while the old one
    /// leaves through the leading edge; pop mirrors it. Both combine with
    /// opacity so the move never looks like a hard wipe.
    private var navTransition: AnyTransition {
        state.routeIsForward
            ? .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                          removal: .move(edge: .leading).combined(with: .opacity))
            : .asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                          removal: .move(edge: .trailing).combined(with: .opacity))
    }

    // MARK: - Error banner (spec §7): dismissable; cmux failures get a
    // "Launch cmux" degraded-mode affordance.

    /// Modest system-like banner: an inset strip on standard material with a
    /// small continuous radius (DesignRadius.field) so it reads as content,
    /// not as a second window corner fighting the panel's own chrome.
    @ViewBuilder private var errorBanner: some View {
        if let error = state.actionError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.caption)
                    .lineLimit(2)
                    .help(error)
                Spacer(minLength: 0)
                if error.localizedCaseInsensitiveContains("cmux") {
                    Button("Launch cmux") {
                        Task { await state.launchCmuxApp() }
                    }
                    .controlSize(.small)
                }
                Button {
                    state.actionError = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial,
                        in: RoundedRectangle(cornerRadius: DesignRadius.field,
                                             style: .continuous))
            .padding(.horizontal, 10)
            .padding(.top, 10)
            // Pin to the route's width: an unconstrained Text would otherwise
            // balloon the content-sized panel to the error's full line width.
            .frame(width: currentPanelSize.width)
        }
    }
}
