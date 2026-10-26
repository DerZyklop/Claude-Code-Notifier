import Foundation
import Testing
@testable import ClaudeCodeNotifier

private let overviewText = """
	# Morning overview

	Updated: 2026-10-27 07:00

	## Open PRs

	- [ ] [#12](https://bitbucket.org/ws/repo/pull-requests/12) Fix: answer 1 task.

	## Draft PRs

	Nothing open.

	## Remaining Tickets in this Sprint

	- [ ] [PROJ-1](https://x.atlassian.net/browse/PROJ-1) Do it.

	## Other Work

	Nothing open.
	"""

private let worktreeList = """
	worktree /work/repo
	HEAD abc
	branch refs/heads/main

	worktree /work/repo/.claude/worktrees/scratch
	HEAD def
	detached

	"""

/// What the fake system saw, for one test.
@MainActor
private final class Log {
	var commands: [MorningOverview.Command] = []
	var requests: [URLRequest] = []
	var posts: [(identifier: String, title: String, body: String)] = []
	var removed: [String] = []
	var opened: [URL] = []
}

/// A value that the fake requests change from other threads.
private final class Locked<Value>: @unchecked Sendable {
	private let lock = NSLock()
	private var value: Value

	init(_ value: Value) {
		self.value = value
	}

	func update<Result>(_ body: (inout Value) -> Result) -> Result {
		lock.withLock { body(&value) }
	}
}

/// A Tuesday, 7:00 in UTC.
private let tuesdayMorning = Date(timeIntervalSince1970: 1_793_084_400)

@MainActor
private struct Fixture {
	let folder: URL
	let log = Log()
	let defaults = MemoryDefaults()
	let overview: MorningOverview

	/// - Parameters:
	///   - claudeOutput: What the run prints.
	///   - status: The HTTP status of each Bitbucket answer.
	/// - Parameters:
	///   - failure: An error for a request, e.g. for a missing network.
	init(now: Date = tuesdayMorning, claudeOutput: String = overviewText, status: Int = 200,
		failure: @escaping @Sendable (URLRequest) -> Error? = { _ in nil }) throws {
		folder = FileManager.default.temporaryDirectory.appendingPathComponent("MorningOverviewTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = TimeZone(identifier: "UTC")!
		let log = log
		overview = MorningOverview(system: MorningOverview.System(
			folder: folder, dailyTasks: ["Zeiterfassung"], now: { now }, calendar: calendar, defaults: defaults,
			prompt: { "PROMPT" },
			run: { command in
				await MainActor.run { log.commands.append(command) }
				return Fixture.answer(command, claudeOutput: claudeOutput)
			},
			get: { request in
				await MainActor.run { log.requests.append(request) }
				if let error = failure(request) { throw error }
				return (Fixture.body(of: request), status)
			},
			post: { log.posts.append(($0, $1, $2)) },
			removeNotifications: { log.removed += $0 },
			open: { log.opened.append($0) }
		))
	}

	func cleanUp() {
		try? FileManager.default.removeItem(at: folder)
	}

	var fileURL: URL { folder.appendingPathComponent(MorningOverview.fileName) }

	func writeFile(updated day: String) throws {
		try "# Morning overview\n\nUpdated: \(day) 06:30\n".write(to: fileURL, atomically: true, encoding: .utf8)
	}

	/// The run of Claude Code, which gets the JSON on stdin.
	var claudeRun: MorningOverview.Command? {
		log.commands.first { $0.arguments.count > 2 && $0.arguments[2] == "claude" }
	}

	var input: [String: Any] {
		get throws {
			let data = try #require(claudeRun?.input)
			return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
		}
	}

	nonisolated static func answer(_ command: MorningOverview.Command, claudeOutput: String) -> MorningOverview.CommandResult {
		let arguments = command.arguments
		if command.executable == "/usr/bin/git" {
			let output = switch Array(arguments.dropFirst(2)) {
			case ["config", "user.name"]: "Nils\n"
			case ["remote", "get-url", "origin"]: "git@bitbucket.org:ws/repo.git\n"
			case ["worktree", "list", "--porcelain"]: worktreeList
			case ["status", "--porcelain"]: " M Sources/a.swift\n"
			default: "abc1234 Local commit\n"
			}
			return .init(status: 0, output: output, error: "")
		}
		switch arguments[2] {
		case "claude": return .init(status: 0, output: claudeOutput, error: "")
		case "/bin/sh": return .init(status: 0, output: "me@example.com:token", error: "")
		default: return .init(status: 127, output: "", error: "unknown")
		}
	}

	nonisolated static func body(of request: URLRequest) -> Data {
		let path = request.url!.path
		let values: [[String: Any]] = if path.hasSuffix("/tasks") {
			[["content": ["raw": String(repeating: "t", count: 400)], "creator": ["display_name": "Rui"]]]
		} else if path.hasSuffix("/comments") {
			[["content": ["raw": "Looks good"], "user": ["display_name": "Rui"]], ["content": ["raw": "gone"], "deleted": true]]
		} else if path.hasSuffix("/statuses") {
			[["state": "SUCCESSFUL", "name": "Pipeline #1"]]
		} else {
			[
				["id": 12, "title": "Fix", "draft": false, "author": ["display_name": "Nils"]],
				["id": 13, "title": "Other", "draft": false, "author": ["display_name": "Rui"],
					"participants": [["user": ["display_name": "Nils"], "role": "PARTICIPANT"]]],
			]
		}
		return try! JSONSerialization.data(withJSONObject: ["values": values])
	}
}

@MainActor @Suite struct MorningOverviewDueTests {
	@Test func dueOnAWeekdayMorningWithoutAFile() throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		#expect(fixture.overview.isDue(at: tuesdayMorning))
	}

