import Foundation
import Testing
@testable import ClaudeCodeNotifier

let overviewText = """
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

extension ReportFixture {
	/// The morning overview, with two open pull requests on Bitbucket.
	init(now: Date = tuesdayMorning, claudeOutput: String = overviewText, status: Int = 200,
		failure: @escaping @Sendable (URLRequest) -> Error? = { _ in nil }) throws {
		try self.init(kind: .morningOverview, now: now, claudeOutput: claudeOutput, body: { Self.morningBody(of: $0) }, status: status, failure: failure)
	}

	func writeFile(updated time: String) throws {
		try "# Morning overview\n\nUpdated: \(time)\n".write(to: fileURL, atomically: true, encoding: .utf8)
	}

	nonisolated static func morningBody(of request: URLRequest) -> Data {
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
		return bitbucketPage(values)
	}
}

@MainActor @Suite struct MorningOverviewDueTests {
	@Test func dueOnAWeekdayMorningWithoutAFile() throws {
		let fixture = try ReportFixture()
		defer { fixture.cleanUp() }
		#expect(fixture.report.isDue(at: tuesdayMorning))
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
		let fixture = try ReportFixture()
		defer { fixture.cleanUp() }
		#expect(fixture.report.isDue(at: tuesdayMorning.addingTimeInterval(offset)) == isDue)
	}

	@Test(arguments: [
		("2026-10-27 06:30", false),
		("2026-10-27 06:00", false),
		("2026-10-27 05:30", true), // A run before 6:00 does not count for the day.
		("2026-10-26 06:30", true),
	])
	func fileOfThisMorningIsNotDue(updated: String, isDue: Bool) throws {
		let fixture = try ReportFixture()
		defer { fixture.cleanUp() }
		try fixture.writeFile(updated: updated)
		#expect(fixture.report.isDue(at: tuesdayMorning) == isDue)
	}

	@Test func runIfDueDoesNothingWhileTheSettingIsOff() async throws {
		let fixture = try ReportFixture()
		defer { fixture.cleanUp() }
		fixture.defaults.set(false, forKey: SettingsKey.updatesMorningOverview)
		await fixture.report.runIfDue()
		#expect(fixture.log.commands.isEmpty)
	}

	@Test func runIfDueRunsOnceAndWaitsBeforeTheNextTry() async throws {
		let fixture = try ReportFixture(claudeOutput: "no overview")
		defer { fixture.cleanUp() }
		await fixture.report.runIfDue()
		#expect(fixture.claudeRun != nil)
		let commands = fixture.log.commands.count
		await fixture.report.runIfDue()
		#expect(fixture.log.commands.count == commands)
	}
}

@MainActor @Suite struct MorningOverviewUpdateTests {
	@Test func updateWritesTheFileAndPostsReady() async throws {
		let fixture = try ReportFixture()
		defer { fixture.cleanUp() }
		await fixture.report.update()
		let text = try String(contentsOf: fixture.fileURL, encoding: .utf8)
		#expect(text == Report.hashLinksAsCode(in: MorningOverview.withDailyTasks(["Zeiterfassung"], in: overviewText + "\n")))
		#expect(text.contains("[`#12`](") && !text.contains("[#"))
		#expect(fixture.report.isUnread)
		#expect(fixture.report.failure == nil)
		#expect(!fixture.report.isRunning)
		#expect(fixture.log.posts.map(\.identifier) == ["morning-overview"])
		#expect(fixture.log.posts.first?.subtitle == "Morning Overview")
		#expect(fixture.log.posts.first?.body == "3 open tasks. Click to open the file.")
		#expect(try #require(fixture.claudeRun?.arguments[4]).contains("- Daily tasks: Zeiterfassung."))
		#expect(fixture.log.removed == ["morning-overview-failed"])
	}

	@Test func claudeGetsOnlyReadTools() async throws {
		let fixture = try ReportFixture()
		defer { fixture.cleanUp() }
		await fixture.report.update()
		let run = try #require(fixture.claudeRun)
		#expect(run.arguments[0...1] == ["-lc", "exec env -u BITBUCKET_API_TOKEN -u SLACK_USER_TOKEN \"$0\" \"$@\""])
		#expect(run.timeout == 15 * 60)
		#expect(run.directory == fixture.folder)
		let arguments = Array(run.arguments.dropFirst(3))
		#expect(arguments.starts(with: ["-p"]))
		#expect(arguments[1].hasPrefix("PROMPT\n## Facts\n\n- Now: 2026-10-27 07:00\n- Project folder: "))
		for flag in ["--restricted", "--no-session-persistence"] { #expect(arguments.contains(flag)) }
		#expect(fixture.value(of: "--permission-mode") == "dontAsk")
		#expect(fixture.value(of: "--tools") == "Read,Grep,Glob,Bash")
		let start = try #require(arguments.firstIndex(of: "--allowedTools")) + 1
		let allowed = arguments[start...].prefix { !$0.hasPrefix("--") }
		let transcripts = claudeProjectFolder(of: fixture.folder.path).path
		#expect(Array(allowed) == ["Read(/\(fixture.folder.path)/**)", "Read(/\(transcripts)/**)",
			"Read(/\(MorningOverview.plansFolder.path)/**)"] + MorningOverview.jiraReadTools)
		// No MCP server from another config, and without a .mcp.json in the folder no server at all.
		#expect(arguments.contains("--strict-mcp-config"))
		#expect(fixture.value(of: "--mcp-config") == nil)
	}

	@Test func runGetsOnlyTheRemoteServersOfTheProject() async throws {
		let fixture = try ReportFixture()
		defer { fixture.cleanUp() }
		let config = #"{"mcpServers": {"jira": {"type": "http", "url": "https://x"}, "lint": {"command": "npx", "args": ["lint@latest"]}}}"#
		try config.write(to: fixture.folder.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
		await fixture.report.update()
		#expect(fixture.value(of: "--mcp-config") == #"{"mcpServers":{"jira":{"type":"http","url":"https:\/\/x"}}}"#)
	}

	@Test func withoutNetworkTheRunFailsAndClaudeDoesNotRun() async throws {
		let fixture = try ReportFixture(failure: { _ in URLError(.notConnectedToInternet) })
		defer { fixture.cleanUp() }
		await fixture.report.update()
		#expect(fixture.claudeRun == nil)
		#expect(fixture.report.failure?.hasPrefix("No connection to Bitbucket: ") == true)
		#expect(fixture.log.posts.map(\.identifier) == ["morning-overview-failed"])
		#expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
	}

	@Test func eachRequestTriesOnceMoreAfterANetworkError() async throws {
		let failed = Locked<Set<URL>>([])
		let fixture = try ReportFixture(failure: { request in
			failed.update { $0.insert(request.url!).inserted } ? URLError(.networkConnectionLost) : nil
		})
		defer { fixture.cleanUp() }
		await fixture.report.update()
		#expect(fixture.log.requests.count == 8)
		#expect(fixture.report.failure == nil)
		#expect(fixture.claudeRun != nil)
	}

	@Test func failedDetailsKeepThePullRequest() async throws {
		let fixture = try ReportFixture(failure: { $0.url!.path.hasSuffix("/tasks") ? CocoaError(.fileReadUnknown) : nil })
		defer { fixture.cleanUp() }
		await fixture.report.update()
		let pullRequests = try #require(try fixture.input["pullRequests"] as? [[String: Any]])
		#expect(pullRequests.map { $0["id"] as? Int } == [12, 13])
		#expect(pullRequests[0]["detailError"] != nil)
		#expect(pullRequests[0]["openTasks"] == nil)
	}

	@Test func inputHoldsThePullRequestsAndWorkspaces() async throws {
		let fixture = try ReportFixture()
		defer { fixture.cleanUp() }
		await fixture.report.update()
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
		let fixture = try ReportFixture()
		defer { fixture.cleanUp() }
		await fixture.report.update()
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
		let fixture = try ReportFixture(status: 401)
		defer { fixture.cleanUp() }
		await fixture.report.update()
		let input = try fixture.input
		#expect(input["pullRequests"] == nil)
		#expect(input["pullRequestError"] as? String == "Bitbucket answered with HTTP 401.")
		#expect(fixture.report.failure == nil)
	}

	@Test(arguments: [false, true])
	func outputWithoutOverviewFailsLoudly(muted: Bool) async throws {
		let fixture = try ReportFixture(claudeOutput: "I could not read the files.")
		defer { fixture.cleanUp() }
		fixture.defaults.set(muted, forKey: SettingsKey.muted)
		try fixture.writeFile(updated: "2026-10-26 06:30")
		await fixture.report.update()
		#expect(fixture.report.failure == "Claude gave no overview: I could not read the files.")
		#expect(fixture.log.posts.map(\.identifier) == ["morning-overview-failed"])
		#expect(!fixture.report.isUnread)
		// The old file stays.
		#expect(try String(contentsOf: fixture.fileURL, encoding: .utf8).contains("2026-10-26"))
	}
}

@Suite struct MorningOverviewParseTests {
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
