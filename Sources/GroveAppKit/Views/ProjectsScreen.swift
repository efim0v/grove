import SwiftUI
import AppKit
import GroveCore

/// The Projects tab (item 4 — the primary view): one card per configured project
/// with its name, path and, crucially, its 2 most recent Claude sessions as
/// tappable blocks for instant terminal access (items 4/7/24). Tapping the card
/// header drills into the project's full workspace scope.
struct ProjectsTab: View {
    @ObservedObject var state: AppState
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    var body: some View {
        if state.config.projects.isEmpty {
            emptyState
        } else if isSnapshotRender {
            cards.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView { cards }.frame(maxHeight: .infinity)
        }
    }

    private var cards: some View {
        VStack(spacing: 8) {
            ForEach(state.config.projects) { project in
                projectCard(project)
            }
        }
        .padding(8)   // consistent with the Charts window's edge padding
    }

    private func projectCard(_ project: ProjectConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { state.open(.project(project.id)) } label: { cardHeader(project) }
                .buttonStyle(.plain)
                .help(project.path)
            let sessions = state.recentSessionsByProject[project.id] ?? []
            if sessions.isEmpty {
                Text("No recent Claude sessions")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 2)
            } else {
                ForEach(sessions) { row in
                    SessionBlock(row: row, accent: ProjectAccent.color(for: project)) {
                        Task { await state.openSession(row) }
                    }
                }
            }
        }
        .padding(10)
        .glassCard()
    }

    private func cardHeader(_ project: ProjectConfig) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(ProjectAccent.color(for: project))
                    .lineLimit(1)
                Text(project.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 10)
            if let snapshot = state.snapshots[project.id] {
                Text("\(snapshot.repos.count) repos · \(snapshot.workspaces.count) ws")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
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
    /// The owning project's accent — colors the workspace name so sessions are
    /// easy to attribute at a glance.
    var accent: Color = cardAccent
    let onTap: () -> Void
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    private var isLive: Bool { row.status != .closed }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 9) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    // Lead with the WORKSPACE (accent) — not the project name (that's
                    // the card header) and not the often-junk session title.
                    HStack(spacing: 8) {
                        Text(row.location)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(accent)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        action
                    }
                    // Secondary: status word (colored) + age.
                    HStack(spacing: 5) {
                        Text(statusWord).foregroundStyle(statusColor)
                        Text("· \(relativeAge(row.lastActivity, now: Date()))").foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                    }
                    .font(.caption2)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(blockBackground)
        }
        .buttonStyle(.plain)
        .help(isLive ? "Go to this running session\n\(row.cwd)"
                     : "Resume — starts a new Claude process with --resume\n\(row.cwd)")
    }

    /// Live → "Go" (jump to the running session). Closed → "Resume" (clearly a NEW
    /// process). The label keys off the live status, not on whether cmux hosts it.
    private var action: some View {
        Label(isLive ? "Go" : "Resume",
              systemImage: isLive ? "arrow.right.circle.fill" : "play.circle")
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(isLive ? accent : .secondary)
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
        case .running: return .green
        case .waiting: return .yellow
        case .closed: return .gray
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

