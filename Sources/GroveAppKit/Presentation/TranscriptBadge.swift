public enum TranscriptBadge: Equatable {
    case mirrored, restorable, unmirrored
    public static func state(liveExists: Bool, mirrored: Bool) -> TranscriptBadge {
        switch (liveExists, mirrored) {
        case (true,  true):  return .mirrored
        case (false, true):  return .restorable
        default:             return .unmirrored
        }
    }
    public var label: String {
        switch self {
        case .mirrored:   return "mirrored"
        case .restorable: return "mirror-only"
        case .unmirrored: return "unmirrored"
        }
    }
}
