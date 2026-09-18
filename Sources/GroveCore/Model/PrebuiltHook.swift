import Foundation

/// Whether a prebuilt hook can actually do anything for a given project RIGHT
/// NOW. `.ready` lights the row green ("this will run on the next fork");
/// `.unavailable` carries a human reason ("nothing to copy — no CLAUDE.md at the
/// project root") so the UI can explain why a preset is dimmed instead of
/// silently offering a no-op.
public enum PrebuiltHookStatus: Equatable, Sendable {
    case ready
    case unavailable(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// The reason a hook can't run, or nil when it's ready.
    public var reason: String? {
        if case .unavailable(let why) = self { return why }
        return nil
    }
}

/// A curated, one-click automation a user can attach to a project's fork
/// pipeline from the Settings tab. Each prebuilt hook is a THIN wrapper over an
/// existing, tested primitive (today: `SeedFile`) plus an algorithmic
/// pre-flight check (`status`) that verifies it can actually run before the user
/// commits to it — so the Settings row goes green only when the inputs exist.
///
/// New presets are added to `all`; the validation contract is intentionally
/// data-driven (`requiresFile`) so most presets need no bespoke logic.
public struct PrebuiltHook: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let summary: String
    public let systemImage: String
    /// A project-root-relative file that must exist for the hook to have
    /// anything to do. nil = the hook is always applicable.
    public let requiresFile: String?
    /// The seed this hook installs when added. Reusing `SeedFile` means the hook
    /// rides the already-tested creation-time seeding path rather than a fragile
    /// ad-hoc shell command.
    public let seed: SeedFile

    public init(id: String, title: String, summary: String, systemImage: String,
                requiresFile: String?, seed: SeedFile) {
        self.id = id
        self.title = title
        self.summary = summary
        self.systemImage = systemImage
        self.requiresFile = requiresFile
        self.seed = seed
    }

    /// The full catalog, in display order.
    public static let all: [PrebuiltHook] = [
        PrebuiltHook(
            id: "import-claude-md",
            title: "Import CLAUDE.md",
            summary: "Copy the project-root CLAUDE.md into every new fork so "
                + "Claude finds it on its upward walk.",
            systemImage: "doc.text",
            requiresFile: "CLAUDE.md",
            seed: SeedFile(source: "CLAUDE.md", mode: .copy, dest: .umbrella)),
    ]

    /// Pre-flight check against the project root: `.ready` when the required
    /// input exists (or there is none), `.unavailable` with a reason otherwise.
    public func status(projectPath: String) -> PrebuiltHookStatus {
        guard let required = requiresFile else { return .ready }
        let path = (expandTilde(projectPath) as NSString).appendingPathComponent(required)
        if FileManager.default.fileExists(atPath: path) {
            return .ready
        }
        return .unavailable("No \(required) at the project root — nothing to copy.")
    }

    /// True when this hook's seed is already installed on the project (matched by
    /// source + destination, so a hand-added equivalent also reads as installed).
    public func isInstalled(in project: ProjectConfig) -> Bool {
        project.seedFiles.contains { $0.source == seed.source && $0.dest == seed.dest }
    }

    /// Installs the hook's seed (idempotent — a no-op if already present).
    public func install(into project: inout ProjectConfig) {
        guard !isInstalled(in: project) else { return }
        project.seedFiles.append(seed)
    }

    /// Removes this hook's seed if present.
    public func remove(from project: inout ProjectConfig) {
        project.seedFiles.removeAll { $0.source == seed.source && $0.dest == seed.dest }
    }
}
