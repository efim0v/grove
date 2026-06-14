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
    public var account: String        // account name
    public var model: String?         // nil = (default)
    public var effort: String?        // nil = (default)
    public var target: LaunchTarget

    public init(sessionId: String?, cwd: String, title: String, account: String,
                model: String? = nil, effort: String? = nil, target: LaunchTarget = .cmux) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.title = title
        self.account = account
        self.model = model
        self.effort = effort
        self.target = target
    }

    public var isResume: Bool { sessionId != nil }
}
