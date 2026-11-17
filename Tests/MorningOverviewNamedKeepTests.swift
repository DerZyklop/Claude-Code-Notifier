import Foundation
import Testing
@testable import ClaudeCodeNotifier

@Suite struct MorningOverviewNamedKeepTests {
	private let old = """
		# Morning overview

		## 3 × Open Branches

		- [ ] `B1` `feature/a` Idea - Open a PR.
		- [ ] `B2` [PROJ-7](https://x/browse/PROJ-7) `feature/PROJ-7-…` Long name - Open a PR.
		- [ ] `B3` `feature/b` Other - Open a PR.

		## 4 × Optional Work

		- [ ] `O1` Worktree cleanup
		    - [ ] Remove the worktree `try-3`, because it has no changes.
		- [ ] `O2` Go on with the session »🦊 Ideas«.
		- [ ] `O3` [`#12`](https://bb/12) Follow-up - When #12 is merged, do it.
		- [ ] `O4` Remove the line from `CLAUDE.md:66`.

		## 1 × Cleanup Work

		- [ ] `C1` Delete `feature/a`, because it is empty.
		"""
	private let states = MorningOverview.NamedStates(branches: ["feature/a": "1", "feature/PROJ-7-long-name": "2", "feature/b": "3"],
		worktrees: ["try-3": "w"], sessions: [MorningOverview.normalizedTitle("🦊\u{A0}Ideas"): "2026-10-26 10:00"], tickets: ["PROJ-7": "In Progress"])
	private let tickets: [String: [String: Any]] = ["PROJ-7": ["status": "In Progress", "done": false, "blocked": false]]

	private func unchanged(_ change: (inout MorningOverview.NamedFacts) -> Void = { _ in }) -> [String] {
		var facts = MorningOverview.NamedFacts(now: states, last: states, openPullRequests: [12], tickets: tickets)
		change(&facts)
		return MorningOverview.unchangedTasks(in: old, files: [], changedPullRequests: [], tickets: facts.tickets, named: facts)
	}

	@Test func aTaskWithoutFilesIsUnchangedWhenAllItsObjectsAre() {
		// O4 names no branch, worktree, PR or session. »Cleanup Work« has its own rules.
		#expect(unchanged() == ["B1", "B2", "B3", "O1", "O2", "O3"])
		// Without the states of the last run, no task without files is unchanged.
		#expect(MorningOverview.unchangedTasks(in: old, files: [], changedPullRequests: []) == [])
	}

	@Test func eachChangeOfAnObjectChangesItsTask() {
		let cases: [(String, (inout MorningOverview.NamedFacts) -> Void, [String])] = [
			("new commit", { $0.now.branches["feature/a"] = "9" }, ["B1"]),
			("gone branch of a name with …", { $0.now.branches["feature/PROJ-7-long-name"] = nil }, ["B2"]),
			("new branch", { $0.last.branches["feature/b"] = nil }, ["B3"]),
			("branch of an open PR", { $0.pullRequestBranches = ["feature/b"] }, ["B3"]),
			("changed worktree", { $0.now.worktrees["try-3"] = "x" }, ["O1"]),
			("changed session", { $0.now.sessions = [MorningOverview.normalizedTitle("🦊 ideas"): "2026-10-27 08:00"] }, ["O2"]),
			("archived session", { $0.archivedTitles = ["🦊 IDEAS"] }, ["O2"]),
			("changed PR", { $0.changedPullRequests = [12] }, ["O3"]),
			("ticket in the sprint", { $0.sprint = ["PROJ-7"] }, ["B2"]),
			("ticket with a new status", { $0.now.tickets = ["PROJ-7": "Untested"] }, ["B2"]),
			("ticket without a saved status", { $0.last.tickets = nil }, ["B2"]),
			("ticket of an open PR", { $0.pullRequestTitles = ["PROJ-7 Long name"] }, ["B2"]),
		]
		let all = unchanged()
		for (name, change, changed) in cases {
			#expect(unchanged(change) == all.filter { !changed.contains($0) }, "\(name)")
		}
	}

	@Test func theStatesOfTheFactsOfARun() {
		let states = MorningOverview.namedStates(branches: [["name": "feature/a", "upstream": "origin/feature/a", "track": "[ahead 1]"],
			["name": "origin/feature/done", "mergedInto": ["origin/dev"]]], tips: ["feature/a": "abc", "origin/feature/a": "def", "origin/feature/done": "123"],
			workspaces: [["path": "/p/.claude/worktrees/try-3", "head": "abc", "branch": "detached HEAD", "uncommittedChanges": [" M a.ts"]]],
			sessions: [["title": "🦊\u{A0} Ideas", "lastChange": "2026-10-26 10:00"]], tickets: tickets)
		#expect(states.branches == ["feature/a": "abc|def|origin/feature/a|[ahead 1]||", "origin/feature/done": "123||||origin/dev|"])
		#expect(states.worktrees.keys.sorted() == ["try-3"])
		#expect(states.sessions == ["🦊 ideas": "2026-10-26 10:00"])
		#expect(states.tickets == ["PROJ-7": "In Progress"])
	}
}

@MainActor @Suite struct MorningOverviewNamedKeepRunTests {
	@Test func aSecondRunOffersTheTaskOfAnUnchangedWorktreeAsKeep() async throws {
		let output = """
			# Morning overview

			Updated: 2026-10-27 07:00

			## Optional Work

			- [ ] Remove the worktree `scratch`, because it has no commits of its own.
			"""
		let fixture = try ReportFixture(kind: .morningOverview, claudeOutput: output, body: { ReportFixture.morningBody(of: $0) })
		defer { fixture.cleanUp() }
		await fixture.report.update()
		let written = try String(contentsOf: fixture.fileURL, encoding: .utf8)
		let saved = try #require(MorningOverview.lastNamedStates(fixture.report, old: written))
		#expect(saved.worktrees.keys.sorted() == ["repo", "scratch"])
		// The states count only for the overview of their run.
		#expect(MorningOverview.lastNamedStates(fixture.report, old: "# Morning overview\n\nUpdated: 2026-10-20 07:00\n") == nil)
		await fixture.report.update()
		let run = try #require(fixture.log.commands.last { $0.isClaudeRun })
		let input = try #require(try JSONSerialization.jsonObject(with: run.input) as? [String: Any])
		#expect(input["unchangedTasks"] as? [String] == ["O1"])
		// The JSON has no newest commit of a worktree.
		#expect((input["workspaces"] as? [[String: Any]])?.allSatisfy { $0["head"] == nil } == true)
	}
}
