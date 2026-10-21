import Darwin
import Foundation
import Testing
@testable import ClaudeCodeNotifier

/// Makes a new empty folder in the temporary directory. Its name does not contain "claude".
private func makeFolder() throws -> URL {
	let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SessionFilesTests-\(UUID().uuidString)")
	try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
	return folder
}

/// The fields that a session file needs.
private func fields(pid: Int = 42) -> [String: Any] {
	["pid": pid, "sessionId": "session-\(pid)", "cwd": "/Users/me/project", "startedAt": 1_700_000_000_000]
}

private func write(_ json: Any, to folder: URL, as name: String) throws {
	try JSONSerialization.data(withJSONObject: json).write(to: folder.appendingPathComponent(name))
}

/// Starts the program as a child of the test process, with the name as its first argument and no environment. The
/// child gets `/dev/null` as standard input and output and no other open file, e.g. no socket of a parallel test.
private func start(_ path: String, as name: String, _ arguments: [String]) throws -> pid_t {
	var actions: posix_spawn_file_actions_t?
	posix_spawn_file_actions_init(&actions)
	defer { posix_spawn_file_actions_destroy(&actions) }
	for descriptor: Int32 in 0...2 {
		posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", descriptor == 0 ? O_RDONLY : O_WRONLY, 0)
	}
	var attributes: posix_spawnattr_t?
	posix_spawnattr_init(&attributes)
	defer { posix_spawnattr_destroy(&attributes) }
	posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
	let argv = ([name] + arguments).map { strdup($0) } + [nil]
	defer { argv.forEach { free($0) } }
	let environment: [UnsafeMutablePointer<CChar>?] = [nil]
	var pid: pid_t = 0
	let error = posix_spawn(&pid, path, &actions, &attributes, argv, environment)
	guard error == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EINVAL) }
	return pid
}

/// Starts `/bin/sleep 5` as a child of the test process, with the name as its first argument.
private func startSleep(as name: String) throws -> pid_t {
	try start("/bin/sleep", as: name, ["5"])
}

/// Copies `/bin/sleep` to the file and signs the copy, because macOS stops an unsigned copy of a system program.
private func copySleep(to file: URL) throws {
	try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: file)
	let codesign = try start("/usr/bin/codesign", as: "codesign", ["--force", "--sign", "-", file.path])
	var status: Int32 = 0
	waitpid(codesign, &status, 0)
	try #require(status == 0)
}

private func stop(_ pid: pid_t) {
	kill(pid, SIGKILL)
	var status: Int32 = 0
	waitpid(pid, &status, 0)
}

/// The value of `CLAUDE_CONFIG_DIR` for the test process.
private let configDirEnvironment = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]

@Suite struct ClaudeConfigDirectoryTests {
	@Test(.enabled(if: configDirEnvironment == nil))
	func withoutEnvironmentItIsTheClaudeFolderInHome() {
		#expect(claudeConfigDirectory.path == FileManager.default.homeDirectoryForCurrentUser.path + "/.claude")
	}

	@Test(.enabled(if: configDirEnvironment != nil))
	func environmentVariableWins() throws {
		let value = try #require(configDirEnvironment)
		#expect(claudeConfigDirectory.path == URL(fileURLWithPath: value).path)
	}
}

@Suite struct TranscriptPathTests {
	@Test(arguments: [
		("/Users/me/project", "-Users-me-project"),
		("/Users/me/my_project.v2", "-Users-me-my-project-v2"),
		("/Users/me/My Files 2", "-Users-me-My-Files-2"),
		("/Users/me/Gr\u{FC}\u{DF}e", "-Users-me-Gr--e"),
		("/tmp/\u{65E5}\u{672C}", "-tmp---"),
	])
	func folderName(cwd: String, folder: String) {
		let session = RunningSession(pid: 1, sessionID: "abc", cwd: cwd, started: .distantPast, state: nil, stateChanged: .distantPast)
		#expect(session.transcriptPath == claudeConfigDirectory.path + "/projects/\(folder)/abc.jsonl")
	}

