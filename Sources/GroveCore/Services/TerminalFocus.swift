import Foundation

/// Best-effort focus of a session running in Apple's Terminal.app, by matching
/// the process's controlling tty to a Terminal tab. This is the non-cmux fallback
/// for "redirect me to the running session" — cmux stays the primary gate, but a
/// session started in a plain Terminal window can still be brought to the front.
/// (iTerm and others aren't covered; they each need their own scripting bridge.)
public enum TerminalFocus {
    /// Brings the Terminal.app window/tab whose tty matches `tty` (e.g.
    /// "/dev/ttys025") to the front. Returns true only when a matching tab was
    /// found and focused. Never throws — a scripting failure just returns false.
    @discardableResult
    public static func focusTerminalApp(tty: String) -> Bool {
        // Guard against script injection via the tty string (it comes from `ps`,
        // but be defensive): only the expected /dev/ttysNNN shape is allowed.
        guard tty.hasPrefix("/dev/tty"), tty.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "/" })
        else { return false }
        let script = """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(tty)" then
                set selected of t to true
                set frontmost of w to true
                activate
                return "ok"
              end if
            end repeat
          end repeat
        end tell
        return "no"
        """
        return runOsascript(script) == "ok"
    }

    /// Opens a new Apple Terminal.app window/tab in `cwd` running `command` (the
    /// non-cmux launch target). `command` is a ready-to-run shell command string
    /// (already shell-quoted by ClaudeService.launchCommand). Returns false on
    /// scripting failure.
    @discardableResult
    public static func launchInTerminal(command: String, cwd: String) -> Bool {
        // cwd single-quoted for the shell; the whole shell line then escaped for the
        // AppleScript string literal.
        let shellLine = "cd '" + cwd.replacingOccurrences(of: "'", with: "'\\''") + "' && " + command
        let escaped = shellLine
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
          activate
          do script "\(escaped)"
        end tell
        return "ok"
        """
        return runOsascript(script) == "ok"
    }

    private static func runOsascript(_ script: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return "" }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