	@Test(arguments: [
		(-10_800, false), // Tuesday, 4:00
		(-3_601, false), // Tuesday, 5:59:59
		(-3_600, true), // Tuesday, 6:00
		(345_600, false), // Saturday
		(432_000, false), // Sunday
		(518_400, true), // Monday
	] as [(TimeInterval, Bool)])
	func dueOnlyOnWeekdaysFromSixOn(offset: TimeInterval, isDue: Bool) throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		#expect(fixture.overview.isDue(at: tuesdayMorning.addingTimeInterval(offset)) == isDue)
	}

	@Test(arguments: [("2026-10-27", false), ("2026-10-26", true)])
	func fileOfTodayIsNotDue(day: String, isDue: Bool) throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		try fixture.writeFile(updated: day)
		#expect(fixture.overview.isDue(at: tuesdayMorning) == isDue)
	}

	@Test func runIfDueDoesNothingWhileTheSettingIsOff() async throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		fixture.defaults.set(false, forKey: SettingsKey.updatesMorningOverview)
		fixture.overview.runIfDue()
		await Task.yield()
		#expect(fixture.log.commands.isEmpty)
	}

	@Test func updatedDayReadsTheLineNearTheTop() {
		#expect(MorningOverview.updatedDay(in: overviewText) == DateComponents(year: 2026, month: 10, day: 27))
		#expect(MorningOverview.updatedDay(in: "# Morning overview\n\nUpdated: soon\n") == nil)
		#expect(MorningOverview.updatedDay(in: "# Morning overview\n") == nil)
	}
}

