import Foundation

public final class ConfigStore {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Missing file -> (defaultConfig, nil). Corrupt file -> copied to <name>.bak,
    /// returns (defaultConfig, "<message>") so the UI can surface the problem.
    public func load() -> (config: GroveConfig, issue: String?) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return (.defaultConfig, nil)
        }
        do {
            let data = try Data(contentsOf: url)
            let config = try JSONDecoder().decode(GroveConfig.self, from: data)
            return (config, nil)
        } catch {
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent(url.lastPathComponent + ".bak")
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: url, to: backup)
            let message = "config at \(url.path) is corrupt (\(error.localizedDescription)); "
                + "backup saved to \(backup.path), starting with defaults"
            return (.defaultConfig, message)
        }
    }

    /// Atomic save: writes a temp file in the destination directory, then renames it
    /// over the target. Creates parent directories as needed.
    public func save(_ config: GroveConfig) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            let tmp = dir.appendingPathComponent("\(url.lastPathComponent).tmp-\(UUID().uuidString)")
            try data.write(to: tmp, options: [])
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
        } catch {
            throw GroveError.io("failed to save config to \(url.path): \(error.localizedDescription)")
        }
    }
}
