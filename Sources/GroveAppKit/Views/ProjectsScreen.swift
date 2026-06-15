import SwiftUI
import AppKit
import GroveCore

/// The Projects tab (item 4 — the primary view): an Apple-26 grouped list. Each
/// project is a section — an H4 name header (+ its repos/ws counts) LIFTED OUT
/// onto the plain background, ABOVE a separate gray .glassCard() that carries the
/// 2 most recent Claude sessions as tappable blocks for instant terminal access
/// (items 4/7/24). An "Open project" chevron at the END of each section drills
/// into the project's full workspace scope.
struct ProjectsTab: View {
    @ObservedObject var state: AppState
    @Environment(\.isSnapshotRender) private var isSnapshotRender
    /// When set (by RootShell), the live ScrollView mirrors its vertical offset
    /// here so the floating "Projects" large title can collapse on scroll. nil
    /// keeps the plain behavior (and ProjectsTab independently testable).
    var scrollOffset: Binding<CGFloat>? = nil

    var body: some View {
        if state.config.projects.isEmpty {
            emptyState
        } else if isSnapshotRender {
            cards.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if let scrollOffset {
            ScrollView { cards.tracksScrollOffset(scrollOffset) }
                .frame(maxHeight: .infinity)
        } else {
            ScrollView { cards }.frame(maxHeight: .infinity)
        }
    }

    /// The ONE content inset (Apple-uniform) that lines up every level of a
    /// project section. It equals the session STATUS DOT's total leading INSIDE
    /// the session card: sessionCard `.padding(10)` + SessionBlock's own
    /// `.padding(.horizontal, 9)` = 19. The lifted name header and the "Open
    /// project" footer use this same inset so the name's left edge, the dot, the
    /// "Open project" affordance, and the card content all share one left edge —
    /// and, symmetrically, the right edge (repos/ws counts, the open chevron, the
    /// card content) shares one right edge.
    static let sectionContentInset: CGFloat = 19

    private var cards: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(state.config.projects) { project in
                projectSection(project)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// One grouped project: H4 name header → separate session card → open footer.
    private func projectSection(_ project: ProjectConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            nameHeader(project)
            sessionCard(project)
            openFooter(project)
        }
    }

    /// The project NAME (H4) + its repos/ws count, LIFTED OUT of the card onto
    /// the plain background — distinct from the gray session-list surface below.
    private func nameHeader(_ project: ProjectConfig) -> some View {
        HStack(spacing: 10) {
            Text(project.name)
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 10)
            if let snapshot = state.snapshots[project.id] {
                Text("\(snapshot.repos.count) repos · \(snapshot.workspaces.count) ws")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        // Apple-uniform: the lifted name lines up with the session status dot, and
        // the repos/ws counts line up with the card's right content edge.
        .padding(.horizontal, Self.sectionContentInset)
    }

    /// The project's recent Claude sessions on their OWN gray .glassCard()
    /// surface, separated from the lifted name header above.
    private func sessionCard(_ project: ProjectConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let sessions = state.recentSessionsByProject[project.id] ?? []
            if sessions.isEmpty {
                Text("No recent Claude sessions")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 2)
            } else {
                ForEach(sessions) { row in
                    SessionBlock(row: row) { Task { await state.openSession(row) } }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .glassCard()
    }

    /// The open-project affordance, moved to the END of the section. This is the
    /// tap-to-open target (the name header is now non-interactive lifted copy).
    private func openFooter(_ project: ProjectConfig) -> some View {
        Button { state.open(.project(project.id)) } label: {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Text("Open project")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            // Same Apple-uniform inset as the name header and the card content: the
            // open chevron's right edge lines up with the card's right content edge.
            .padding(.horizontal, Self.sectionContentInset)
        }
        .buttonStyle(.plain)
        .help(project.path)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tree").font(.largeTitle).foregroundStyle(.secondary)
            Text("No projects yet").font(.headline)
            Text("Add the directory that contains your repos with +.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One recent session, rendered as a distinct, tappable block (item 7): status
/// dot + word, title, location · account, age, and a Go/Resume affordance.
struct SessionBlock: View {
    let row: ProjectSessionRow
    let onTap: () -> Void
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    private var isLive: Bool { row.status != .closed }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    // Lead with the WORKSPACE — not the project name (card header)
                    // and not the often-junk session title.
                    Text(row.location)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    // Secondary: status word (lighter) + age.
                    HStack(spacing: 5) {
                        Text(statusWord).foregroundStyle(statusColor)
                        Text("· \(relativeAge(row.lastActivity, now: Date()))").foregroundStyle(.tertiary)
                    }
                    .font(.caption2.weight(.regular))
                }
                Spacer(minLength: 8)
                action   // bigger, vertically-centered Go / Resume
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(blockBackground)
        }
        .buttonStyle(.plain)
        .help(isLive ? "Go to this running session\n\(row.cwd)"
                     : "Resume — starts a new Claude process with --resume\n\(row.cwd)")
    }

    /// Live → "Go" (jump to the running session). Closed → "Resume" (clearly a NEW
    /// process). A real, centered capsule button — not a cramped corner label.
    private var action: some View {
        Label(isLive ? "Go" : "Resume",
              systemImage: isLive ? "arrow.right.circle.fill" : "play.circle")
            .labelStyle(.titleAndIcon)
            .font(.callout.weight(.semibold))
            .foregroundStyle(isLive ? Palette.primary : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(.white.opacity(0.07)))
            .fixedSize()
    }

    /// A faint inset fill — NO border — so the session rows read as a quiet list
    /// inside the project card, not a stack of bordered card-in-cards.
    private var blockBackground: some View {
        RoundedRectangle(cornerRadius: DesignRadius.field, style: .continuous)
            .fill(.white.opacity(isSnapshotRender ? 0.05 : 0.04))
    }

    private var statusColor: Color {
        switch row.status {
        case .running: return Palette.primary
        case .waiting: return Palette.mid
        case .closed: return Palette.neutral
        }
    }

    private var statusWord: String {
        switch row.status {
        case .running: return "running"
        case .waiting: return "waiting"
        case .closed: return "closed"
        }
    }
}