@MainActor @Suite struct MorningOverviewUpdateTests {
	@Test func updateWritesTheFileAndPostsReady() async throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		await fixture.overview.update()
		let text = try String(contentsOf: fixture.fileURL, encoding: .utf8)
		#expect(text == MorningOverview.withDailyTasks(["Zeiterfassung"], in: overviewText + "\n"))
		#expect(fixture.overview.isUnread)
		#expect(fixture.overview.failure == nil)
		#expect(!fixture.overview.isRunning)
		#expect(fixture.log.posts.map(\.identifier) == [MorningOverview.readyNotificationID])
		#expect(fixture.log.posts.first?.body == "3 open tasks. Click to open the file.")
		#expect(try #require(fixture.claudeRun?.arguments[4]).contains("- Daily tasks: Zeiterfassung."))
		#expect(fixture.log.removed == [MorningOverview.failedNotificationID])
	}

	@Test func claudeGetsOnlyReadTools() async throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		await fixture.overview.update()
		let run = try #require(fixture.claudeRun)
		#expect(run.arguments[0...1] == ["-lc", "exec \"$0\" \"$@\""])
		#expect(run.timeout == MorningOverview.timeout)
		#expect(run.directory == fixture.folder)
		let arguments = Array(run.arguments.dropFirst(3))
		#expect(arguments.starts(with: ["-p"]))
		#expect(arguments[1].hasPrefix("PROMPT\n## Facts"))
		for flag in ["--restricted", "--no-session-persistence"] { #expect(arguments.contains(flag)) }
		let value = { (flag: String) in arguments.firstIndex(of: flag).map { arguments[$0 + 1] } }
		#expect(value("--permission-mode") == "dontAsk")
		#expect(value("--tools") == "Read,Grep,Glob,Bash")
		let start = try #require(arguments.firstIndex(of: "--allowedTools")) + 1
		let allowed = arguments[start...].prefix { !$0.hasPrefix("--") }
		let transcripts = claudeProjectFolder(of: fixture.folder.path).path
		#expect(Array(allowed) == ["Read(/\(fixture.folder.path)/**)", "Read(/\(transcripts)/**)",
			"Read(/\(MorningOverview.plansFolder.path)/**)"] + MorningOverview.jiraReadTools)
		// No MCP server from another config, and without a .mcp.json in the folder no server at all.
		#expect(arguments.contains("--strict-mcp-config"))
		#expect(value("--mcp-config") == nil)
	}

	@Test func runGetsOnlyTheRemoteServersOfTheProject() async throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		let config = #"{"mcpServers": {"jira": {"type": "http", "url": "https://x"}, "lint": {"command": "npx", "args": ["lint@latest"]}}}"#
		try config.write(to: fixture.folder.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
		await fixture.overview.update()
		let arguments = try #require(fixture.claudeRun?.arguments)
		#expect(arguments.firstIndex(of: "--mcp-config").map { arguments[$0 + 1] } == #"{"mcpServers":{"jira":{"type":"http","url":"https:\/\/x"}}}"#)
	}

	@Test func configWithoutRemoteServersGivesNone() {
		#expect(MorningOverview.remoteServers(in: Data(#"{"mcpServers": {"lint": {"command": "npx"}}}"#.utf8)) == nil)
		#expect(MorningOverview.remoteServers(in: Data("no json".utf8)) == nil)
	}

	@Test func withoutNetworkTheRunFailsAndClaudeDoesNotRun() async throws {
		let fixture = try Fixture(failure: { _ in URLError(.notConnectedToInternet) })
		defer { fixture.cleanUp() }
		await fixture.overview.update()
		#expect(fixture.claudeRun == nil)
		#expect(fixture.overview.failure?.hasPrefix("No connection to Bitbucket: ") == true)
		#expect(fixture.log.posts.map(\.identifier) == [MorningOverview.failedNotificationID])
		#expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
	}

	@Test func eachRequestTriesOnceMoreAfterANetworkError() async throws {
		let failed = Locked<Set<URL>>([])
		let fixture = try Fixture(failure: { request in
			failed.update { $0.insert(request.url!).inserted } ? URLError(.networkConnectionLost) : nil
		})
		defer { fixture.cleanUp() }
		await fixture.overview.update()
		#expect(fixture.log.requests.count == 8)
		#expect(fixture.overview.failure == nil)
		#expect(fixture.claudeRun != nil)
	}

	@Test func failedDetailsKeepThePullRequest() async throws {
		let fixture = try Fixture(failure: { $0.url!.path.hasSuffix("/tasks") ? CocoaError(.fileReadUnknown) : nil })
		defer { fixture.cleanUp() }
		await fixture.overview.update()
		let pullRequests = try #require(try fixture.input["pullRequests"] as? [[String: Any]])
		#expect(pullRequests.map { $0["id"] as? Int } == [12, 13])
		#expect(pullRequests[0]["detailError"] != nil)
		#expect(pullRequests[0]["openTasks"] == nil)
	}

	@Test func inputHoldsThePullRequestsAndWorkspaces() async throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		await fixture.overview.update()
		let input = try fixture.input
		#expect(input["me"] as? String == "Nils")
		let pullRequests = try #require(input["pullRequests"] as? [[String: Any]])
		#expect(pullRequests.map { $0["id"] as? Int } == [12, 13])
		// Only the own PR gets details. Rui's PR names Nils as a participant, not as a reviewer.
		let tasks = try #require(pullRequests[0]["openTasks"] as? [[String: Any]])
		let task = try #require((tasks.first?["content"] as? [String: Any])?["raw"] as? String)
		#expect(task.count == 301 && task.hasSuffix("…"))
		#expect((pullRequests[0]["newestComments"] as? [Any])?.count == 1)
		#expect((pullRequests[0]["buildStatuses"] as? [[String: Any]])?.first?["state"] as? String == "SUCCESSFUL")
		#expect(pullRequests[1]["openTasks"] == nil)

		let workspaces = try #require(input["workspaces"] as? [[String: Any]])
		#expect(workspaces.map { $0["path"] as? String } == ["/work/repo", "/work/repo/.claude/worktrees/scratch"])
		#expect(workspaces.map { $0["branch"] as? String } == ["main", "detached HEAD"])
		#expect(workspaces.first?["uncommittedChanges"] as? [String] == [" M Sources/a.swift"])
		#expect(workspaces.first?["commitsOnNoRemote"] as? [String] == ["abc1234 Local commit"])
	}

	@Test func requestsAreGetsWithBasicAuthOnTheOriginRepository() async throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		await fixture.overview.update()
		let requests = fixture.log.requests
		#expect(requests.map { $0.url!.path } == ["/2.0/repositories/ws/repo/pullrequests",
			"/2.0/repositories/ws/repo/pullrequests/12/tasks", "/2.0/repositories/ws/repo/pullrequests/12/comments",
			"/2.0/repositories/ws/repo/pullrequests/12/statuses"])
		let authorization = "Basic " + Data("me@example.com:token".utf8).base64EncodedString()
		for request in requests {
			#expect(request.httpMethod == "GET")
			#expect(request.value(forHTTPHeaderField: "Authorization") == authorization)
		}
		let query = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems
		#expect(query?.first { $0.name == "q" }?.value == "state=\"UNRESOLVED\"")
		#expect(requests[1].url!.absoluteString.contains("\"") == false)
	}

	@Test func failedFetchStillRunsClaudeWithTheError() async throws {
		let fixture = try Fixture(status: 401)
		defer { fixture.cleanUp() }
		await fixture.overview.update()
		let input = try fixture.input
		#expect(input["pullRequests"] == nil)
		#expect(input["pullRequestError"] as? String == "Bitbucket answered with HTTP 401.")
		#expect(fixture.overview.failure == nil)
	}

	@Test func mutedSendsNoReadyNotification() async throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		fixture.defaults.set(true, forKey: SettingsKey.muted)
		await fixture.overview.update()
		#expect(fixture.log.posts.isEmpty)
		#expect(fixture.overview.isUnread)
	}

	@Test(arguments: [false, true])
	func outputWithoutOverviewFailsLoudly(muted: Bool) async throws {
		let fixture = try Fixture(claudeOutput: "I could not read the files.")
		defer { fixture.cleanUp() }
		fixture.defaults.set(muted, forKey: SettingsKey.muted)
		try fixture.writeFile(updated: "2026-10-26")
		await fixture.overview.update()
		#expect(fixture.overview.failure == "Claude gave no overview: I could not read the files.")
		#expect(fixture.log.posts.map(\.identifier) == [MorningOverview.failedNotificationID])
		#expect(!fixture.overview.isUnread)
		// The old file stays.
		#expect(MorningOverview.updatedDay(in: try String(contentsOf: fixture.fileURL, encoding: .utf8))?.day == 26)
	}

	@Test func openFileOpensItAndRemovesTheMark() async throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		await fixture.overview.update()
		fixture.overview.openFile()
		#expect(!fixture.overview.isUnread)
		#expect(fixture.log.opened == [fixture.fileURL])
	}
}

