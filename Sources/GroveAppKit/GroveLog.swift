import os

/// Central os.Logger handles. Stream timings live with:
///   log stream --predicate 'subsystem == "dev.artemefimov.grove"'
/// or open Console.app and filter on the subsystem.
public enum GroveLog {
    public static let menubar = Logger(subsystem: "dev.artemefimov.grove", category: "menubar")
    /// Open/scan/usage timings (item 2 perf work).
    public static let perf = Logger(subsystem: "dev.artemefimov.grove", category: "perf")
}
