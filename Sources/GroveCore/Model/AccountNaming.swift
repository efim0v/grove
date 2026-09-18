import Foundation

/// Accounts are named by the login Claude Code knows them by — the email in the
/// account's `.claude.json` — the way Brow names them. A folder name ("default",
/// "work-account") is what the user typed once; the email is who is signed in.
public enum AccountNaming {
    /// The name for an account with `email`, given the names already in use: the
    /// email itself, or — a second config dir signed in to the same account —
    /// `email (folder)`, falling back to `email (2)`, `email (3)`… when the folder
    /// is the email already.
    public static func uniqueName(email: String, folder: String, taken: Set<String>) -> String {
        if !taken.contains(email) { return email }
        if folder != email, !taken.contains("\(email) (\(folder))") { return "\(email) (\(folder))" }
        var n = 2
        while taken.contains("\(email) (\(n))") { n += 1 }
        return "\(email) (\(n))"
    }

    /// Old name → new name for every account whose known email differs from its
    /// name. Accounts with no email, and accounts already named by their email, keep
    /// their names and reserve them first, so a rename never collides with a name
    /// that stays.
    public static func renames(accounts: [AccountConfig], emailByName: [String: String]) -> [String: String] {
        var taken: Set<String> = []
        for account in accounts {
            let email = emailByName[account.name]
            if email == nil || email == account.name { taken.insert(account.name) }
        }
        var renames: [String: String] = [:]
        for account in accounts {
            guard let email = emailByName[account.name], email != account.name else { continue }
            let folder = ((account.configDir as NSString).expandingTildeInPath as NSString).lastPathComponent
            let name = uniqueName(email: email, folder: folder, taken: taken)
            taken.insert(name)
            renames[account.name] = name
        }
        return renames
    }
}

public extension AccountNaming {
    /// Same login in several config dirs → ONE account. Per email, the dir with the
    /// most recent activity (`activityByName`: the `.claude.json` mtime) becomes the
    /// account's `configDir`; the others become its `aliasDirs`, their config
    /// entries go, and their names map to the survivor's in the returned renames so
    /// project defaults follow. Accounts with no email are left untouched.
    static func merged(accounts: [AccountConfig], emailByName: [String: String],
                       activityByName: [String: Date] = [:]) -> (accounts: [AccountConfig], renames: [String: String]) {
        var byEmail: [String: [AccountConfig]] = [:]
        var order: [String] = []
        for account in accounts {
            guard let email = emailByName[account.name] else { continue }
            if byEmail[email] == nil { order.append(email) }
            byEmail[email, default: []].append(account)
        }
        var renames: [String: String] = [:]
        var absorbed: Set<String> = []
        var survivorByName: [String: AccountConfig] = [:]
        for email in order {
            let group = byEmail[email] ?? []
            guard group.count > 1 else { continue }
            let primary = group.enumerated().max { a, b in
                let da = activityByName[a.element.name] ?? .distantPast
                let db = activityByName[b.element.name] ?? .distantPast
                return da == db ? a.offset > b.offset : da < db
            }!.element
            var survivor = primary
            for other in group where other.name != primary.name {
                survivor.aliasDirs.append(contentsOf: other.allConfigDirs.filter { !survivor.allConfigDirs.contains($0) })
                survivor.sharedStore = survivor.sharedStore || other.sharedStore
                survivor.monitoring = survivor.monitoring || other.monitoring
                absorbed.insert(other.name)
                renames[other.name] = primary.name
            }
            survivorByName[primary.name] = survivor
        }
        let kept = accounts.compactMap { account -> AccountConfig? in
            if absorbed.contains(account.name) { return nil }
            return survivorByName[account.name] ?? account
        }
        return (kept, renames)
    }
}

extension GroveConfig {
    /// The config with `renames` applied to the accounts AND to every project's
    /// default account, so a project keeps pointing at the same account.
    public func renamingAccounts(_ renames: [String: String]) -> GroveConfig {
        var copy = self
        copy.accounts = accounts.map { account in
            guard let name = renames[account.name] else { return account }
            var renamed = account
            renamed.name = name
            return renamed
        }
        copy.projects = projects.map { project in
            guard let current = project.defaultAccount, let name = renames[current] else { return project }
            var updated = project
            updated.defaultAccount = name
            return updated
        }
        return copy
    }
}
