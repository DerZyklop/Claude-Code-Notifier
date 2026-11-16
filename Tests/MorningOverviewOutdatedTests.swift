import Foundation
import Testing
@testable import ClaudeCodeNotifier

/// The facts of a file as ``MorningOverview/plans(of:old:now:calendar:branches:knownBranches:pullRequests:branchDates:changedPullRequests:closedPullRequests:changeDate:)``
/// gives them, with no outdated fact.
private func facts(_ path: String, _ extra: [String: Any] = [:]) -> [String: Any] {
	var facts: [String: Any] = ["name": (path as NSString).lastPathComponent, "url": "file:///p/\(path)", "oldSections": [String](),
		"tickets": [String](), "branches": [[String: Any]](), "unknownBranches": [String](), "openPullRequests": [Int](), "openSteps": 1,
		"doneSteps": 0, "changedAfterOldOverview": false, "newCommits": false, "changedOn": "2026-10-20"]
	facts.merge(extra) { $1 }
	return facts
}

/// The facts of a file whose branch is gone.
private func gone(_ path: String, _ extra: [String: Any] = [:]) -> [String: Any] {
	facts(path, ["unknownBranches": ["feature/x"]].merging(extra) { $1 })
}

/// The files of `files` that get `checkFindings`, by name.
private func checked(_ files: [[String: Any]]) -> [String] {
	files.filter { $0["checkFindings"] as? Bool == true }.compactMap { $0["name"] as? String }
}

