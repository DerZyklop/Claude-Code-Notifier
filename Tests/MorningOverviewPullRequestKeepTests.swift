import Foundation
import Testing
@testable import ClaudeCodeNotifier

@Suite struct MorningOverviewPullRequestKeepTests {
	private let pullRequest: [String: Any] = ["id": 12, "title": "Fix", "updated_on": "2026-10-26T10:00:00.000000+00:00", "comment_count": 2,
		"task_count": 1, "source": ["commit": ["hash": "abc"]], "openTasks": [["content": ["raw": "t"]]],
		"buildStatuses": [["name": "Pipeline #2", "state": "SUCCESSFUL"], ["name": "Pipeline #1", "state": "FAILED"]],
		"hasMergeConflict": false, "draft": false, "isMyTurn": true, "isStale": false]

	@Test func eachFactOfThePullRequestChangesItsState() {
		let state = MorningOverview.state(of: pullRequest)
		#expect(MorningOverview.state(of: pullRequest) == state)
		let changes: [(String, Any)] = [("updated_on", "2026-10-27T10:00:00.000000+00:00"), ("comment_count", 3), ("task_count", 2),
			("source", ["commit": ["hash": "def"]]), ("openTasks", [[String: Any]]()), ("buildStatuses", [["name": "Pipeline #3", "state": "FAILED"]]),
			("hasMergeConflict", true), ("draft", true), ("isMyTurn", false), ("isStale", true), ("needsNewReview", true),
			("reviewedCommit", "1234567"), ("title", "Fix more"),
			("participants", [["user": ["display_name": "Rui"], "role": "REVIEWER", "approved": true]]),
			("openTasks", [["content": ["raw": "t2"]]]), ("newestComments", [["content": ["raw": "Edited"], "user": ["display_name": "Rui"]]])]
		for (key, value) in changes {
			var changed = pullRequest
			changed[key] = value
			#expect(MorningOverview.state(of: changed) != state, "\(key)")
		}
	}

	@Test func aTaskOfAnUnchangedPullRequestIsUnchanged() {
		let old = """
			# Morning overview

			Updated: 2026-10-27 07:00

			## 3 × My Open PRs

			- [ ] `M1` [`#12`](https://bb/12) Fix
			    - [ ] Merge it.
			- [ ] `M2` [`#13`](https://bb/13) Other
			    - [ ] Merge it.
			- [ ] `M3` [`#14`](https://bb/14) Third
			    - [ ] Fix finding #2, then wait for #13.
			- [ ] `M4` [`#15`](https://bb/15) Fourth
			    - [ ] Merge it after #99.
			- [ ] `M5` [`#16`](https://bb/16) Fifth
			    - [x] Remind Rui.
			- [ ] `M6` [`#17`](https://bb/17) [PROJ-5](https://x/browse/PROJ-5) Sixth
			    - [ ] Merge it.

			## 2 × Optional Work

			- [ ] `O1` [`#99`](https://bb/99) Plan [a.md](file:///p/a.md)
			- [ ] `O2` [`#12`](https://bb/12) Plan [a.md](file:///p/a.md)
			"""
		let files: [[String: Any]] = [["url": "file:///p/a.md", "changedAfterOldOverview": false, "newCommits": false]]
		let unchanged = MorningOverview.unchangedTasks(in: old, files: files, changedPullRequests: [], tickets: ["PROJ-5": ["done": true]],
			closedPullRequests: [99], unchangedPullRequests: [12, 14, 15, 16, 17], openPullRequests: [12, 13, 14, 15, 16, 17])
		// #13 changed, so M2 and M3 change. M4 names the merged #99, and so does the title line of O1. The user did all next
		// actions of M5, and the ticket of M6 is done.
		#expect(unchanged == ["M1", "O2"])
		// Without the states of the pull requests, no PR task is unchanged.
		#expect(MorningOverview.unchangedTasks(in: old, files: files, changedPullRequests: []) == ["O1", "O2"])
	}

	@Test func aFileOnTheBranchOfThePullRequestDoesNotBlockKeep() {
		let old = """
			# Morning overview

			## 2 × Draft PRs

			- [ ] `D1` [`#12`](https://bb/12) Fix
			    - [ ] Remove `notes/branch-report.md` from the branch.
			- [ ] `D2` [`#13`](https://bb/13) Other
			    - [ ] Update `gone-plan.md`.

			## 2 × Optional Work

			- [ ] `O1` Plan [a.md](file:///p/a.md)
			    - [ ] Remove `branch-report.md`.
			"""
		let files: [[String: Any]] = [["url": "file:///p/a.md", "changedAfterOldOverview": false, "newCommits": false]]
		let unchanged = { (lastNames: Set<String>?) in
			MorningOverview.unchangedTasks(in: old, files: files, changedPullRequests: [], unchangedPullRequests: [12, 13],
				openPullRequests: [12, 13], lastNames: lastNames)
		}
		// `gone-plan.md` was a plan at the last run, so it changed. Outside the PR sections, an unknown name still counts.
		#expect(unchanged(["a.md", "gone-plan.md"]) == ["D1"])
		// Without the names of the last run, each unknown name counts as changed.
		#expect(unchanged(nil) == [])
	}
}

@MainActor @Suite struct MorningOverviewPullRequestKeepRunTests {
	@Test func aSecondRunOffersTheTaskOfAnUnchangedPullRequestAsKeep() async throws {
		let fixture = try ReportFixture()
		defer { fixture.cleanUp() }
		await fixture.report.update()
		let written = try String(contentsOf: fixture.fileURL, encoding: .utf8)
		#expect(MorningOverview.lastStates(fixture.report, old: written).keys.sorted() == ["12", "13"])
		// The states count only for the overview of their run.
		#expect(MorningOverview.lastStates(fixture.report, old: "# Morning overview\n\nUpdated: 2026-10-20 07:00\n") == [:])
		await fixture.report.update()
		#expect(try unchangedTasks(of: fixture) == ["M1"])
		// A new review report of PR 12 changes its task.
		let reviews = fixture.folder.appendingPathComponent("reviews")
		try FileManager.default.createDirectory(at: reviews, withIntermediateDirectories: true)
		try "# Review\n\nreviewed commit `1234567`\n".write(to: reviews.appendingPathComponent("12-fix.md"), atomically: true, encoding: .utf8)
		await fixture.report.update()
		#expect(try unchangedTasks(of: fixture) == [])
	}

	/// The `unchangedTasks` of the last Claude run of `fixture`.
	private func unchangedTasks(of fixture: ReportFixture) throws -> [String]? {
		let run = try #require(fixture.log.commands.last { $0.isClaudeRun })
		return try #require(try JSONSerialization.jsonObject(with: run.input) as? [String: Any])["unchangedTasks"] as? [String]
	}
}
