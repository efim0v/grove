import AppKit
import Foundation

/// Backend seam for terminal-app automation (see CmuxService for routing).
/// The AppleScript implementation below is the fallback used when cmux's
/// control socket denies Grove (socketControlMode "cmuxOnly"); Apple Events
/// bypass the socket entirely, so this works against a running cmux without
/// any cmux-side configuration beyond the one-time macOS automation consent.
protocol CmuxScripting: Sendable {
    /// Cheap liveness check (no Apple Event, no consent prompt).
    func isAppRunning() -> Bool
    func listWorkspaces() async throws -> [CmuxWorkspace]
    /// Creates a workspace (tab) in the front window, cd's it to `cwd` and
    /// optionally starts `command`. AppleScript cannot name tabs, so unlike
    /// the socket backend there is no name parameter: cmux titles the tab
    /// after its working directory / running command.
    func newWorkspace(cwd: String, command: String?, focus: Bool) async throws
    func selectWorkspace(tabId: String) async throws
    func closeWorkspace(tabId: String) async throws
}

/// cmux automation via its AppleScript dictionary (`sdef /Applications/cmux.app`):
/// windows > tabs (= workspaces) > terminals, commands `new tab`, `select tab`,
/// `close tab`, `activate window`, `perform action`, `input text`.
///
/// Scripts run through an `/usr/bin/osascript` CHILD process. TCC attributes
/// the child's Apple Events to Grove (the responsible process), so the
/// automation consent is still Grove > cmux. In-process NSAppleScript was
/// tried first and is NON-DETERMINISTICALLY broken when the sender is GUI
/// Grove: scripts randomly stall mid-execution inside AESendMessage's reply
/// runloop until the -1712 two-minute timeout while cmux sits idle (observed
/// repeatedly via --cmux-probe + `sample`; App Nap suppression did not help;
/// identical scripts via the osascript child complete in <1s in every run).
///
/// Empirically verified against cmux 0.64.4 (2026-06):
/// - `working directory` of `focused terminal` is live (updates after `cd`),
///   but some tabs have no terminal -> wrapped in `try`.
/// - `new tab` does NOT auto-select the new tab; text injection only reaches
///   a tab that is selected (unselected surfaces drop input), so newWorkspace
///   selects the probe tab and restores the previous selection afterwards
///   when focus=false.
/// - `input text` (paste) is unreliable into a fresh shell; the Ghostty action
///   `perform action "text:...\r"` writes to the pty directly and is reliable,
///   BUT input sent while the shell is still initializing is flushed away by
///   zsh. The only robust handshake: retry the (idempotent) setup line until a
///   marker file it touches appears. Pty input is FIFO, so duplicate setup
///   lines all execute before the user command that is sent only after the
///   marker confirms the shell is interactive.
/// - The Ghostty action parser interprets backslash escapes in the "text:"
///   payload (and mangles octal/control escapes), so payload backslashes are
///   doubled and control characters never embedded; the trailing `\r` (two
///   characters: backslash, r) is what the parser turns into the Enter key.
/// - Tab titles are read-only (no rename in the dictionary) and cmux overrides
///   OSC 0/2 titles with the working directory, so workspace names cannot be
///   applied; AppleScript-created tabs keep cmux's cwd-derived title.
/// - When the sender is NOT a cmux descendant (GUI Grove), cmux executes
///   mutating commands (`new tab`, ...) but does not reliably REPLY to them —
///   the Apple Event times out (-1712) after 2 minutes while the tab was
///   created instantly. Therefore every mutating command is sent inside
///   `try`/`with timeout of 10 seconds` and its EFFECT is verified by reading
///   state (property reads and list diffs reply fine). Property reads keep
///   the default timeout: the very first Apple Event blocks on the macOS
///   automation consent dialog, which must not be cut short.
struct CmuxAppleScript: CmuxScripting {
    private let runner: any CommandRunning

    init(runner: any CommandRunning = ProcessRunner()) {
        self.runner = runner
    }

    /// listWorkspaces ids are namespaced "as:<tabId>" so ids handed back to
    /// selectWorkspace/closeWorkspace route to this backend even if the socket
    /// has silently resumed in between.
    static let idPrefix = "as:"

    /// The raw cmux tab id when `id` carries this backend's namespace, else nil.
    static func tabId(fromNamespaced id: String) -> String? {
        guard id.hasPrefix(idPrefix) else { return nil }
        return String(id.dropFirst(idPrefix.count))
    }

    // ASCII unit/record separators: delimiters no tab title plausibly contains.
    static let fieldSeparator = "\u{1F}"
    static let rowSeparator = "\u{1E}"

    /// Diagnostic hook (used by --cmux-probe): every executed script reports
    /// "<label> <ms>ms <ok|error>" here. Set/read only around probe runs.
    nonisolated(unsafe) static var trace: (@Sendable (String) -> Void)?

    // MARK: - String escaping (pure, unit-tested)

    /// An AppleScript source string literal: backslashes and double quotes
    /// escaped, wrapped in quotes.
    static func appleScriptLiteral(_ s: String) -> String {
        "\"" + s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            + "\""
    }