@Suite struct MorningOverviewOutdatedTests {
	@Test func eachFactGivesItsReason() {
		let tickets: [String: [String: Any]] = ["PROJ-1": ["done": true, "status": "Closed"], "PROJ-2": ["done": false]]
		let states = [41: "DECLINED", 42: "MERGED", 43: "SUPERSEDED"]
		let reason = { (facts: [String: Any]) in MorningOverview.outdatedReason(of: facts, jiraTickets: tickets, closedStates: states) }
		#expect(reason(facts("reviews/41-a.md")).map { [$0.text, "\($0.declined)"] } == ["#41 was declined", "true"])
		#expect(reason(facts("reviews/42-a.md")).map { [$0.text, "\($0.declined)"] } == ["#42 is merged", "false"])
		// The code of a superseded PR can reach `dev` in the PR that replaces it, so Claude checks it.
		#expect(reason(facts("reviews/43-a.md")).map { [$0.text, "\($0.declined)"] } == ["#43 was superseded", "false"])
		#expect(reason(facts("a.md", ["tickets": ["PROJ-2", "PROJ-1"]]))?.text == "PROJ-1 is »Closed«")
		#expect(reason(facts("a.md", ["branches": [["name": "feature/a", "mergedInto": ["origin/dev"]]]]))?.text
			== "`feature/a` is merged into `origin/dev`")
		#expect(reason(gone("a.md"))?.text == "the branch `feature/x` is gone")
		#expect(reason(facts("a.md", ["openSteps": 0, "doneSteps": 3]))?.text == "all its steps are done")
		// An open PR wins over each fact. A number outside a `reviews` folder is no review PR.
		#expect(reason(facts("reviews/41-a.md", ["openPullRequests": [7]])) == nil)
		#expect(reason(facts("notes/41-a.md")) == nil)
		#expect(reason(facts("a.md", ["openSteps": 0, "doneSteps": 0])) == nil)
		#expect(reason(facts("a.md", ["tickets": ["PROJ-2"]])) == nil)
	}

	@Test func eachOutdatedFileGetsItsCheckOrTask() {
		let files = [facts("reviews/41-declined.md"), facts("reviews/42-merged.md"), gone("gone.md"), facts("fresh.md")]
		let result = MorningOverview.withOutdatedCheck(files, old: nil, last: nil, jiraTickets: [:],
			closedStates: [41: "DECLINED", 42: "MERGED"])
		#expect(result.files.map { $0["checkFindings"] as? Bool } == [nil, true, true, nil])
		#expect(result.files.map { $0["outdated"] as? String } == [nil, "#42 is merged", "the branch `feature/x` is gone", nil])
		#expect(result.files.map { $0["appTask"] as? Bool } == [true, nil, nil, nil])
		#expect(result.deleteTasks == [MorningOverview.DeleteTask(url: "file:///p/reviews/41-declined.md",
			line: "- [ ] Delete [41-declined.md](file:///p/reviews/41-declined.md), because #41 was declined.")])
		#expect(result.run.outdated == ["file:///p/reviews/41-declined.md", "file:///p/reviews/42-merged.md", "file:///p/gone.md"])
		// The run does not get the facts that only the check needs.
		#expect(result.files.allSatisfy { file in MorningOverview.outdatedCheckFields.allSatisfy { file[$0] == nil } })
		#expect(result.files.allSatisfy { $0["changedAfterOldOverview"] != nil && $0["url"] != nil })
	}

	@Test func anOpenOldTaskMarksAFileAsChecked() {
		let old = """
			# Morning overview

			## 3 × Optional Work

			- [ ] `O1` Solve the open findings of [solve.md](file:///p/solve.md)
			    - [ ] `O1a` Fix the loop.
			- [ ] `O2` Outdated reviews of gone branches
			    - [ ] `O2a` Check `reviews/bundle.md` against `origin/dev`.
			- [ ] `O3` Solve the open findings of [fixed.md](file:///p/fixed.md)
			    - [x] `O3a` Fix the loop.
			- [ ] `O4` Plan [refactor-plan.md](file:///p/refactor-plan.md)

			## 1 × Cleanup Work

			- [ ] `C1` Delete [cleanup.md](file:///p/cleanup.md), because PROJ-1 is »Done«.
			- [x] `C2` Delete [ticked.md](file:///p/ticked.md), because PROJ-1 is »Done«.
			"""
		let files = [gone("solve.md"), gone("reviews/bundle.md"), gone("fixed.md"), gone("plan.md"), gone("cleanup.md"), gone("ticked.md"),
			gone("changed.md", ["changedAfterOldOverview": true]), gone("cleanup.md", ["url": "file:///p/cleanup.md", "newCommits": true])]
		let check = { (last: MorningOverview.OutdatedState?) in
			checked(MorningOverview.withOutdatedCheck(files, old: old, last: last, jiraTickets: [:], closedStates: [:]).files)
		}
		// A done task, a ticked task and a similar name do not count. An open task in »Cleanup Work« counts also after a change.
		#expect(check(nil) == ["fixed.md", "plan.md", "ticked.md", "changed.md"])
		// A file that was not outdated at the last run needs a check, also with an open task in »Optional Work«.
		#expect(check(.init()) == ["solve.md", "bundle.md", "fixed.md", "plan.md", "ticked.md"])
		let all = Set(files.compactMap { $0["url"] as? String })
		#expect(check(.init(outdated: all)) == ["fixed.md", "plan.md", "ticked.md", "changed.md"])
		// Without an old overview, no old task covers a file.
		#expect(checked(MorningOverview.withOutdatedCheck(files, old: nil, last: .init(outdated: all), jiraTickets: [:], closedStates: [:]).files).count == 5)
	}

	@Test func aRunChecksOnlyTheNewestFiles() {
		let files = (1...7).map { gone("f\($0).md", ["changedOn": "2026-10-0\($0)"]) }
		let result = MorningOverview.withOutdatedCheck(files, old: nil, last: nil, jiraTickets: [:], closedStates: [:])
		#expect(checked(result.files) == ["f3.md", "f4.md", "f5.md", "f6.md", "f7.md"])
		// The 2 waiting files are not saved, so that the next run checks them. Claude still sees that they are outdated.
		#expect(result.run.outdated == Set((3...7).map { "file:///p/f\($0).md" }))
		#expect(result.files.allSatisfy { $0["outdated"] as? String == "the branch `feature/x` is gone" })
		#expect(result.run.checked.map(\.name) == ["f7.md", "f6.md", "f5.md", "f4.md", "f3.md"])
	}

	@Test func anIgnoredFileWaitsUntilItChanges() {
		let url = "file:///p/other.md"
		let last = MorningOverview.OutdatedState(outdated: [url], ignored: [url])
		let quiet = MorningOverview.withOutdatedCheck([gone("other.md")], old: nil, last: last, jiraTickets: [:], closedStates: [:])
		#expect(checked(quiet.files) == [])
		#expect(quiet.run == MorningOverview.OutdatedRun(outdated: [url], ignored: [url]))
		let changed = MorningOverview.withOutdatedCheck([gone("other.md", ["changedAfterOldOverview": true])], old: nil, last: last,
			jiraTickets: [:], closedStates: [:])
		#expect(checked(changed.files) == ["other.md"])
		#expect(changed.run.ignored == [])
	}

	@Test func aCheckedFileThatNoTaskNamesIsIgnored() {
		let run = MorningOverview.OutdatedRun(outdated: ["file:///p/a.md", "file:///p/b.md", "file:///p/c.md"], ignored: ["file:///p/old.md"],
			checked: [("file:///p/a.md", "a.md"), ("file:///p/b.md", "b.md"), ("file:///p/c.md", "c.md")])
		let written = "## Optional Work\n\n- [ ] Solve the open findings of [b.md](file:///p/b.md)\n- [ ] Check `reviews/c.md`.\n"
		#expect(run.state(written: written) == MorningOverview.OutdatedState(outdated: run.outdated, ignored: ["file:///p/old.md", "file:///p/a.md"]))
	}

	@Test func aDoneTicketDoesNotStopTheKeepOfACheckedFile() {
		let old = """
			# Morning overview

			Updated: 2026-10-27 07:00

			## Optional Work

			- [ ] `O1` [PROJ-5](https://x/browse/PROJ-5) Solve the open findings of [a.md](file:///p/a.md)
			    - [ ] `O1a` Fix the loop.
			"""
		let tickets: [String: [String: Any]] = ["PROJ-5": ["done": true]]
		let settled = facts("a.md", ["outdated": "PROJ-5 is »Done«"])
		#expect(MorningOverview.unchangedTasks(in: old, files: [settled], changedPullRequests: [], tickets: tickets) == ["O1"])
		#expect(MorningOverview.unchangedTasks(in: old, files: [facts("a.md")], changedPullRequests: [], tickets: tickets) == [])
		#expect(MorningOverview.unchangedTasks(in: old, files: [settled.merging(["checkFindings": true]) { $1 }], changedPullRequests: [],
			tickets: tickets) == [])
	}

	@Test func aFailedTicketRequestMarksTheTicketsAsIncomplete() async {
		let failing = Jira(api: URL(string: "https://api.example/rest/api/3")!, browseURL: "https://x/browse/", authorization: "Basic x") { _ in
			(Data(), 500)
		}
		let search = MorningOverview.JiraSearch(browseURL: nil, result: .success((jira: failing, sprint: [], forgotten: [])))
		let data = await MorningOverview.jiraData(search, texts: ["PROJ-1"], projectKeys: ["PROJ"])
		#expect(data[MorningOverview.ticketsIncompleteKey] as? Bool == true)
		#expect(data["error"] == nil)
		let none = await MorningOverview.jiraData(search, texts: [], projectKeys: ["PROJ"])
		#expect(none[MorningOverview.ticketsIncompleteKey] == nil)
	}

	@Test func aDeclinedFileGetsItsTaskInEachRun() {
		let old = "# Morning overview\n\n## Cleanup Work\n\n- [ ] `C1` Delete [41-a.md](file:///p/reviews/41-a.md), because #41 was declined.\n"
		let url = "file:///p/reviews/41-a.md"
		let result = MorningOverview.withOutdatedCheck([facts("reviews/41-a.md")], old: old, last: .init(outdated: [url]), jiraTickets: [:],
			closedStates: [41: "DECLINED"])
		#expect(result.files.first?["appTask"] as? Bool == true)
		#expect(result.deleteTasks.map(\.url) == [url])
	}

	@Test func deleteTasksGoAboveTheSubsectionsOfCleanupWork() {
		let task = MorningOverview.DeleteTask(url: "file:///p/41-a.md", line: "- [ ] Delete [41-a.md](file:///p/41-a.md), because #41 was declined.")
		let withTasks = "# O\n\n## Cleanup Work\n\n- [ ] Old\n\n### Local\n\n- [ ] Delete `b`\n\n## Optional Work\n\nNothing open.\n"
		#expect(MorningOverview.withDeleteTasks([task], in: withTasks)
			== "# O\n\n## Cleanup Work\n\n- [ ] Old\n\(task.line)\n\n### Local\n\n- [ ] Delete `b`\n\n## Optional Work\n\nNothing open.\n")
		let onlySubsection = "# O\n\n## Cleanup Work\n\n### Local\n\n- [ ] Delete `b`\n"
		#expect(MorningOverview.withDeleteTasks([task], in: onlySubsection)
			== "# O\n\n## Cleanup Work\n\n\(task.line)\n\n### Local\n\n- [ ] Delete `b`\n")
		let empty = "# O\n\n## Cleanup Work\n\nNothing open.\n\n## Optional Work\n\nNothing open.\n"
		#expect(MorningOverview.withDeleteTasks([task], in: empty) == "# O\n\n## Cleanup Work\n\n\(task.line)\n\n## Optional Work\n\nNothing open.\n")
		// A kept old task with the link stays the only one.
		let kept = "# O\n\n## Cleanup Work\n\n- [ ] `C1` Delete [41-a.md](file:///p/41-a.md), because #41 was declined.\n"
		#expect(MorningOverview.withDeleteTasks([task], in: kept) == kept)
		// A link in another section, or a file with a similar name, does not count.
		let other = "# O\n\n## Optional Work\n\n- [ ] Fix [41-a.md](file:///p/41-a.md)\n\n## Cleanup Work\n\n- [ ] Delete [141-a.md](file:///p/141-a.md)\n"
		#expect(MorningOverview.withDeleteTasks([task], in: other) == other + task.line + "\n")
		#expect(MorningOverview.withDeleteTasks([task], in: "# O\n\n## Optional Work\n\nNothing open.\n")
			== "# O\n\n## Optional Work\n\nNothing open.\n\n## Cleanup Work\n\n\(task.line)\n")
	}

	@Test func aTaskOfAFileToCheckIsNotUnchanged() {
		let old = "# Morning overview\n\nUpdated: 2026-10-27 07:00\n\n## Optional Work\n\n- [ ] `O1` Plan [a.md](file:///p/a.md)\n"
		let unchanged = facts("a.md")
		#expect(MorningOverview.unchangedTasks(in: old, files: [unchanged], changedPullRequests: []) == ["O1"])
		#expect(MorningOverview.unchangedTasks(in: old, files: [unchanged.merging(["checkFindings": true]) { $1 }], changedPullRequests: []) == [])
		#expect(MorningOverview.unchangedTasks(in: old, files: [unchanged.merging(["appTask": true]) { $1 }], changedPullRequests: []) == [])
	}

	@Test func statesComeInBatchesAndAFailureGivesNone() async throws {
		let queries = Locked<[String]>([])
		let failSecond = Locked(false)
		let bitbucket = try Bitbucket(remote: "git@bitbucket.org:ws/repo.git",
			environment: [Bitbucket.emailVariable: "me@example.com", Bitbucket.tokenVariable: "token"]) { request in
			let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
			let count = queries.update { $0.append(query); return $0.count }
			if count == 2, failSecond.update({ $0 }) { return (Data(), 500) }
			let ids = query.matches(of: #/id=(\d+)/#).compactMap { Int($0.1) }
			return (bitbucketPage(ids.filter { $0 % 2 == 0 }.map { ["id": $0, "state": "MERGED"] }), 200)
		}
		let states = await MorningOverview.closedStates(bitbucket, ids: Array(1...60))
		#expect(states?.count == 30)
		#expect(queries.update { $0 }.map { $0.matches(of: #/id=/#).count } == [50, 10])
		#expect(queries.update { $0 }.first?.hasPrefix("(state=\"MERGED\" OR state=\"DECLINED\" OR state=\"SUPERSEDED\") AND (id=1 OR id=2") == true)
		queries.update { $0 = [] }
		failSecond.update { $0 = true }
		#expect(await MorningOverview.closedStates(bitbucket, ids: Array(1...60)) == nil)
		#expect(await MorningOverview.closedStates(bitbucket, ids: []) == [:])
	}
}

