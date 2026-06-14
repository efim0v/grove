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
                    SessionBlock(row: row) { Task { await state.openSession(row) } }
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
    let onTap: () -> Void
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 9) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    // Title line + the Go/Resume affordance, aligned as a clean row.
                    HStack(spacing: 8) {
                        Text(row.title)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Label(row.canGo ? "Go" : "Resume",
                              systemImage: row.canGo ? "arrow.right.circle.fill" : "play.circle")
                            .labelStyle(.titleAndIcon)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(cardAccent)
                            .fixedSize()
                    }
                    // Secondary line: status · location · age (account dropped — it's
                    // shown in the dashboard; here it was just clutter).
                    HStack(spacing: 5) {
                        Text(statusWord).foregroundStyle(statusColor)
                        Text("· \(row.location)").foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(relativeAge(row.lastActivity, now: Date())).foregroundStyle(.tertiary)
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
        .help(row.cwd)
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