	/// Claude Code replaces each UTF-16 code unit, and cuts a name longer than 200 characters and adds a hash of the
	/// working directory in base 36.
	@Test(arguments: [
		("/tmp/u\u{308}", "-tmp-u-"),
		("/tmp/\u{1F44D}", "-tmp---"),
		("/tmp/a\r\nb", "-tmp-a--b"),
		("/Users/me/" + String(repeating: "a", count: 250), "-Users-me-" + String(repeating: "a", count: 190) + "-ctfcht"),
	])
	func folderNameLikeClaudeCode(cwd: String, folder: String) {
		let session = RunningSession(pid: 1, sessionID: "abc", cwd: cwd, started: .distantPast, state: nil, stateChanged: .distantPast)
		withKnownIssue("transcriptPath replaces Characters, not UTF-16 code units, and does not cut long names") {
			#expect(session.transcriptPath == claudeConfigDirectory.path + "/projects/\(folder)/abc.jsonl")
		}
	}
}

@Suite struct RunningSessionsTests {
	@Test func missingFolderGivesNoSessions() {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)")
		#expect(ClaudeSessionFiles.running(in: folder, isClaude: { _ in true }).isEmpty)
	}

	@Test func readsAllFields() throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(at: folder) }
		try write([
			"pid": 42, "sessionId": "abc", "cwd": "/Users/me/project", "startedAt": 1_700_000_000_500,
			"status": "busy", "statusUpdatedAt": 1_700_000_060_250,
		], to: folder, as: "42.json")
		let sessions = ClaudeSessionFiles.running(in: folder, isClaude: { _ in true })
		let session = try #require(sessions.first)
		#expect(sessions.count == 1)
		#expect(session.pid == 42)
		#expect(session.sessionID == "abc")
		#expect(session.cwd == "/Users/me/project")
		#expect(session.started == Date(timeIntervalSince1970: 1_700_000_000.5))
		#expect(session.state == .working)
		#expect(session.stateChanged == Date(timeIntervalSince1970: 1_700_000_060.25))
	}

	@Test func withoutStatusTheStateIsUnknownAndChangedAtTheStart() throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(at: folder) }
		try write(fields(), to: folder, as: "42.json")
		let session = try #require(ClaudeSessionFiles.running(in: folder, isClaude: { _ in true }).first)
		#expect(session.state == nil)
		#expect(session.stateChanged == Date(timeIntervalSince1970: 1_700_000_000))
		#expect(session.stateChanged == session.started)
	}

	@Test(arguments: [
		("busy", SessionState.working),
		("waiting", .asksYou),
		("idle", .yourTurn),
		("compacting", nil),
	] as [(String, SessionState?)])
	func status(_ status: String, state: SessionState?) throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(at: folder) }
		var json = fields()
		json["status"] = status
		try write(json, to: folder, as: "42.json")
		let session = try #require(ClaudeSessionFiles.running(in: folder, isClaude: { _ in true }).first)
		#expect(session.state == state)
	}

	@Test func readsEveryFile() throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(at: folder) }
		for pid in [1, 2, 3] {
			try write(fields(pid: pid), to: folder, as: "\(pid).json")
		}
		let sessions = ClaudeSessionFiles.running(in: folder, isClaude: { _ in true })
		#expect(sessions.map(\.pid).sorted() == [1, 2, 3])
	}

	@Test func onlyJSONFilesCount() throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(at: folder) }
		try write(fields(pid: 1), to: folder, as: "1.json")
		try write(fields(pid: 2), to: folder, as: "2.txt")
		try write(fields(pid: 3), to: folder, as: "3")
		try write(fields(pid: 4), to: folder, as: "4.json.tmp")
		let sessions = ClaudeSessionFiles.running(in: folder, isClaude: { _ in true })
		#expect(sessions.map(\.pid) == [1])
	}

	@Test func brokenFileIsSkipped() throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(at: folder) }
		try write(fields(pid: 1), to: folder, as: "1.json")
		try Data("{\"pid\":".utf8).write(to: folder.appendingPathComponent("2.json"))
		try write([fields(pid: 3)], to: folder, as: "3.json")
		let sessions = ClaudeSessionFiles.running(in: folder, isClaude: { _ in true })
		#expect(sessions.map(\.pid) == [1])
	}

	@Test(arguments: ["pid", "sessionId", "cwd", "startedAt"])
	func fileWithoutFieldIsSkipped(field: String) throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(at: folder) }
		var json = fields()
		json[field] = nil
		try write(json, to: folder, as: "42.json")
		#expect(ClaudeSessionFiles.running(in: folder, isClaude: { _ in true }).isEmpty)
	}

	@Test(arguments: ["pid", "sessionId", "cwd", "startedAt"])
	func fieldOfWrongTypeIsSkipped(field: String) throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(at: folder) }
		var json = fields()
		let wrongValue: Any = json[field] is String ? 1 : "1"
		json[field] = wrongValue
		try write(json, to: folder, as: "42.json")
		#expect(ClaudeSessionFiles.running(in: folder, isClaude: { _ in true }).isEmpty)
	}

	@Test(arguments: [(true, 0), (false, 1)])
	func onlyASpareProcessIsSkipped(spare: Bool, count: Int) throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(at: folder) }
		var json = fields()
		json["spare"] = spare
		try write(json, to: folder, as: "42.json")
		#expect(ClaudeSessionFiles.running(in: folder, isClaude: { _ in true }).count == count)
	}

	@Test func fileOfAProcessThatIsNotClaudeIsSkipped() throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(at: folder) }
		try write(fields(pid: 7), to: folder, as: "7.json")
		try write(fields(pid: 8), to: folder, as: "8.json")
		let sessions = ClaudeSessionFiles.running(in: folder, isClaude: { $0 == 8 })
		#expect(sessions.map(\.pid) == [8])
	}
}

