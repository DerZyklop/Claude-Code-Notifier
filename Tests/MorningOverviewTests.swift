import Foundation
import Testing
@testable import ClaudeCodeNotifier

let overviewText = """
	# Morning overview

	Updated: 2026-10-27 07:00

	## Their Open PRs

	Nothing open.

	## My Open PRs

	- [ ] [#12](https://bitbucket.org/ws/repo/pull-requests/12) Fix: answer 1 task.

	## Draft PRs

	Nothing open.

	## Remaining Tickets in this Sprint

	- [ ] [PROJ-1](https://x.atlassian.net/browse/PROJ-1) Do it.

	## Optional Work

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
		} else if path.hasSuffix("/diffstat") {
			[["status": "modified"], ["status": "merge conflict"]]
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

	@Test func runIfDueSkipsTheDueMomentOfAStoppedRun() async throws {
		let fixture = try ReportFixture()
		defer { fixture.cleanUp() }
		let shared = Locked<Report?>(nil)
		var system = fixture.report.system
		let run = system.run
		system.run = { command in
			guard command.isClaudeRun else { return await run(command) }
			await MainActor.run { shared.update { $0 }?.stop() }
			return .init(status: 143, output: "", error: "")
		}
		let stopped = Report(kind: .morningOverview, system: system)
		shared.update { $0 = stopped }
		await stopped.update()
		// A new report has no wait from an earlier try, as after a restart.
		let next = Report(kind: .morningOverview, system: fixture.report.system)
		let commands = fixture.log.commands.count
		await next.runIfDue()
		#expect(fixture.log.commands.count == commands)
		#expect(next.isDue(at: tuesdayMorning))
	}
}

@MainActor @Suite struct MorningOverviewUpdateTests {
	@Test func updateWritesTheFileAndPostsReady() async throws {
		let fixture = try ReportFixture()
		defer { fixture.cleanUp() }
		await fixture.report.update()
		let text = try String(contentsOf: fixture.fileURL, encoding: .utf8)
		#expect(text == MorningOverview.withKeptSections(from: "", keepingTicks: false,
			in: Report.hashLinksAsCode(in: MorningOverview.numbered(overviewText + "\n"))))
		#expect(text.contains("Updated: 2026-10-27 07:00\n\n## My Notes\n\n## Daily\n\n## 0 × Their Open PRs\n"))
		#expect(text.contains("- [ ] `M1` [`#12`]("))
		#expect(text.contains("## 0 × Their Open PRs\n") && text.contains("## 1 × My Open PRs\n") && text.contains("## 0 × Draft PRs\n"))
		#expect(text.contains("[`#12`](") && !text.contains("[#"))
		#expect(fixture.report.isUnread)
		#expect(fixture.report.failure == nil)
		#expect(!fixture.report.isRunning)
		#expect(fixture.log.posts.map(\.identifier) == ["morning-overview"])
		#expect(fixture.log.posts.first?.subtitle == "Morning Overview")
		#expect(fixture.log.posts.first?.body == "2 open tasks. Click to open the file.")
		#expect(!(try #require(fixture.claudeRun?.arguments[4]).contains("Weekday tasks")))
		#expect(fixture.log.removed == ["morning-overview-failed"])
	}

	@Test func mondayAddsTheTasksOfMonday() async throws {
		let fixture = try ReportFixture(now: tuesdayMorning.addingTimeInterval(-24 * 60 * 60))
		defer { fixture.cleanUp() }
		await fixture.report.update()
		let text = try String(contentsOf: fixture.fileURL, encoding: .utf8)
		#expect(text.contains("Updated: 2026-10-27 07:00\n\n- [ ] Reflect\n\n## My Notes\n"))
		#expect(try #require(fixture.claudeRun?.arguments[4]).contains("- Weekday tasks: Reflect."))
	}

	@Test func updateKeepsMyNotesAndUnticksDailyOnANewDay() async throws {
		let fixture = try ReportFixture()
		defer { fixture.cleanUp() }
		let notes = "## My Notes\n\nAsk [#7](https://x) about it.\n- [x] Keep\n    - [ ] this\n"
		let daily = "## Daily\n\n- [x] Mail\n    - [X] Inbox\n- [ ] Slack\n"
		try "# Morning overview\n\nUpdated: 2026-10-26 07:00\n\n\(daily)\n## 1 × Optional Work\n\n- [ ] `O1` Old\n\n\(notes)"
			.write(to: fixture.fileURL, atomically: true, encoding: .utf8)
		await fixture.report.update()
		let text = try String(contentsOf: fixture.fileURL, encoding: .utf8)
		#expect(text.contains("Updated: 2026-10-27 07:00\n\n\(notes)\n## Daily\n\n- [ ] Mail\n    - [ ] Inbox\n- [ ] Slack\n\n## 0 × Their"))
		#expect(try #require(fixture.claudeRun?.arguments[4]).contains("»My Notes«, »Daily« and »Notifier App«"))
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
		#expect(fixture.log.requests.count == 10)
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
		#expect(pullRequests[0]["hasMergeConflict"] as? Bool == true)
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
			"/2.0/repositories/ws/repo/pullrequests/12/statuses", "/2.0/repositories/ws/repo/pullrequests/12/diffstat"])
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
		#expect(fixture.log.ready == 0)
		// The old file stays.
		#expect(try String(contentsOf: fixture.fileURL, encoding: .utf8).contains("2026-10-26"))
	}
}

@Suite struct MorningOverviewParseTests {
	@Test func branchesWithUpstreamTrackAndSubject() {
		let output = "feature/a\torigin/feature/a\t[ahead 2]\t2026-10-26\tFix it\nlocal-only\t\t\t2026-10-20\tTry\tthis\nbroken line\n"
		let branches = MorningOverview.branches(in: output)
		#expect(branches.map { $0["name"] as? String } == ["feature/a", "local-only"])
		#expect(branches[0]["upstream"] as? String == "origin/feature/a")
		#expect(branches[0]["track"] as? String == "[ahead 2]")
		#expect(branches[1]["upstream"] == nil && branches[1]["track"] == nil)
		#expect(branches[1]["subject"] as? String == "Try\tthis")
		#expect(branches[1]["lastCommit"] as? String == "2026-10-20")
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

	@Test(arguments: [
		(["draft": true, "author": ["display_name": "Rui"]], true),
		(["draft": true, "author": ["display_name": "Nils"]], false),
		(["draft": false, "author": ["display_name": "Rui"]], false),
	] as [([String: Any], Bool)])
	func onlyDraftsOfOthersGetRemoved(pullRequest: [String: Any], removed: Bool) {
		#expect(MorningOverview.isDraftOfOthers(pullRequest, me: "Nils") == removed)
	}

	@Test func subItemsGetFourSpaces() {
		#expect(MorningOverview.subItemsIndented(in: "- [ ] Title\n  - Do it.\n    - Done.\n- [ ] Next\n")
			== "- [ ] Title\n    - Do it.\n    - Done.\n- [ ] Next\n")
	}

	@Test func sectionHeadingsCountTheirTasks() {
		let overview = """
			# Morning overview

			- [ ] Reflect

			## My Open PRs

			- [ ] [#1](https://x) First
			    - [ ] A next action
			- [ ] [#2](https://x) Second

			## 7 × Draft PRs

			Nothing open.
			"""
		#expect(MorningOverview.withSectionCounts(in: overview) == """
			# Morning overview

			- [ ] Reflect

			## 2 × My Open PRs

			- [ ] [#1](https://x) First
			    - [ ] A next action
			- [ ] [#2](https://x) Second

			## 0 × Draft PRs

			Nothing open.
			""")
	}

	@MainActor @Test func keeperCountsAgainAfterAChangeOnlyOnceTheFileIsQuiet() throws {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeCodeNotifierTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		let file = folder.appendingPathComponent("overview.md")
		let keeper = SectionCountKeeper(fileURL: file)
		try "## 2 × My Open PRs\n\n- [ ] One\n- [ ] Two\n".write(to: file, atomically: true, encoding: .utf8)
		keeper.check()

		// The user ticks a task. The first check sees the change, and the next one counts.
		try "## 2 × My Open PRs\n\n- [x] One\n- [ ] Two\n".write(to: file, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
		keeper.check()
		#expect(try String(contentsOf: file, encoding: .utf8).hasPrefix("## 2 × "))
		keeper.check()
		#expect(try String(contentsOf: file, encoding: .utf8) == "## 1 × My Open PRs\n\n- [x] `M1` One\n- [ ] `M2` Two\n")
	}

	@Test func tasksGetSectionIDsAndStepsGetLetters() {
		let overview = """
			- [ ] Reflect

			## 9 × My Open PRs

			- [x] [`#1`](https://x) First
			    - [x] Review it
			    - `M1c` The pipeline is green.
			    - [ ] `Z9z` Approve it
			- [ ] `P7` Second

			## Open Branches

			- [ ] `feature/a` Old idea

			## Ideas

			Nothing open.
			- [ ] New
			"""
		#expect(MorningOverview.withTaskIDs(in: overview) == """
			- [ ] Reflect

			## 9 × My Open PRs

			- [x] `M1` [`#1`](https://x) First
			    - [x] `M1a` Review it
			    - The pipeline is green.
			    - [ ] `M1b` Approve it
			- [ ] `M2` Second

			## Open Branches

			- [ ] `B1` `feature/a` Old idea

			## Ideas

			Nothing open.
			- [ ] `I1` New
			""")
	}

	@Test func plansGetTheFactsThatTheAppFinds() throws {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		let now = tuesdayMorning
		let day: TimeInterval = 24 * 60 * 60
		let texts = [
			"plan-proj-7-new.md": "Fix `feature/PROJ-1-a` and `feature/gone-b`, see #42 and UTF-8.\n- [x] One\n  - [ ] Two\n",
			"old.md": "Uses `bugfix/PROJ-2-c`.\n",
			"notes.txt": "x",
		]
		for (name, text) in texts {
			let file = folder.appendingPathComponent(name)
			try text.write(to: file, atomically: true, encoding: .utf8)
			try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval((name == "old.md" ? -20 : -0.5) * day)], ofItemAtPath: file.path)
		}
		let old = "# Morning overview\n\nUpdated: \(Report.timestampFormatter(utcCalendar).string(from: now.addingTimeInterval(-day)))\n\n"
			+ "## 1 × Cleanup Work\n\n- [ ] `C1` Delete [old.md](file:///old.md)\n"
		let branches: [[String: Any]] = [["name": "feature/PROJ-1-a", "mergedInto": ["origin/dev"]]]
		let pullRequests: [[String: Any]] = [["id": 42, "title": "PROJ-1 A"], ["id": 43, "source": ["branch": ["name": "bugfix/PROJ-2-c"]]]]
		let plans = MorningOverview.plans(in: folder, old: old, now: now, calendar: utcCalendar, branches: branches,
			knownBranches: ["feature/PROJ-1-a", "bugfix/PROJ-2-c"], pullRequests: pullRequests)
		#expect(plans.map { $0["name"] as? String } == ["old.md", "plan-proj-7-new.md"])
		let (oldPlan, newPlan) = (plans[0], plans[1])
		#expect(oldPlan["recent"] as? Bool == false)
		#expect(oldPlan["changedAfterOldOverview"] as? Bool == false)
		#expect(oldPlan["oldSections"] as? [String] == ["Cleanup Work"])
		#expect(oldPlan["openPullRequests"] as? [Int] == [43])
		#expect(newPlan["recent"] as? Bool == true)
		#expect(newPlan["changedAfterOldOverview"] as? Bool == true)
		#expect(newPlan["oldSections"] as? [String] == [])
		#expect(newPlan["tickets"] as? [String] == ["PROJ-1", "PROJ-7"])
		#expect((newPlan["branches"] as? [[String: Any]])?.first?["mergedInto"] as? [String] == ["origin/dev"])
		#expect(newPlan["unknownBranches"] as? [String] == ["feature/gone-b"])
		#expect(newPlan["openPullRequests"] as? [Int] == [42])
		#expect(newPlan["openSteps"] as? Int == 1)
		#expect(newPlan["doneSteps"] as? Int == 1)
		#expect(MorningOverview.plans(in: folder, old: nil, now: now, calendar: utcCalendar, branches: [], knownBranches: [], pullRequests: [])
			.allSatisfy { $0["changedAfterOldOverview"] == nil })
	}

	@Test func eachSectionGetsItsOwnLetter() {
		let overview = """
			## Reviews

			- [ ] A

			## Ideas

			- [ ] B

			## Issues

			- [ ] C

			## 2026

			- [ ] D

			## Ideas

			- [ ] E

			## Daily

			- [ ] F

			## Their Open PRs

			- [ ] G
			"""
		#expect(MorningOverview.letters(in: overview) == ["E", "I", "S", "A", nil, nil, "R"])
		#expect(MorningOverview.withTaskIDs(in: overview).contains("## 2026\n\n- [ ] `A1` D\n\n## Ideas\n\n- [ ] E\n"))
	}

	@Test func weekdayTasksComeBeforeTheFirstSection() {
		let overview = "# Morning overview\n\nUpdated: 2026-10-27 07:00\n\n## My Open PRs\n\nNothing open.\n\n## Optional Work\n"
		#expect(MorningOverview.withWeekdayTasks(["Reflect", "Mail"], in: overview)
			== "# Morning overview\n\nUpdated: 2026-10-27 07:00\n\n- [ ] Reflect\n- [ ] Mail\n\n## My Open PRs\n\nNothing open.\n\n## Optional Work\n")
		#expect(MorningOverview.withWeekdayTasks([], in: overview) == overview)
		#expect(MorningOverview.withWeekdayTasks(["Reflect", "Mail"], done: ["Mail"], in: overview)
			.contains("- [ ] Reflect\n- [x] Mail\n\n## "))
	}

	@Test func weekdayTasksKeepTheirTickOnTheSameDay() {
		let old = "# Morning overview\n\nUpdated: 2026-10-27 06:00\n\n- [x] Reflect\n- [ ] Mail\n\n## Optional Work\n\n- [x] `O1` Done\n"
		#expect(MorningOverview.doneWeekdayTasks(in: old) == ["Reflect"])
		#expect(MorningOverview.isSameDay(old, now: tuesdayMorning, calendar: utcCalendar))
		#expect(!MorningOverview.isSameDay(old, now: tuesdayMorning.addingTimeInterval(24 * 60 * 60), calendar: utcCalendar))
	}

	@Test func keptSectionsReplaceTheOnesOfClaude() {
		let old = "# Morning overview\n\nUpdated: 2026-10-27 06:00\n\n## Daily\n\n- [x] Mail\n\n## Optional Work\n"
		let overview = MorningOverview.withoutAppSections("# Morning overview\n\n## My Notes\n\nNew\n\n## Optional Work\n\n## Daily\n\n- [ ] X\n\n## Notifier App\n\n- Y\n")
		#expect(overview == "# Morning overview\n\n## Optional Work\n")
		#expect(MorningOverview.withKeptSections(from: old, keepingTicks: true, in: overview)
			== "# Morning overview\n\n## My Notes\n\n## Daily\n\n- [x] Mail\n\n## Optional Work\n")
	}

	@Test func keptSectionsWithACountInTheHeadingKeepTheirText() {
		let old = "# Morning overview\n\n## 2 × My Notes\n(Mine)\n\n- [ ] `M1` Note\n\n## 0 × Daily\n- [x] `D1` Mail\n\n## 0 × Optional Work\n"
		#expect(MorningOverview.withKeptSections(from: old, keepingTicks: true, in: "# Morning overview\n\n## Optional Work\n")
			== "# Morning overview\n\n## My Notes\n(Mine)\n\n- [ ] `M1` Note\n\n## Daily\n- [x] `D1` Mail\n\n## Optional Work\n")
		#expect(MorningOverview.numbered("## 2 × My Notes\n\n- [ ] Note\n") == "## 2 × My Notes\n\n- [ ] Note\n")
	}

	@Test func cleanupWorkComesBelowMyNotes() {
		let old = "# Morning overview\n\n## My Notes\n\nNote\n\n## Daily\n\n- [ ] Mail\n"
		let overview = "# Morning overview\n\n## 0 × My Open PRs\n\nNothing open.\n\n## 1 × Cleanup Work\n\n- [ ] `C1` Delete\n\n## 0 × Optional Work\n"
		#expect(MorningOverview.withKeptSections(from: old, keepingTicks: true, in: overview)
			== "# Morning overview\n\n## My Notes\n\nNote\n\n## 1 × Cleanup Work\n\n- [ ] `C1` Delete\n\n## Daily\n\n- [ ] Mail\n\n"
			+ "## 0 × My Open PRs\n\nNothing open.\n\n## 0 × Optional Work\n")
	}

	@Test func appSectionsGetNoIDsAndNoCounts() {
		let overview = "## My Notes\n\n- [ ] Note\n\n## Daily\n\n- [ ] Mail\n\n## Optional Work\n\n- [ ] Work\n\n## Notifier App\n\n- [a](file:///a.md)\n"
		#expect(MorningOverview.numbered(overview)
			== "## My Notes\n\n- [ ] Note\n\n## Daily\n\n- [ ] Mail\n\n## 1 × Optional Work\n\n- [ ] `O1` Work\n\n## Notifier App\n\n- [a](file:///a.md)\n")
	}

	@MainActor @Test func notifierAppSectionLinksThePlansAtTheEnd() async throws {
		let fixture = try ReportFixture()
		defer { fixture.cleanUp() }
		let plans = fixture.folder.appendingPathComponent("notifier plans")
		try FileManager.default.createDirectory(at: plans, withIntermediateDirectories: true)
		for name in ["b.md", "a plan.md", "README.md", "notes.txt"] { try "x".write(to: plans.appendingPathComponent(name), atomically: true, encoding: .utf8) }
		var system = fixture.report.system
		system.notifierPlansFolder = plans
		await Report(kind: .morningOverview, system: system).update()
		let text = try String(contentsOf: fixture.fileURL, encoding: .utf8)
		let link = plans.appendingPathComponent("a plan.md").absoluteString
		#expect(link.contains("%20"))
		#expect(text.hasSuffix("Nothing open.\n\n## Notifier App\n\n- [a plan](\(link))\n- [b](\(plans.appendingPathComponent("b.md").absoluteString))\n"))
		#expect(MorningOverview.notifierSection(plansIn: fixture.folder.appendingPathComponent("missing")) == nil)
		try FileManager.default.removeItem(at: plans)
		try FileManager.default.createDirectory(at: plans, withIntermediateDirectories: true)
		#expect(MorningOverview.notifierSection(plansIn: plans) == "\n## Notifier App\n\nNo plans.\n")
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
		#expect(MorningOverview.overview(in: "# Morning overview\n\n## My Open PRs\n") == nil)
	}
}
