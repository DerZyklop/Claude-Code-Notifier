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
	/// - Parameters:
	///   - folder: The folder of the session files.
	///   - isClaude: Whether the process with the ID runs and is Claude Code.
	static func running(in folder: URL = claudeConfigDirectory.appendingPathComponent("sessions"),
		isClaude: (Int32) -> Bool = ClaudeSessionFiles.isClaudeProcess) -> [RunningSession] {
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
				isClaude(pid) else { return nil }
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

	/// The number of shell commands that run now, for each of the given Claude Code processes. Claude Code starts every
	/// shell command of a session as a direct child, with a shell snapshot from `~/.claude/shell-snapshots`. Its MCP
	/// servers are children too, but without a snapshot.
	static func shellCommandCounts(of claudePIDs: Set<Int32>) -> [Int32: Int] {
		guard !claudePIDs.isEmpty else { return [:] }
		var pids = [Int32](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
		let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size)))
		var result: [Int32: Int] = [:]
		for pid in pids.prefix(count) where pid > 0 {
			var info = proc_bsdinfo()
			let size = Int32(MemoryLayout<proc_bsdinfo>.size)
			guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
			let parent = Int32(info.pbi_ppid)
			guard claudePIDs.contains(parent), arguments(of: pid).contains("/.claude/shell-snapshots/") else { continue }
			result[parent, default: 0] += 1
		}
		return result
	}

	/// The command line of a process, with spaces between the arguments.
	static func arguments(of pid: Int32) -> String {
		var mib = [CTL_KERN, KERN_PROCARGS2, pid]
		var size = 0
		guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return "" }
		var buffer = [UInt8](repeating: 0, count: size)
		guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return "" }
		return String(decoding: buffer.prefix(size).map { $0 == 0 ? UInt8(ascii: " ") : $0 }, as: UTF8.self)
	}

	/// Whether the process runs and is Claude Code. The system can give the ID of an ended process to a new one.
	static func isClaudeProcess(_ pid: Int32) -> Bool {
		var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
		guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
		return String(cString: path).lowercased().contains("claude")
	}
}