@Suite struct MorningOverviewParseTests {
	@Test(arguments: [
		("git@bitbucket.org:drplanoteam/drplano.git\n", "drplanoteam/drplano"),
		("https://nils@bitbucket.org/ws/repo.git", "ws/repo"),
		("https://bitbucket.org/ws/repo", "ws/repo"),
		("git@github.com:me/app.git", nil),
		("", nil),
	] as [(String, String?)])
	func bitbucketRepositoryFromTheRemote(remote: String, repository: String?) {
		#expect(MorningOverview.bitbucketRepository(remote: remote) == repository)
	}

	@Test func worktreesWithBranchOrDetached() {
		let worktrees = MorningOverview.worktrees(in: worktreeList)
		#expect(worktrees.map(\.path) == ["/work/repo", "/work/repo/.claude/worktrees/scratch"])
		#expect(worktrees.map(\.branch) == ["main", nil])
	}

	@Test(arguments: [
		(["author": ["display_name": "Nils"]], true),
		(["participants": [["user": ["display_name": "Nils"], "role": "REVIEWER"]]], true),
		(["participants": [["user": ["display_name": "Nils"], "role": "PARTICIPANT"]]], false),
		(["author": ["display_name": "Rui"]], false),
	] as [([String: Any], Bool)])
	func concernsTheAuthorAndTheReviewers(pullRequest: [String: Any], concerns: Bool) {
		#expect(MorningOverview.concerns(pullRequest, me: "Nils") == concerns)
	}