@MainActor @Suite struct MorningOverviewOutdatedRunTests {
	/// The fake Bitbucket answers, with the pull request 14 declined.
	nonisolated static func bodyWithDeclined(of request: URLRequest) -> Data {
		guard request.url!.query?.contains("DECLINED") == true else { return ReportFixture.morningBody(of: request) }
		return bitbucketPage([["id": 14, "state": "DECLINED"]])
	}

	@Test func theAppWritesTheDeleteTaskOfADeclinedPullRequest() async throws {
		let fixture = try ReportFixture(kind: .morningOverview, claudeOutput: overviewText, body: { Self.bodyWithDeclined(of: $0) })
		defer { fixture.cleanUp() }
		let reviews = fixture.folder.appendingPathComponent("reviews")
		try FileManager.default.createDirectory(at: reviews, withIntermediateDirectories: true)
		for name in ["13-other.md", "14-declined.md"] {
			try "# Review\n\n- [ ] Fix it.\n".write(to: reviews.appendingPathComponent(name), atomically: true, encoding: .utf8)
		}
		let declinedURL = reviews.appendingPathComponent("14-declined.md").absoluteString
		await fixture.report.update()
		// Only the closed PR gets a state request. The open PR 13 does not.
		let query = try #require(fixture.log.requests.compactMap { $0.url?.query }.first { $0.contains("DECLINED") })
		#expect(query.contains("id%3D14") || query.contains("id=14"))
		#expect(!query.contains("13"))
		let files = try #require(try fixture.input["projectFiles"] as? [[String: Any]])
		let declined = try #require(files.first { $0["name"] as? String == "14-declined.md" })
		#expect(declined["appTask"] as? Bool == true)
		#expect(declined["oldSections"] == nil)
		// The report of the open PR 13 names it by its file name.
		#expect(files.first { $0["name"] as? String == "13-other.md" }?["openPullRequests"] as? [Int] == [13])
		var text = try String(contentsOf: fixture.fileURL, encoding: .utf8)
		#expect(text.contains("Delete [14-declined.md](\(declinedURL)), because"))
		#expect(text.contains("was declined."))
		// The saved files can also have outdated plans of `~/.claude/plans`.
		let saved = try #require(MorningOverview.lastOutdated(fixture.report))
		#expect(saved.outdated.contains(declinedURL))
		#expect(!saved.outdated.contains(reviews.appendingPathComponent("13-other.md").absoluteString))
		// The next run has the task again, also when Claude does not keep it.
		await fixture.report.update()
		text = try String(contentsOf: fixture.fileURL, encoding: .utf8)
		#expect(text.components(separatedBy: "Delete [14-declined.md](").count == 2)
	}

