import Foundation

/// Where a (re)launch opens.
public enum LaunchTarget: String, CaseIterable, Sendable, Equatable {
    case cmux
    case terminal
    var label: String { self == .cmux ? "cmux" : "Terminal" }
}

/// A pending Resume/New launch, configured in the launch sheet before it runs.
/// `sessionId == nil` is a fresh session; otherwise it's `--resume <id>`.
public struct LaunchRequest: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var sessionId: String?
    public var cwd: String
    public var title: String
    public var account: String        // CHOSEN account name (user can change in the sheet)
    /// The account the session currently BELONGS to (== `account` for a new
    /// session). When a resume targets a different `account`, the cross-account
    /// store-linking runs against this origin so the transcript stays visible.
    public var originAccount: String
    public var model: String?         // nil = (default)
    public var effort: String?        // nil = (default)
    /// Per-launch `--dangerously-skip-permissions`. Seeded from the project default
    /// but overridable in the sheet, so a single relaunch can opt in/out.
    public var skipPermissions: Bool
    public var target: LaunchTarget

    public init(sessionId: String?, cwd: String, title: String, account: String,
                originAccount: String? = nil, model: String? = nil, effort: String? = nil,
                skipPermissions: Bool = false, target: LaunchTarget = .cmux) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.title = title
        self.account = account
        self.originAccount = originAccount ?? account
        self.model = model
        self.effort = effort
        self.skipPermissions = skipPermissions
        self.target = target
    }

    public var isResume: Bool { sessionId != nil }
}