    /// Shell command -> Ghostty "text:" action string that types the command
    /// and presses Enter. The action parser unescapes backslash sequences, so
    /// literal backslashes are doubled; embedded control characters (which
    /// would submit early or confuse the parser) are replaced with spaces.
    static func textAction(_ shellCommand: String) -> String {
        var payload = shellCommand.replacingOccurrences(of: "\\", with: "\\\\")
        payload = String(String.UnicodeScalarView(payload.unicodeScalars.map {
            $0.properties.generalCategory == .control ? " " : $0
        }))
        return "text:" + payload + "\\r"
    }

    // MARK: - Script execution

    func isAppRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: CmuxService.bundleID).isEmpty
    }

    /// Executes `source` via an osascript child (see type-level comment for
    /// why not NSAppleScript) and returns its stdout with the trailing
    /// newline osascript appends stripped. AppleScript errors (including the
    /// user declining the automation consent, error -1743) become actionable
    /// GroveError.cmuxUnavailable. The generous timeout leaves room for the
    /// one-time consent dialog, which blocks the first Apple Event until the
    /// user answers.
    func runScript(_ source: String) async throws -> String {
        let started = Date()
        func traced<T>(_ outcome: String, _ value: T) -> T {
            if let trace = Self.trace {
                let label = source.split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { $0.contains("tab") || $0.contains("window") || $0.contains("perform") }
                    ?? "script"
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                trace("\(label.prefix(90)) -> \(ms)ms \(outcome)")
            }
            return value
        }
        let result: ProcessResult
        do {
            result = try await runner.run("/usr/bin/osascript", ["-e", source],
                                          cwd: nil, env: nil, timeout: 150)
        } catch {
            throw traced("spawn/timeout error", error)
        }
        guard result.exitCode == 0 else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            var text = "AppleScript control of cmux failed: \(stderr)"
            if stderr.contains("-1743") || stderr.contains("Not authorized") {
                text += " — allow Grove to control cmux in System Settings"
                    + " > Privacy & Security > Automation."
            }
            throw traced("error", GroveError.cmuxUnavailable(text))
        }
        var stdout = result.stdout
        if stdout.hasSuffix("\n") { stdout.removeLast() }
        return traced("ok", stdout)
    }

    // MARK: - Operations

    /// Also used by the --cmux-probe transport benchmarks.
    static var listScriptSource: String {
        """
        set fs to string id 31
        set rs to string id 30
        set out to ""
        tell application id \(appleScriptLiteral(CmuxService.bundleID))
            repeat with w in windows
                repeat with t in tabs of w
                    set wd to ""
                    try
                        set wd to working directory of focused terminal of t
                    end try
                    set out to out & (id of t) & fs & (name of t) & fs & wd & rs
                end repeat
            end repeat
        end tell
        return out
        """
    }

    func listWorkspaces() async throws -> [CmuxWorkspace] {
        let raw = try await runScript(Self.listScriptSource)
        return raw.components(separatedBy: Self.rowSeparator).compactMap { row in
            let fields = row.components(separatedBy: Self.fieldSeparator)
            guard fields.count == 3, !fields[0].isEmpty else { return nil }
            return CmuxWorkspace(id: Self.idPrefix + fields[0], title: fields[1],
                                 currentDirectory: fields[2])
        }
    }

    func selectWorkspace(tabId: String) async throws {
        try await selectVerified(tabId: tabId, activateWindow: true)
    }

    /// Fires `select tab` (+ optionally `activate window`) and confirms via
    /// the tab's `selected` property; retries because cmux may apply the
    /// command without replying to it (see type-level comment).
    private func selectVerified(tabId: String, activateWindow: Bool) async throws {
        let source = fireAndReadScript(tabId: tabId,
                                       fire: "select tab t" + (activateWindow ? "\nactivate window w" : ""),
                                       read: "(selected of t) as text")
        for attempt in 0..<3 {
            let result = try await runScript(source)
            if result == "true" { return }
            if result == "NOTFOUND" {
                throw GroveError.cmuxUnavailable("cmux workspace \(tabId) not found via AppleScript")
            }
            if attempt < 2 { try await Task.sleep(nanoseconds: 300_000_000) }
        }
        throw GroveError.cmuxUnavailable("cmux did not select workspace \(tabId) via AppleScript")
    }

    func closeWorkspace(tabId: String) async throws {
        let result = try await runScript(fireAndReadScript(tabId: tabId,
                                                           fire: "close tab t", read: "\"FIRED\""))
        guard result == "FIRED" else {
            throw GroveError.cmuxUnavailable("cmux workspace \(tabId) not found via AppleScript")
        }
        // Verify the tab actually disappeared (the close command itself may
        // not be replied to).
        for _ in 0..<10 {
            if !(try await listTabIds().contains(tabId)) { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw GroveError.cmuxUnavailable("cmux workspace \(tabId) still present after AppleScript close")
    }

    /// Script that finds the tab with `tabId` (t, in window w), fires the
    /// mutating `fire` statements inside try/short-timeout (cmux executes but
    /// may not reply, see type-level comment), then returns the `read`
    /// expression; "NOTFOUND" when no window contains the tab.
    private func fireAndReadScript(tabId: String, fire: String, read: String) -> String {
        """
        tell application id \(Self.appleScriptLiteral(CmuxService.bundleID))
            repeat with w in windows
                repeat with t in tabs of w
                    if (id of t) is \(Self.appleScriptLiteral(tabId)) then
                        try
                            with timeout of 10 seconds
                                \(fire)
                            end timeout
                        end try
                        return \(read)
                    end if
                end repeat
            end repeat
        end tell
        return "NOTFOUND"
        """
    }

    /// Raw (un-namespaced) ids of all tabs across all windows.
    private func listTabIds() async throws -> Set<String> {
        let source = """
        set rs to string id 30
        set out to ""
        tell application id \(Self.appleScriptLiteral(CmuxService.bundleID))
            repeat with w in windows
                repeat with t in tabs of w
                    set out to out & (id of t) & rs
                end repeat
            end repeat
        end tell
        return out
        """
        let raw = try await runScript(source)
        return Set(raw.components(separatedBy: Self.rowSeparator).filter { !$0.isEmpty })
    }

    func newWorkspace(cwd: String, command: String?, focus: Bool) async throws {
        // 1. Remember the current state, then FIRE `new tab` (or `new window`
        //    when there is none) without waiting for its reply, and identify
        //    the created tab by diffing the id list — robust against cmux not
        //    replying to mutating commands from non-descendant senders.
        let before = try await listTabIds()
        let previousTabId = try await runScript("""
        tell application id \(Self.appleScriptLiteral(CmuxService.bundleID))
            if (count of windows) is 0 then return ""
            try
                return id of selected tab of front window
            end try
        end tell
        return ""
        """)
        _ = try await runScript("""
        tell application id \(Self.appleScriptLiteral(CmuxService.bundleID))
            try
                with timeout of 10 seconds
                    if (count of windows) is 0 then
                        new window
                    else
                        new tab in front window
                    end if
                end timeout
            end try
        end tell
        return "FIRED"
        """)
        var tabId: String?
        for _ in 0..<20 {  // up to 5s
            if let added = try await listTabIds().subtracting(before).first {
                tabId = added
                break
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let tabId else {
            throw GroveError.cmuxUnavailable("cmux did not create a workspace via AppleScript (no new tab appeared)")
        }

        // 2. The tab must be selected for its terminal to accept input
        //    (unselected surfaces drop it).
        try await selectVerified(tabId: tabId, activateWindow: false)

        // 3. Inject "cd && touch <marker> && clear" and retry until the marker
        //    file proves the shell executed it (input sent while the shell is
        //    still starting up is flushed away; see type-level comment).
        let marker = NSTemporaryDirectory() + "grove-cmux-ready-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: marker) }
        let setup = "cd \(shellQuote(cwd)) && touch \(shellQuote(marker)) && clear"
        var confirmed = false
        attempts: for _ in 0..<8 {
            try await inject(setup, tabId: tabId)
            for _ in 0..<15 {  // poll up to 1.5s per attempt
                if FileManager.default.fileExists(atPath: marker) {
                    confirmed = true
                    break attempts
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        guard confirmed else {
            throw GroveError.cmuxUnavailable(
                "created cmux workspace \(tabId) via AppleScript, but its shell did not"
                + " accept the setup command within ~12s (the tab was left open)")
        }

        // 4. The user command, sent exactly once now that the shell is provably
        //    interactive. Verbatim, not exec'd: Grove's claude command lines can
        //    carry env prefixes (CLAUDE_CONFIG_DIR=... claude) which `exec`
        //    rejects in both zsh and bash.
        if let command, !command.isEmpty {
            try await inject(command, tabId: tabId)
        }

        // 5. Focus handling. The new tab had to be selected for injection;
        //    focus=false restores the previously selected tab to mirror the
        //    socket backend's --focus false. App-level activation for
        //    focus=true is done by CmuxService.activateApp (shared with the
        //    socket path).
        if focus {
            _ = try? await runScript(fireAndReadScript(tabId: tabId,
                                                       fire: "activate window w", read: "\"FIRED\""))
        } else if !previousTabId.isEmpty, previousTabId != tabId {
            _ = try? await selectVerified(tabId: previousTabId, activateWindow: false)
        }
    }

    /// Types `shellCommand` + Enter into the tab's focused terminal via the
    /// Ghostty "text:" action (fired without waiting for the reply; callers
    /// verify the effect, e.g. via the marker file).
    private func inject(_ shellCommand: String, tabId: String) async throws {
        let action = Self.appleScriptLiteral(Self.textAction(shellCommand))
        _ = try await runScript(fireAndReadScript(
            tabId: tabId,
            fire: "perform action \(action) on (focused terminal of t)",
            read: "\"FIRED\""))
    }
}