	@Test func aFailedStateRequestKeepsTheSavedFiles() async throws {
		// Jira works, so only the failed state request keeps the saved files.
		let fixture = try ReportFixture(kind: .morningOverview, claudeOutput: overviewText, environment: ReportFixture.jiraCredentials.merging([Jira.siteVariable: "x.atlassian.net"]) { $1 },
			body: { ReportFixture.morningBody(of: $0) }, failure: { $0.url?.query?.contains("DECLINED") == true ? URLError(.timedOut) as Error : nil })
		defer { fixture.cleanUp() }
		let reviews = fixture.folder.appendingPathComponent("reviews")
		try FileManager.default.createDirectory(at: reviews, withIntermediateDirectories: true)
		let file = reviews.appendingPathComponent("14-declined.md")
		try "# Review\n\n- [ ] Fix it.\n".write(to: file, atomically: true, encoding: .utf8)
		MorningOverview.saveOutdated(.init(outdated: [file.absoluteString, "file:///gone.md"], ignored: [file.absoluteString]), fixture.report)
		await fixture.report.update()
		#expect(fixture.report.failure == nil)
		let jira = try #require(try fixture.input["jira"] as? [String: Any])
		#expect(jira["error"] == nil)
		#expect(fixture.log.requests.contains { $0.url?.query?.contains("DECLINED") == true })
		let files = try #require(try fixture.input["projectFiles"] as? [[String: Any]])
		#expect(files.first { $0["name"] as? String == "14-declined.md" }?["appTask"] == nil)
		// Without the states, the file keeps its state of the last run. A file that is gone leaves the list. The saved files
		// can also have outdated plans of `~/.claude/plans`.
		let saved = try #require(MorningOverview.lastOutdated(fixture.report))
		#expect(saved.outdated.contains(file.absoluteString))
		#expect(!saved.outdated.contains("file:///gone.md"))
		#expect(saved.ignored.contains(file.absoluteString))
	}

