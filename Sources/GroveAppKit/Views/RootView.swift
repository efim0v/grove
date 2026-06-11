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
    @StateObject private var panelWindow = PanelWindowBridge()
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    public init(state: AppState) {
        _state = ObservedObject(wrappedValue: state)
    }

    /// The panel silhouette: Apple 26 large continuous corners.
    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignRadius.panel, style: .continuous)
    }

    public var body: some View {
        VStack(spacing: 0) {
            errorBanner
            routedScreen
        }
        // The hosting NSPanel is made CLEAR (PanelWindowAccessor below), so
        // this is the panel's ONLY glass — no system chrome to stack against.
        // The dark scrim over it implements "darkened screens inside a glass
        // window" (spec §6); both live inside the same continuous-corner clip
        // so the window silhouette gets the macOS 26 large radius. In snapshot
        // mode the scrim alone keeps PNGs non-blank (.glassEffect renders
        // invisible offscreen).
        .background(.black.opacity(0.35), in: panelShape)
        .modifier(PanelGlass(shape: panelShape, isSnapshotRender: isSnapshotRender))
        .clipShape(panelShape)
        .containerShape(.rect(cornerRadius: DesignRadius.panel, style: .continuous))
        .background(panelWindowHook)
        .onChange(of: state.route) {
            // The panel resizes per route; with a clear window the system
            // shadow only follows the opaque content after an explicit
            // invalidate. Once now, once after the slide/resize settles.
            panelWindow.window?.invalidateShadow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak panelWindow] in
                panelWindow?.window?.invalidateShadow()
            }
        }
        .task {
            // Refresh now, then every 15 s while the panel stays open. The
            // task is cancelled on disappear (panel closed), pausing the loop.
            guard !isSnapshotRender else { return }
            await state.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled { break }
                await state.refresh()
            }
        }
    }

    /// AppKit hook that clears the hosting panel (so our chrome above is the
    /// visible window) and fills `panelWindow`. Never attached during
    /// snapshot renders: ImageRenderer has no window and AppKit-backed views
    /// are placeholder landmines offscreen.
    @ViewBuilder private var panelWindowHook: some View {
        if !isSnapshotRender {
            PanelWindowAccessor(bridge: panelWindow)
        }
    }

    // MARK: - Route switch with push/pop transitions and per-route size

    /// Preferred panel frame per route; nil height = adaptive (the screen
    /// sizes to its content, capped at 560 in routedScreen).
    static func panelSize(for route: Route) -> (width: CGFloat, height: CGFloat?) {
        switch route {
        case .projects: return (420, 440)
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
        let size = Self.panelSize(for: state.route)
        ZStack(alignment: .top) {
            Group {
                switch state.route {
                case .projects:
                    ProjectsScreen(state: state)
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
            .frame(maxHeight: 560)   // caps the height-adaptive createWorkspace
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

    @ViewBuilder private var errorBanner: some View {
        if let error = state.actionError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.caption)
                    .lineLimit(2)
                    .help(error)
                Spacer()
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
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            // Pin to the route's width: an unconstrained Text would otherwise
            // balloon the content-sized panel to the error's full line width.
            .frame(width: Self.panelSize(for: state.route).width)
            .background(.orange.opacity(0.15))
            Divider()
        }
    }
}

/// Liquid Glass for the panel itself — live only. ImageRenderer draws
/// .glassEffect-modified views fully INVISIBLE offscreen (the GlassCard
/// landmine), so snapshot renders skip the modifier entirely and rely on the
/// dark scrim already applied inside the same panel shape.
private struct PanelGlass: ViewModifier {
    let shape: RoundedRectangle
    let isSnapshotRender: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isSnapshotRender {
            content
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}
