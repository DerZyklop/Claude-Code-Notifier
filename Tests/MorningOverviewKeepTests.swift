import Foundation
import Testing
@testable import ClaudeCodeNotifier

@Suite struct MorningOverviewKeepTests {
	private static let old = """
		# Morning overview

		Updated: 2026-10-26 06:30

		## 1 × My Open PRs

		- [ ] `M1` [`#12`](https://bb/12) [plan.md](file:///plans/plan.md) Fix
		    - [ ] `M1a` Answer Rui.

		## 3 × Optional Work

		- [ ] `O1` Solve the open findings of [plan.md](file:///plans/plan.md)
		    - [ ] `O1a` Move the check.
		    - [x] `O1b` Done step
		        - [ ] Sub-item of the done step
		    - [ ] `O1c` Rename it.
		- [ ] `O2` [`#13`](https://bb/13) Solve the open findings of [review.md](file:///reviews/review.md)
		- [x] `O3` Done task with [plan.md](file:///plans/plan.md)
		- [ ] `O4` No file

		## 1 × Cleanup Work

		- [ ] `C1` Delete [changed.md](file:///plans/changed.md), because it is old.

		"""

	private static func file(_ path: String, changed: Bool, newCommits: Bool = false) -> [String: Any] {
		["url": "file://" + path, "changedAfterOldOverview": changed, "newCommits": newCommits]
	}

	@Test func unchangedTasksNeedAnUnchangedFileAndNoNewCommits() {
		let files = [Self.file("/plans/plan.md", changed: false), Self.file("/reviews/review.md", changed: false),
			Self.file("/plans/changed.md", changed: true)]
		#expect(MorningOverview.unchangedTasks(in: Self.old, files: files, changedPullRequests: []) == ["O1", "O2"])
		// New commits on PR 13 make O2 change. The PR sections never count.
		#expect(MorningOverview.unchangedTasks(in: Self.old, files: files, changedPullRequests: [12, 13]) == ["O1"])
		let withNewCommits = [Self.file("/plans/plan.md", changed: false, newCommits: true), Self.file("/reviews/review.md", changed: false)]
		#expect(MorningOverview.unchangedTasks(in: Self.old, files: withNewCommits, changedPullRequests: []) == ["O2"])
		// A file without facts, e.g. a deleted one, counts as changed.
		#expect(MorningOverview.unchangedTasks(in: Self.old, files: [], changedPullRequests: []).isEmpty)
	}