	@Test func aWorkingStateRequestDropsTheFilesThatAreNotOutdated() async throws {
		let fixture = try ReportFixture(kind: .morningOverview, claudeOutput: overviewText, environment: ReportFixture.jiraCredentials.merging([Jira.siteVariable: "x.atlassian.net"]) { $1 },
			body: { ReportFixture.morningBody(of: $0) })
		defer { fixture.cleanUp() }
		let reviews = fixture.folder.appendingPathComponent("reviews")
		try FileManager.default.createDirectory(at: reviews, withIntermediateDirectories: true)
		let file = reviews.appendingPathComponent("14-declined.md")
		try "# Review\n\n- [ ] Fix it.\n".write(to: file, atomically: true, encoding: .utf8)
		MorningOverview.saveOutdated(.init(outdated: [file.absoluteString]), fixture.report)
		await fixture.report.update()
		// The fake Bitbucket gives no state for PR 14, so the file is not outdated now.
		#expect(MorningOverview.lastOutdated(fixture.report)?.outdated.contains(file.absoluteString) == false)
	}
}

@Suite struct MorningOverviewOutdatedRound3Tests {
	@Test func aFailedRunKeepsOnlyTheStateOfUnchangedFilesWithoutReason() {
		let last = MorningOverview.OutdatedState(outdated: ["file:///p/a.md", "file:///p/b.md", "file:///p/c.md"], ignored: ["file:///p/a.md", "file:///p/b.md"])
		let files = [facts("a.md"), facts("b.md", ["changedAfterOldOverview": true]), facts("c.md", ["outdated": "the branch `x` is gone"])]
		let run = MorningOverview.withLastState(MorningOverview.OutdatedRun(outdated: ["file:///p/c.md"]), files: files, last: last)
		// a.md did not change and has no reason now. b.md changed, so it needs a check. c.md got its state in this run.
		#expect(run.outdated == ["file:///p/a.md", "file:///p/c.md"])
		#expect(run.ignored == ["file:///p/a.md"])
	}