@Suite struct ShellCommandCountsTests {
	@Test func noProcessesGiveNoCounts() {
		#expect(ClaudeSessionFiles.shellCommandCounts(of: []) == [:])
	}

	@Test func missingProcessHasNoCount() {
		#expect(ClaudeSessionFiles.shellCommandCounts(of: [Int32.max]) == [:])
	}

	/// The only test that starts children with a shell snapshot, because the counts are for all children of the test process.
	@Test func onlyChildrenWithAShellSnapshotCount() throws {
		let command = try startSleep(as: "/Users/me/.claude/shell-snapshots/snapshot-zsh.sh")
		defer { stop(command) }
		let server = try startSleep(as: "mcp-server")
		defer { stop(server) }
		#expect(ClaudeSessionFiles.shellCommandCounts(of: [getpid()]) == [getpid(): 1])

		let secondCommand = try startSleep(as: "/Users/me/.claude/shell-snapshots/snapshot-bash.sh")
		defer { stop(secondCommand) }
		#expect(ClaudeSessionFiles.shellCommandCounts(of: [getpid()]) == [getpid(): 2])
		#expect(ClaudeSessionFiles.shellCommandCounts(of: [command, server]) == [:])
	}
}

@Suite struct ProcessArgumentsTests {
	@Test func ownArgumentsContainTheExecutable() throws {
		let executable = try #require(ProcessInfo.processInfo.arguments.first)
		#expect(ClaudeSessionFiles.arguments(of: getpid()).contains(executable))
	}

	@Test func argumentsAreJoinedWithSpaces() throws {
		let pid = try startSleep(as: "first-argument")
		defer { stop(pid) }
		let arguments = ClaudeSessionFiles.arguments(of: pid)
		#expect(arguments.contains("/bin/sleep"))
		#expect(arguments.contains("first-argument 5"))
	}

	@Test(arguments: [-1, Int32.max])
	func missingProcessHasNoArguments(pid: Int32) {
		#expect(ClaudeSessionFiles.arguments(of: pid) == "")
	}
}

@Suite struct IsClaudeProcessTests {
	@Test(arguments: [-1, Int32.max])
	func missingProcessIsNotClaude(pid: Int32) {
		#expect(!ClaudeSessionFiles.isClaudeProcess(pid))
	}

	@Test func launchdIsNotClaude() {
		#expect(!ClaudeSessionFiles.isClaudeProcess(1))
	}

	@Test func onlyTheExecutablePathCounts() throws {
		let pid = try startSleep(as: "claude")
		defer { stop(pid) }
		#expect(!ClaudeSessionFiles.isClaudeProcess(pid))
	}

	@Test func programWithClaudeInItsPathIsClaude() throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(at: folder) }
		let program = folder.appendingPathComponent("Claude")
		try copySleep(to: program)
		let pid = try start(program.path, as: "node", ["5"])
		defer { stop(pid) }
		#expect(ClaudeSessionFiles.isClaudeProcess(pid))
	}
}