	@Test func keepTakesTheOldTaskWithItsOpenSubItems() {
		let overview = "## Optional Work\n\n- [ ] KEEP O1\n- [ ] KEEP `C1`\n- [ ] KEEP O9\n- [ ] New task\n"
		#expect(MorningOverview.withKeptByID(in: overview, old: Self.old) == """
			## Optional Work

			- [ ] `O1` Solve the open findings of [plan.md](file:///plans/plan.md)
			    - [ ] `O1a` Move the check.
			    - [ ] `O1c` Rename it.
			- [ ] `C1` Delete [changed.md](file:///plans/changed.md), because it is old.
			- [ ] New task

			""")
	}

	@Test func keepIgnoresTheSectionsOfTheUserAndOddShapes() {
		let old = """
			# Morning overview

			## My Notes

			- [ ] `O2` Task that the user moved here

			## Daily

			- [ ] `D1` Daily task

			## 2 × Optional Work

			- [ ] `O1` 🚫 [PROJ-1](https://x/browse/PROJ-1) Blocked task
			    - [ ] `O1a` First step
			- [ ] `O2` Real task
			    - [ ] `O2a` Step
			- [ ] `O3` All done
			    - [x] `O3a` Done step

			## 1 × Draft PRs

			- [ ] `D1` [`#4327`](https://bb/4327) Draft
			    - [ ] `D1a` Step of the draft

			"""
		let overview = "- [ ] KEEP O2\n- [ ] 🚫 KEEP O1\n- [ ] KEEP D1a.\n- [ ] KEEP O3\n- [ ] KEEP: O1a Some text\n"
		#expect(MorningOverview.withKeptByID(in: overview, old: old) == """
			- [ ] `O2` Real task
			    - [ ] `O2a` Step
			- [ ] `O1` 🚫 [PROJ-1](https://x/browse/PROJ-1) Blocked task
			    - [ ] `O1a` First step
			- [ ] `D1a` Step of the draft
			- [ ] `O1a` First step

			""")
	}

	@Test func unchangedTasksLookAtCodePathsJiraAndTheSection() {
		let old = """
			# Morning overview

			## 1 × TODO

			- [ ] `T1` Note with [plan.md](file:///plans/plan.md)

			## 5 × Optional Work

			- [ ] `O1` Go on with `plans/PLANO-1-plan.md`
			- [ ] `O2` Fix [plan.md](file:///plans/plan.md)
			    - [ ] `O2a` Start with step 6 of `plans/other-plan.md`.
			- [ ] `O3` 🚫 [PROJ-1](https://x/browse/PROJ-1) Fix [plan.md](file:///plans/plan.md)
			- [ ] `O4` [PROJ-2](https://x/browse/PROJ-2) Fix [plan.md](file:///plans/plan.md)
			- [ ] `O5` [PROJ-3](https://x/browse/PROJ-3) Fix [plan.md](file:///plans/plan.md)

			"""
		let files = [Self.file("/plans/plan.md", changed: false), Self.file("/project/plans/PLANO-1-plan.md", changed: false),
			Self.file("/project/plans/other-plan.md", changed: true)]
		let tickets: [String: [String: Any]] = ["PROJ-1": ["blocked": true, "done": false], "PROJ-2": ["blocked": false, "done": false],
			"PROJ-3": ["blocked": false, "done": true]]
		// T1 is in a section of the user. O2 names a changed plan. O5 has a done ticket.
		#expect(MorningOverview.unchangedTasks(in: old, files: files, changedPullRequests: [], tickets: tickets) == ["O1", "O3", "O4"])
		// O3 is no longer blocked, and O4 is blocked now, so both need a new 🚫.
		let changedBlocks: [String: [String: Any]] = ["PROJ-1": ["blocked": false], "PROJ-2": ["blocked": true]]
		#expect(MorningOverview.unchangedTasks(in: old, files: files, changedPullRequests: [], tickets: changedBlocks) == ["O1", "O5"])
		// Without Jira, the marks stay as they are.
		#expect(MorningOverview.unchangedTasks(in: old, files: files, changedPullRequests: []) == ["O1", "O3", "O4", "O5"])
	}

	@Test(arguments: [
		("- Branch: `b`, reviewed at `5868f54`, fixes up to `09a6970`", "5868f54"),
		("[PR #4341](x) · reviewed commit `6e460fc` · 2026-11-10", "6e460fc"),
		("- Reviewed commit: `AC3CCF6` · 2026-11-09", "ac3ccf6"),
		("**Reviewed commit:** `276c71d`", "276c71d"),
		("The commit `94ff8d6` is fine.", nil),
	] as [(String, String?)])
	func reviewedCommitOfAReport(text: String, commit: String?) {
		#expect(MorningOverview.reviewedCommit(in: text) == commit)
	}

	@Test func aReviewIsNewWhenThePullRequestHasAnotherHead() throws {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("reviews")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
		let reports = [
			("4341-fix.md", "reviewed commit `6e460fc`", -100.0),
			("4342-older.md", "reviewed commit `1111111`", -200),
			("4342-newer-2222222.md", "No line with the commit.", -100),
			("4343-same.md", "reviewed commit `3333333`", -100),
			("4344-closed.md", "reviewed commit `4444444`", -100),
			("notes-4345.md", "reviewed commit `5555555`", -100),
		]
		var files: [URL] = []
		for (name, text, age) in reports {
			let file = folder.appendingPathComponent(name)
			try text.write(to: file, atomically: true, encoding: .utf8)
			try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(age)], ofItemAtPath: file.path)
			files.append(file)
		}
		let outside = folder.deletingLastPathComponent().appendingPathComponent("4343-outside.md")
		try "reviewed commit `0000000`".write(to: outside, atomically: true, encoding: .utf8)
		let pullRequest = { (id: Int, head: String, author: String, draft: Bool) -> [String: Any] in
			["id": id, "title": "PR \(id)", "draft": draft, "author": ["display_name": author], "source": ["commit": ["hash": head]],
				"links": ["html": ["href": "https://bb/\(id)"]]]
		}
		// The older report of 4346 names the head, so the newer one with an old commit does not count.
		for (name, text, age) in [("4346-head.md", "reviewed commit `6666666`", -300.0), ("4346-later-edit.md", "reviewed commit `5555555`", -10)] {
			let file = folder.appendingPathComponent(name)
			try text.write(to: file, atomically: true, encoding: .utf8)
			try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(age)], ofItemAtPath: file.path)
			files.append(file)
		}
		let pullRequests = [pullRequest(4341, "abcdef012345", "Rui", false), pullRequest(4342, "2222222abcde", "Nils", false),
			pullRequest(4343, "333333300000", "Nils", true), pullRequest(4345, "999999999999", "Nils", false),
			pullRequest(4346, "666666600000", "Nils", false)]
		let reviews = MorningOverview.newReviews(in: files + [outside], reviewsFolder: folder, pullRequests: pullRequests, me: "Nils")
		// 4341 has a new head. The newer report of 4342 names its head in the file name. 4343 has its head. 4344 is not
		// open, and the file of 4345 does not start with the number.
		#expect(reviews == [MorningOverview.NewReview(id: 4341, reviewedCommit: "6e460fc", url: "https://bb/4341", title: "PR 4341",
			section: "Their Open PRs")])

		let marked = MorningOverview.withNewReviews(reviews, in: pullRequests)
		#expect(marked[0]["needsNewReview"] as? Bool == true)
		#expect(marked[0]["reviewedCommit"] as? String == "6e460fc")
		#expect(marked[0]["isMyTurn"] as? Bool == true)
		#expect(marked[1]["needsNewReview"] == nil)
	}

	@Test func aNewReviewGetsTheFirstNextActionOfItsTask() {
		let review = { (id: Int, section: String) in
			MorningOverview.NewReview(id: id, reviewedCommit: "6e460fc", url: "https://bb/\(id)", title: "Fix PROJ-3 the login", section: section)
		}
		let overview = """
			# Morning overview

			## Their Open PRs

			Nothing open.

			## My Open PRs

			- [ ] [`#12`](https://bb/12) Fix
			    - [ ] Answer Rui.

			## Draft PRs

			Nothing open.

			"""
		var conflict = review(15, "Draft PRs")
		conflict.hasMergeConflict = true
		conflict.destination = "dev"
		let result = MorningOverview.withNewReviewTasks([review(12, "My Open PRs"), review(14, "Their Open PRs"), conflict],
			jiraBrowseURL: "https://x.atlassian.net/browse/", in: overview)
		#expect(result == """
			# Morning overview

			## Their Open PRs

			- [ ] [`#14`](https://bb/14) [PROJ-3](https://x.atlassian.net/browse/PROJ-3) Fix the login
			    - [ ] Run `/nn-review #14` again, because the PR has new commits after the review of `6e460fc`.

			## My Open PRs

			- [ ] [`#12`](https://bb/12) Fix
			    - [ ] Run `/nn-review #12` again, because the PR has new commits after the review of `6e460fc`.
			    - [ ] Answer Rui.

			## Draft PRs

			- [ ] [`#15`](https://bb/15) [PROJ-3](https://x.atlassian.net/browse/PROJ-3) Fix the login
			    - [ ] Merge `dev` into the branch and solve the merge conflict.
			    - [ ] Run `/nn-review #15` again, because the PR has new commits after the review of `6e460fc`.

			""")
	}

	@Test(arguments: [
		// The newest commit is from Rui, and the commits of Nils are not after the reviewed commit.
		(["Rui Costa <rui@x.com>", "Nils <nils@x.com>", "Nils <nils@x.com>"], "bbbb222", false),
		(["Rui Costa <rui@x.com>", "Nils <nils@x.com>", "Nils <nils@x.com>"], "cccc333", true),
		// The reviewed commit is the newest one.
		(["Nils <nils@x.com>", "Nils <nils@x.com>"], "aaaa111", false),
		// No commit is the reviewed one, e.g. after a rebase, so each commit counts.
		(["Rui Costa <rui@x.com>", "Nils <nils@x.com>"], "0000000", true),
		(["Rui Costa <rui@x.com>", "Nilsson <n@x.com>"], "0000000", false),
	] as [([String], String, Bool)])
	func aCommitOfTheUserAfterTheReviewedCommit(authors: [String], reviewed: String, expected: Bool) {
		let hashes = ["aaaa111aaaa", "bbbb222bbbb", "cccc333cccc"]
		let commits = zip(hashes, authors).map { hash, author in ["hash": hash, "author": ["raw": author]] as [String: Any] }
		#expect(MorningOverview.hasCommit(of: "Nils", after: reviewed, in: commits) == expected)
	}

	@Test func theDisplayNameOnBitbucketNamesTheUserToo() {
		let commits: [[String: Any]] = [["hash": "aaaa111", "author": ["raw": "nn <nils@x.com>", "user": ["display_name": "Nils"]]]]
		#expect(MorningOverview.hasCommit(of: "Nils", after: "0000000", in: commits))
		#expect(!MorningOverview.hasCommit(of: "Rui", after: "0000000", in: commits))
	}

	@Test func theNextActionOfAReviewThatIsNotNewGoesAway() {
		let review = MorningOverview.NewReview(id: 14, reviewedCommit: "6e460fc", url: "https://bb/14", title: "Other", section: "My Open PRs")
		let overview = """
			# Morning overview

			## My Open PRs

			- [ ] `M1` [`#12`](https://bb/12) Fix
			    - [ ] `M1a` Run `/nn-review #12` again, because the PR has new commits after the review of `1111111`.
			        - a note
			    - [ ] `M1b` Answer Rui.
			- [ ] [`#14`](https://bb/14) Other
			    - [ ] Run `/nn-review #14` again, because the PR has new commits after the review of `6e460fc`.

			"""
		#expect(MorningOverview.withNewReviewTasks([review], jiraBrowseURL: nil, in: overview) == """
			# Morning overview

			## My Open PRs

			- [ ] `M1` [`#12`](https://bb/12) Fix
			    - [ ] `M1b` Answer Rui.
			- [ ] [`#14`](https://bb/14) Other
			    - [ ] Run `/nn-review #14` again, because the PR has new commits after the review of `6e460fc`.

			""")
	}

	@Test func aNewReviewComesAfterTheMergeOfAConflict() {
		var review = MorningOverview.NewReview(id: 12, reviewedCommit: "6e460fc", url: "https://bb/12", title: "Fix", section: "My Open PRs")
		review.hasMergeConflict = true
		let overview = """
			# Morning overview

			## My Open PRs

			- [ ] [`#12`](https://bb/12) Fix
			    - [ ] Merge `dev` into the branch and solve the merge conflict.
			    - [ ] Answer Rui.

			"""
		#expect(MorningOverview.withNewReviewTasks([review], jiraBrowseURL: nil, in: overview) == """
			# Morning overview

			## My Open PRs

			- [ ] [`#12`](https://bb/12) Fix
			    - [ ] Merge `dev` into the branch and solve the merge conflict.
			    - [ ] Run `/nn-review #12` again, because the PR has new commits after the review of `6e460fc`.
			    - [ ] Answer Rui.

			""")
	}
}

@MainActor @Suite struct MorningOverviewKeepRunTests {
	/// The fake Bitbucket answers, with a head commit for the open pull requests 12 and 13.
	nonisolated static func bodyWithHeads(of request: URLRequest) -> Data {
		let data = ReportFixture.morningBody(of: request)
		guard request.url!.path.hasSuffix("/pullrequests"), request.url!.query?.contains("MERGED") != true,
			var page = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let values = page["values"] as? [[String: Any]] else { return data }
		let heads = [12: "aaaa1111bbbb", 13: "cccc2222dddd"]
		page["values"] = values.map { value in
			var value = value
			if let id = value["id"] as? Int, let head = heads[id] { value["source"] = ["commit": ["hash": head]] }
			return value
		}
		return try! JSONSerialization.data(withJSONObject: page)
	}

	@Test func aPullRequestWithNewCommitsAfterItsReportGetsANewReview() async throws {
		let fixture = try ReportFixture(kind: .morningOverview, claudeOutput: overviewText, body: { Self.bodyWithHeads(of: $0) })
		defer { fixture.cleanUp() }
		let reviews = fixture.folder.appendingPathComponent("reviews")
		try FileManager.default.createDirectory(at: reviews, withIntermediateDirectories: true)
		try "# PR #13\n\nreviewed commit `1234567` · report mode\n".write(to: reviews.appendingPathComponent("13-other.md"), atomically: true, encoding: .utf8)
		await fixture.report.update()
		let pullRequests = try #require(try fixture.input["pullRequests"] as? [[String: Any]])
		#expect(pullRequests.first { $0["id"] as? Int == 13 }?["needsNewReview"] as? Bool == true)
		let text = try String(contentsOf: fixture.fileURL, encoding: .utf8)
		#expect(text.contains("Run `/nn-review #13` again, because the PR has new commits after the review of `1234567`."))
		#expect(MorningOverview.lastHeads(fixture.report) == ["12": "aaaa1111bbbb", "13": "cccc2222dddd"])
	}

	/// ``bodyWithHeads(of:)``, with one commit of `author` on the pull request 12 after the reviewed commit `1234567`.
	nonisolated static func bodyWithCommits(of request: URLRequest, author: String) -> Data {
		guard request.url!.path.hasSuffix("/pullrequests/12/commits") else { return bodyWithHeads(of: request) }
		return bitbucketPage([["hash": "aaaa1111bbbb", "author": ["raw": "\(author) <a@x.com>"]],
			["hash": "1234567890ab", "author": ["raw": "Nils <nils@x.com>"]]])
	}

	@Test(arguments: [("Rui", false), ("Nils", true)])
	func aPullRequestOfTheUserGetsANewReviewOnlyAfterACommitOfTheUser(author: String, isNew: Bool) async throws {
		let fixture = try ReportFixture(kind: .morningOverview, claudeOutput: overviewText,
			body: { Self.bodyWithCommits(of: $0, author: author) })
		defer { fixture.cleanUp() }
		let reviews = fixture.folder.appendingPathComponent("reviews")
		try FileManager.default.createDirectory(at: reviews, withIntermediateDirectories: true)
		try "# PR #12\n\nreviewed commit `1234567` · report mode\n".write(to: reviews.appendingPathComponent("12-fix.md"), atomically: true, encoding: .utf8)
		await fixture.report.update()
		let pullRequests = try #require(try fixture.input["pullRequests"] as? [[String: Any]])
		#expect((pullRequests.first { $0["id"] as? Int == 12 }?["needsNewReview"] as? Bool == true) == isNew)
		let text = try String(contentsOf: fixture.fileURL, encoding: .utf8)
		#expect(text.contains("Run `/nn-review #12` again") == isNew)
		let query = try #require(fixture.log.requests.first { $0.url!.path.hasSuffix("/pullrequests/12/commits") }?.url?.query)
		#expect(query.contains("values.author.raw"))
	}

	@Test func headsStayWhenTheFileCannotBeWritten() async throws {
		let fixture = try ReportFixture(kind: .morningOverview, claudeOutput: overviewText, body: { Self.bodyWithHeads(of: $0) })
		defer {
			try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.overviewFolder.path)
			fixture.cleanUp()
		}
		MorningOverview.saveHeads([99: "old"], fixture.report)
		try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.overviewFolder.path)
		await fixture.report.update()
		#expect(fixture.report.failure?.hasPrefix("The file could not be written") == true)
		#expect(MorningOverview.lastHeads(fixture.report) == ["99": "old"])
	}

	@Test func keeperDoesNotChangeTheFileWhileARunIsActive() throws {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeCodeNotifierTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		let file = folder.appendingPathComponent("overview.md")
		let text = "## 2 × My Open PRs\n\n- [ ] New task\n- [ ] `M1` Old task\n"
		try text.write(to: file, atomically: true, encoding: .utf8)
		let keeper = SectionCountKeeper(isPaused: { true }) { file }
		keeper.check()
		try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
		keeper.check()
		keeper.check()
		#expect(try String(contentsOf: file, encoding: .utf8) == text)
	}

	@Test func keepUsesTheOldOverviewThatClaudeRead() async throws {
		let output = "# Morning overview\n\nUpdated: 2026-10-27 07:00\n\n## Optional Work\n\n- [ ] KEEP O1\n"
		let changed = Locked<URL?>(nil)
		let fixture = try ReportFixture(kind: .morningOverview, claudeOutput: output, body: { ReportFixture.morningBody(of: $0) }, beforeAnswer: {
			// The user adds a task while Claude runs, and the app gives the tasks new IDs.
			try? "# Morning overview\n\nUpdated: 2026-10-26 06:30\n\n## Optional Work\n\n- [ ] `O1` New task of the user\n- [ ] `O2` Kept task\n"
				.write(to: changed.update { $0 }!, atomically: true, encoding: .utf8)
		})
		defer { fixture.cleanUp() }
		try "# Morning overview\n\nUpdated: 2026-10-26 06:30\n\n## Optional Work\n\n- [ ] `O1` Kept task\n    - [ ] `O1a` Step\n    - [x] `O1b` Done\n"
			.write(to: fixture.fileURL, atomically: true, encoding: .utf8)
		changed.update { $0 = fixture.fileURL }
		await fixture.report.update()
		let text = try String(contentsOf: fixture.fileURL, encoding: .utf8)
		#expect(text.contains("- [ ] `O1` Kept task\n    - [ ] `O1a` Step\n"))
		#expect(!text.contains("KEEP"))
		#expect(!text.contains("Done"))
	}

	@Test func headsOfTheOpenPullRequestsStayForTheNextRun() async throws {
		let fixture = try ReportFixture()
		defer { fixture.cleanUp() }
		MorningOverview.saveHeads([12: "abc", 13: "def"], fixture.report)
		#expect(MorningOverview.lastHeads(fixture.report) == ["12": "abc", "13": "def"])
		await fixture.report.update()
		// The fake pull requests have no head, so the run saves none.
		#expect(MorningOverview.lastHeads(fixture.report) == [:])
		let input = try fixture.input
		#expect(input["projectFiles"] as? [Any] != nil)
		#expect(input["unchangedTasks"] == nil)
	}
}