	@Test func aRefWithoutLinkStillNamesTheFile() {
		let run = MorningOverview.OutdatedRun(outdated: ["file:///p/docs/h.md"], checked: [("file:///p/docs/h.md", "h.md")])
		#expect(run.state(written: "- [ ] Solve the open findings of [h.md]").ignored == [])
		#expect(run.state(written: "- [ ] Solve the open findings of [docs/h.md]").ignored == [])
		#expect(run.state(written: "- [ ] Solve the open findings of [gh.md]").ignored == ["file:///p/docs/h.md"])
	}

	@Test func aDeleteTaskOfAGoneFileGoesAway() {
		let text = """
			# Morning overview

			## Cleanup Work

			- [ ] `C1` Delete [gone.md](file:///p/gone.md), because #4 was declined.
			- [ ] `C2` Delete [here.md](file:///p/here.md), because #5 was declined.
			- [ ] `C3` Check status: [PROJ-1](https://x/browse/PROJ-1) Old ticket

			## Optional Work

			- [ ] Delete [gone.md](file:///p/gone.md) later.
			"""
		let result = MorningOverview.withoutDeleteTasksOfGoneFiles(in: text) { $0 == "/p/here.md" }
		#expect(!result.contains("`C1`"))
		#expect(result.contains("`C2`") && result.contains("`C3`"))
		// Only »Cleanup Work« counts.
		#expect(result.contains("- [ ] Delete [gone.md](file:///p/gone.md) later."))
	}
}
