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
        // One brand accent for every system-styled control (default-action
        // buttons, links, toggles) so they pick up Palette.primary instead of
        // the OS accent — the single source of truth for the app's blue.
        .tint(Palette.primary)
        // The window backdrop (the shared glass substrate) is supplied ONCE at the
        // merged panel level, identically across the projects and charts sections.
        // Here we only declare the container shape for concentric nesting underneath.
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
        // Resume/New launch configuration (open-target, account, model, effort).
        .sheet(item: $state.launchRequest) { LaunchConfigSheet(state: state, request: $0) }
    }

    // MARK: - Route switch with push/pop transitions and per-route size

    /// Preferred panel frame for the CURRENT route. The root scope (.projects) is
    /// the project list at a roomy size (its height is a *minimum* — it stretches to
    /// fill the taller merged window; see RouteFrame); the usage dashboard is no
    /// longer a tab here (it's the embedded charts section of the merged window).
    var currentPanelSize: (width: CGFloat, height: CGFloat?) {
        if case .projects = state.route {
            return (460, 520)
        }
        return Self.panelSize(for: state.route)
    }

    /// Height cap for the adaptive-height screens.
    private var maxPanelHeight: CGFloat { 560 }

    /// Preferred panel frame per route; nil height = adaptive (the screen
    /// sizes to its content, capped at 560 in routedScreen).
    static func panelSize(for route: Route) -> (width: CGFloat, height: CGFloat?) {
        switch route {
        case .projects: return (460, 520)
        case .project: return (760, 540)
        case .createWorkspace: return (540, nil)
        case .projectSettings: return (560, 560)
        case .statsSettings: return (560, 560)
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
                case .statsSettings(let id):
                    StatsSettingsScreen(state: state, projectID: id)
                case .accounts:
                    AccountsScreen(state: state)
                case .globalSettings:
                    GlobalSettingsScreen(state: state)
                }
            }
            .modifier(RouteFrame(route: state.route, size: size, cap: maxPanelHeight))
            .transition(.opacity)
        }
        .clipped()
    }

    /// Per-route frame. Every route except `.projects` keeps the exact prior
    /// behavior (a fixed/adaptive height capped at `cap`). The `.projects` route
    /// instead takes its height as a *minimum* with an unbounded max, so the
    /// projects column can stretch DOWN to match the taller charts column when
    /// embedded in `MergedRootView` (footer pinned to the bottom edge) while still
    /// resolving to its natural 520 standalone or when the charts are collapsed.
    /// The on-screen height is clamped by the controller's `applyContentSize`.
    private struct RouteFrame: ViewModifier {
        let route: Route
        let size: (width: CGFloat, height: CGFloat?)
        let cap: CGFloat

        func body(content: Content) -> some View {
            if case .projects = route {
                content
                    .frame(width: size.width)
                    .frame(minHeight: size.height ?? 0, maxHeight: .infinity,
                           alignment: .top)
            } else {
                content
                    .frame(width: size.width, height: size.height)
                    .frame(maxHeight: cap)   // caps the height-adaptive screens
            }
        }
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
                    .foregroundStyle(Palette.negative)
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
