import SwiftUI
import GroveCore

/// Stats-settings page (route `.statsSettings(id)`): an expandable directory+FILE
/// tree built from the per-file list the git scan publishes (`state.statsFiles`).
/// Folder rows carry a SUMMED line total + descendant file count and an exclude
/// toggle (OFF = excluded); a folder excluded by an ancestor shows disabled. File
/// rows show name + LOC with a data/prose tint and no toggle. Toggling a folder
/// persists via `setStatsFolderExcluded`, which clears the cache and triggers a
/// rescan, so the Stats-tab numbers shrink/grow accordingly.
///
/// The tree is PURE: it builds from injected `statsFiles` (no `.task`, no I/O), so
/// it renders identically offscreen — `isSnapshotRender` swaps the lazy
/// `DisclosureGroup`/`ScrollView` (whose children aren't realized under
/// ImageRenderer) for a fully-expanded flat list, the same trick the other screens use.
struct StatsSettingsScreen: View {
    @ObservedObject var state: AppState
    let projectID: UUID
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    /// Always the CURRENT copy in state.config (edits to exclusions replace it there).
    private var project: ProjectConfig? {
        state.config.projects.first { $0.id == projectID }
    }

    /// Project-relative folder paths currently excluded. Drives both the toggles and
    /// the tree's `isExcluded`/`excludedByAncestor` propagation.
    private var ignoredFolders: Set<String> {
        Set(project?.statsIgnoredFolders ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScopeHeader(title: "Stats Settings", subtitle: project?.name,
                        onBack: { state.goBack() })
            content
        }
    }

    // MARK: - Content / states

    @ViewBuilder
    private var content: some View {
        if let files = state.statsFiles[projectID] {
            if files.isEmpty {
                placeholder("No files matched the scan.", system: "doc")
            } else {
                tree(files: files)
            }
        } else if state.isStatsScanning {
            VStack(spacing: 8) {
                ProgressView().controlSize(.large)
                Text("Scanning code…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            placeholder("No stats yet — open the Stats tab to scan this project.",
                        system: "chart.bar.doc.horizontal")
        }
    }

    private func placeholder(_ message: String, system: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: system).font(.largeTitle).foregroundStyle(.secondary)
            Text(message).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Tree

    @ViewBuilder
    private func tree(files: [StatFileEntry]) -> some View {
        let card = VStack(alignment: .leading, spacing: 8) {
            CardLabel(title: "Files", systemImage: "doc.text.magnifyingglass")
            Text("Toggle a folder off to exclude it (and its files) from the scan.")
                .font(.caption2).foregroundStyle(.secondary)
            if isSnapshotRender {
                // Lazy DisclosureGroups don't realize their children offscreen, so
                // render the fully-expanded flat list (depth-indented) instead.
                let rows = buildFileTree(files: files, ignoredFolders: ignoredFolders)
                ForEach(rows) { row in
                    flatRow(row)
                }
            } else {
                let nodes = buildFileTreeNodes(files: files, ignoredFolders: ignoredFolders)
                ForEach(nodes) { node in
                    nodeView(node)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassCard()

        if isSnapshotRender {
            card.padding(8).frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView { card.padding(8) }
        }
    }

    // MARK: - Live (nested DisclosureGroup) rendering

    /// One node. Folders become a `DisclosureGroup` (lazy disclosure of children);
    /// files render as a leaf row. Returns `AnyView` to break the self-referential
    /// opaque-type cycle the recursion would otherwise create.
    private func nodeView(_ node: FileTreeNode) -> AnyView {
        if node.isFolder, let children = node.children {
            return AnyView(
                DisclosureGroup {
                    ForEach(children) { child in
                        nodeView(child)
                    }
                } label: {
                    folderLabel(name: node.name, relativePath: node.relativePath,
                                lines: node.lines, fileCount: node.fileCount,
                                isExcluded: node.isExcluded,
                                excludedByAncestor: node.excludedByAncestor)
                }
            )
        } else {
            return AnyView(
                fileLabel(name: node.name, lines: node.lines, language: node.language,
                          isDataProse: node.isDataProse, isExcluded: node.isExcluded)
            )
        }
    }

    // MARK: - Snapshot (flat, indented) rendering

    @ViewBuilder
    private func flatRow(_ row: FileTreeRow) -> some View {
        Group {
            if row.isFolder {
                folderLabel(name: row.name, relativePath: row.relativePath,
                            lines: row.lines, fileCount: row.fileCount,
                            isExcluded: row.isExcluded,
                            excludedByAncestor: row.excludedByAncestor)
            } else {
                fileLabel(name: row.name, lines: row.lines, language: row.language,
                          isDataProse: row.isDataProse, isExcluded: row.isExcluded)
            }
        }
        .padding(.leading, CGFloat(row.depth) * 14)
    }

    // MARK: - Row labels (shared by live + snapshot)

    /// A folder row: a checkbox Toggle (ON = included), the folder name, and a
    /// "LOC · N files" summary. An ancestor-excluded folder is disabled (the
    /// ancestor governs it) and dimmed.
    private func folderLabel(name: String, relativePath: String, lines: Int,
                             fileCount: Int, isExcluded: Bool,
                             excludedByAncestor: Bool) -> some View {
        let included = Binding<Bool>(
            get: { !isExcluded },
            set: { include in
                state.setStatsFolderExcluded(projectID: projectID,
                                             relativePath: relativePath,
                                             excluded: !include)
            })
        return HStack(spacing: 6) {
            Toggle(isOn: included) {
                HStack(spacing: 5) {
                    Image(systemName: "folder.fill")
                        .font(.caption2)
                        .foregroundStyle(isExcluded ? Color.secondary : cardAccent)
                    Text(name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(isExcluded ? Color.secondary : Color.primary)
                        .lineLimit(1)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(excludedByAncestor)
            Spacer(minLength: 8)
            Text("\(groupedThousands(lines)) · \(fileCount) file\(fileCount == 1 ? "" : "s")")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// A file row: name + LOC + a small language tag, tinted by the data/prose
    /// split (neutral gray for data/prose, blue for code). No toggle; an excluded
    /// file is dimmed.
    private func fileLabel(name: String, lines: Int, language: String?,
                           isDataProse: Bool, isExcluded: Bool) -> some View {
        // Leading pad lines up the file name with a folder's name (past its checkbox).
        HStack(spacing: 6) {
            Color.clear.frame(width: 16, height: 1)
            Circle()
                .fill(isExcluded ? Palette.neutral
                      : (isDataProse ? Palette.neutral : Palette.primary))
                .frame(width: 6, height: 6)
            Text(name)
                .font(.caption)
                .foregroundStyle(isExcluded ? Color.secondary : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let language {
                Text(language)
                    .font(.caption2)
                    .foregroundStyle(isDataProse ? Palette.neutral : Palette.primary.opacity(0.85))
                    .lineLimit(1)
            }
            Text(groupedThousands(lines))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
        }
    }
}
