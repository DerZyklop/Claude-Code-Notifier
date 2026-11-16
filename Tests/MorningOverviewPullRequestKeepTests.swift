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
			("reviewedCommit", "1234567"), ("title", "Fix more")]
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

			## 2 × Optional Work

			- [ ] `O1` [`#99`](https://bb/99) Plan [a.md](file:///p/a.md)
			- [ ] `O2` [`#12`](https://bb/12) Plan [a.md](file:///p/a.md)
			"""
		let files: [[String: Any]] = [["url": "file:///p/a.md", "changedAfterOldOverview": false, "newCommits": false]]
		let unchanged = MorningOverview.unchangedTasks(in: old, files: files, changedPullRequests: [], closedPullRequests: [99],
			unchangedPullRequests: [12, 14, 15], openPullRequests: [12, 13, 14, 15])
		// #13 changed, so M2 and M3 change. M4 names the merged #99, and so does the title line of O1.
		#expect(unchanged == ["M1", "O2"])
		// Without the states of the pull requests, no PR task is unchanged.
		#expect(MorningOverview.unchangedTasks(in: old, files: files, changedPullRequests: []) == ["O1", "O2"])
	}
}

@MainActor @Suite struct MorningOverviewPullRequestKeepRunTests {
	@Test func aSecondRunOffersTheTaskOfAnUnchangedPullRequestAsKeep() async throws {
		let fixture = try ReportFixture()
		defer { fixture.cleanUp() }
		await fixture.report.update()
		#expect(MorningOverview.lastStates(fixture.report).keys.sorted() == ["12", "13"])
		await fixture.report.update()
		let run = try #require(fixture.log.commands.last { $0.isClaudeRun })
		let input = try #require(try JSONSerialization.jsonObject(with: run.input) as? [String: Any])
		#expect(input["unchangedTasks"] as? [String] == ["M1"])
	}
}
