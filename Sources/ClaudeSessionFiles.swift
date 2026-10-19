import Darwin
import Foundation

/// A running Claude Code session, from its file in `~/.claude/sessions`. Claude Code writes one file per process,
/// named after the process ID, and keeps its status up to date.
struct RunningSession {
	let pid: Int32
	let sessionID: String
	let cwd: String
	let started: Date
	/// `nil` for a status this app does not know.
	let state: SessionState?
	let stateChanged: Date

	/// Where Claude Code keeps the transcript: the folder name is the working directory with every character that is
	/// not a letter or digit replaced by `-`.
	var transcriptPath: String {
		let folder = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
		return claudeConfigDirectory.appendingPathComponent("projects/\(folder)/\(sessionID).jsonl").path
	}
}

/// The Claude Code configuration folder. Like Claude Code, it honors `CLAUDE_CONFIG_DIR`.
let claudeConfigDirectory: URL = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
	?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")

enum ClaudeSessionFiles {
	/// The sessions whose Claude Code process runs. A file stays behind when a process crashes, so each one is checked.
	static func running() -> [RunningSession] {
		let folder = claudeConfigDirectory.appendingPathComponent("sessions")
		guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
		return files.filter { $0.pathExtension == "json" }.compactMap { file in
			guard let data = try? Data(contentsOf: file),
				let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
				let pid = (json["pid"] as? NSNumber)?.int32Value,
				let sessionID = json["sessionId"] as? String,
				let cwd = json["cwd"] as? String,
				let startedAt = (json["startedAt"] as? NSNumber)?.doubleValue,
				// A spare process waits for a session that does not exist yet.
				json["spare"] as? Bool != true,
				isClaudeProcess(pid) else { return nil }
			let state: SessionState? = switch json["status"] as? String {
			case "busy": .working
			case "waiting": .asksYou
			case "idle": .yourTurn
			default: nil
			}
			let changed = (json["statusUpdatedAt"] as? NSNumber)?.doubleValue ?? startedAt
			return RunningSession(pid: pid, sessionID: sessionID, cwd: cwd, started: Date(timeIntervalSince1970: startedAt / 1000),
				state: state, stateChanged: Date(timeIntervalSince1970: changed / 1000))
		}
	}

	/// Whether the process runs and is Claude Code. The system can give the ID of an ended process to a new one.
	static func isClaudeProcess(_ pid: Int32) -> Bool {
		var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
		guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
		return String(cString: path).lowercased().contains("claude")
	}
}