	@Test func dailyTasksComeBeforeTheFirstSection() {
		let overview = "# Morning overview\n\nUpdated: 2026-10-27 07:00\n\n## Open PRs\n\nNothing open.\n\n## Other Work\n"
		#expect(MorningOverview.withDailyTasks(["Zeiterfassung", "Mail"], in: overview)
			== "# Morning overview\n\nUpdated: 2026-10-27 07:00\n\n- [ ] Zeiterfassung\n- [ ] Mail\n\n## Open PRs\n\nNothing open.\n\n## Other Work\n")
		#expect(MorningOverview.withDailyTasks([], in: overview) == overview)
	}

	@Test(arguments: [
		(false, false, [], true),
		(true, false, [], false), // already approved
		(false, true, [], false), // draft
		(false, false, ["task"], false), // the author's turn
	] as [(Bool, Bool, [String], Bool)])
	func waitsForReviewOnlyWithoutOpenTasks(approved: Bool, draft: Bool, tasks: [String], waits: Bool) {
		let pullRequest: [String: Any] = ["draft": draft, "openTasks": tasks,
			"participants": [["user": ["display_name": "Nils"], "role": "REVIEWER", "approved": approved]]]
		#expect(MorningOverview.waitsForReview(pullRequest, me: "Nils") == waits)
		#expect(!MorningOverview.waitsForReview(pullRequest, me: "Rui"))
	}

	@Test func overviewNeedsTheTitleAndTheDate() {
		#expect(MorningOverview.overview(in: "\n\(overviewText)\n\n") == overviewText + "\n")
		#expect(MorningOverview.overview(in: "Here it is:\n```markdown\n\(overviewText)\n```\n") == overviewText + "\n")
		#expect(MorningOverview.overview(in: "Text about the # Morning overview and \(overviewText)") == nil)
		#expect(MorningOverview.overview(in: "# Morning overview\n\n## Open PRs\n") == nil)
	}
}

@Suite struct MorningOverviewExecuteTests {
	private func command(_ executable: String, _ arguments: [String], input: String = "", timeout: TimeInterval = 5) -> MorningOverview.Command {
		MorningOverview.Command(executable: executable, arguments: arguments, directory: FileManager.default.temporaryDirectory,
			input: Data(input.utf8), timeout: timeout)
	}

	@Test func passesTheInputAndReadsBothStreams() async {
		let result = await MorningOverview.execute(command("/bin/sh", ["-c", "cat; echo oops >&2; exit 3"], input: "hello"))
		#expect(result.output == "hello")
		#expect(result.error == "oops\n")
		#expect(result.status == 3)
		#expect(!result.timedOut)
	}

	@Test func loginShellFormRunsTheProgramWithItsArguments() async {
		let result = await MorningOverview.execute(command("/bin/sh", ["-c", "exec \"$0\" \"$@\"", "/bin/echo", "a b", "c"]))
		#expect(result.output == "a b c\n")
	}

	@Test func endsTheProgramAfterTheTimeout() async {
		let result = await MorningOverview.execute(command("/bin/sleep", ["5"], timeout: 0.2))
		#expect(result.timedOut)
	}

	@Test func childGetsOnlyTheBasicVariables() {
		let environment = ["HOME": "/Users/me", "PATH": "/usr/bin", "CLAUDECODE": "1", "NODE_USE_ENV_PROXY": "1", "LANG": "en_US.UTF-8"]
		#expect(MorningOverview.childEnvironment(of: environment) == ["HOME": "/Users/me", "PATH": "/usr/bin", "LANG": "en_US.UTF-8"])
	}

	@Test func missingProgramGivesStatus127() async {
		let result = await MorningOverview.execute(command("/no/such/program", []))
		#expect(result.status == 127)
	}
}
