import Foundation

/// The panel's navigation state machine: at any moment the panel shows ONE
/// scope (general -> specific), never an overlay. RootView switches over this
/// and animates transitions; AppState.open/goBack mutate it.
public enum Route: Equatable {
    case projects
    case accounts
    case globalSettings
    case project(UUID)
    case projectSettings(UUID)
    case createWorkspace(UUID)
    /// The Stats-tab settings page (directory+file exclusion tree). Reached from a
    /// gear affordance on the Stats tab; backs out to its project (the Stats tab).
    case statsSettings(UUID)

    /// Scope depth, used to classify a route change as push (deeper or equal)
    /// or pop (shallower) for the transition direction.
    public var depth: Int {
        switch self {
        case .projects: return 0
        case .project, .accounts, .globalSettings: return 1
        case .projectSettings, .createWorkspace, .statsSettings: return 2
        }
    }

    /// Explicit back-map: createWorkspace/projectSettings/statsSettings -> their
    /// project; project/accounts/globalSettings -> projects; projects -> itself (root).
    public var backRoute: Route {
        switch self {
        case .projects: return .projects
        case .project, .accounts, .globalSettings: return .projects
        case .projectSettings(let id), .createWorkspace(let id), .statsSettings(let id):
            return .project(id)
        }
    }
}
