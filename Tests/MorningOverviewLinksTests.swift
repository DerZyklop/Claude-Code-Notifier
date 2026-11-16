import Foundation
import Testing
@testable import ClaudeCodeNotifier

private let links = MorningOverview.Links(
	pullRequests: [12: "https://bb/12"], repository: "ws/repo", jiraBrowseURL: "https://x.atlassian.net/browse/", projectKeys: ["PROJ"],
	files: ["file:///p/plans/a.md", "file:///p/reviews/13-r.md", "file:///p/plans/same.md", "file:///p/reviews/same.md",
		"file:///p/handover.md", "file:///p/notes/handover.md", "file:///p/my%20plan.md"],
	folders: ["/p"])

/// The overview with `body` as the only section `section`.
private func overview(_ section: String, _ body: String) -> String { "# Morning overview\n\n## \(section)\n\n\(body)\n" }

@Suite struct MorningOverviewLinksTests {
	@Test func refsBecomeLinks() {
		let text = overview("My Open PRs", "- [ ] 🚫 [#12] [PROJ-1] [a.md] Fix it\n    - [ ] Read [13-r.md] and [reviews/same.md], then ask on [#99].")
		#expect(MorningOverview.withLinks(links, in: text) == overview("My Open PRs", """
			- [ ] 🚫 [`#12`](https://bb/12) [PROJ-1](https://x.atlassian.net/browse/PROJ-1) [a.md](file:///p/plans/a.md) Fix it
			    - [ ] Read [13-r.md](file:///p/reviews/13-r.md) and [reviews/same.md](file:///p/reviews/same.md), then ask on [`#99`](https://bitbucket.org/ws/repo/pull-requests/99).
			"""))
	}

	@Test func theFileWithThePathFromTheProjectFolderWins() {
		let text = overview("Optional Work", "- [ ] [handover.md] and [notes/handover.md] and [my plan.md]")
		#expect(MorningOverview.withLinks(links, in: text) == overview("Optional Work",
			"- [ ] [handover.md](file:///p/handover.md) and [notes/handover.md](file:///p/notes/handover.md) and [my plan.md](file:///p/my%20plan.md)"))
	}

	@Test func codeLinksCheckboxesAndOtherTextStay() {
		let body = """
			- [ ] `[#12]` [`#12`](https://old/12) [same.md] [gone.md] [x] [UTF-8] [CVE-2024]
			- [x] Run `/nn-review #12` again.
			"""
		#expect(MorningOverview.withLinks(links, in: overview("Optional Work", body)) == overview("Optional Work", body))
	}

	@Test func aTicketWithoutTheJiraSiteIsPlainText() {
		var noJira = links
		noJira.jiraBrowseURL = nil
		#expect(MorningOverview.withLinks(noJira, in: overview("Optional Work", "- [ ] [PROJ-1] Do it [UTF-8]"))
			== overview("Optional Work", "- [ ] PROJ-1 Do it [UTF-8]"))
	}
}

@MainActor @Suite struct MorningOverviewLinksRunTests {
	@Test func theWrittenOverviewHasTheLinksOfTheRefs() async throws {
		let output = """
			# Morning overview

			Updated: 2026-10-27 07:00

			## My Open PRs

			- [ ] [#12] Fix
			    - [ ] Answer the task on [#13].

			## Optional Work

			- [ ] Solve the open findings of [reviews/13-other.md]
			"""
		let fixture = try ReportFixture(kind: .morningOverview, claudeOutput: output, body: { ReportFixture.morningBody(of: $0) })
		defer { fixture.cleanUp() }
		let reviews = fixture.folder.appendingPathComponent("reviews")
		try FileManager.default.createDirectory(at: reviews, withIntermediateDirectories: true)
		try "# Review\n\n- [ ] Fix it.\n".write(to: reviews.appendingPathComponent("13-other.md"), atomically: true, encoding: .utf8)
		await fixture.report.update()
		let text = try String(contentsOf: fixture.fileURL, encoding: .utf8)
		// The fake PRs have no URL, so the app builds it from the repository of `origin`.
		#expect(text.contains("[`#12`](https://bitbucket.org/ws/repo/pull-requests/12) Fix"))
		#expect(text.contains("Answer the task on [`#13`](https://bitbucket.org/ws/repo/pull-requests/13)."))
		#expect(text.contains("Solve the open findings of [reviews/13-other.md](\(reviews.appendingPathComponent("13-other.md").absoluteString))"))
	}

	@Test func aTaskWithALineOfTheUserStaysOneTask() async throws {
		let output = "# Morning overview\n\nUpdated: 2026-10-27 07:00\n\n## My Open PRs\n\n- [ ] [#12] Fix\n    - [ ] Merge it.\n"
		let fixture = try ReportFixture(kind: .morningOverview, claudeOutput: output, body: { ReportFixture.morningBody(of: $0) })
		defer { fixture.cleanUp() }
		let written = "# Morning overview\n\nUpdated: 2026-10-26 06:30\n\n## 1 × My Open PRs\n\n- [ ] `M1` [`#12`](https://bitbucket.org/ws/repo/pull-requests/12) Fix\n"
		try written.write(to: fixture.report.supportFolder.appendingPathComponent("last-written.md").creatingFolder(), atomically: true, encoding: .utf8)
		try (written + "    - [ ] My own note\n").write(to: fixture.fileURL, atomically: true, encoding: .utf8)
		await fixture.report.update()
		let text = try String(contentsOf: fixture.fileURL, encoding: .utf8)
		#expect(text.components(separatedBy: "pull-requests/12) Fix").count == 2)
		#expect(text.contains("My own note") && text.contains("Merge it."))
	}
}

private extension URL {
	/// The URL, after its folder was made.
	func creatingFolder() throws -> URL {
		try FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true)
		return self
	}
}

@Suite struct MorningOverviewFileTextTests {
	/// A file of the project, with the facts of a run.
	private func file(_ name: String, _ extra: [String: Any] = [:]) -> [String: Any] {
		["name": name, "url": "file:///p/\(name)", "changedAfterOldOverview": false, "newCommits": false, "changedOn": "2026-10-20"]
			.merging(extra) { $1 }
	}

	@Test func onlyTheFilesThatClaudeMustReadGetTheirText() {
		let old = """
			# Morning overview

			## My Open PRs

			- [ ] `M1` [`#12`](https://bb/12) [pr.md](file:///p/pr.md) Fix

			## Optional Work

			- [ ] `O1` Plan [kept.md](file:///p/kept.md)
			- [x] `O2` Done [ticked.md](file:///p/ticked.md)
			"""
		let files = [file("check.md", ["checkFindings": true, "outdated": "x"]), file("changed.md", ["changedAfterOldOverview": true]),
			file("pr.md"), file("kept.md"), file("ticked.md"), file("waits.md", ["outdated": "x", "changedAfterOldOverview": true]),
			file("declined.md", ["appTask": true, "newCommits": true]), file("quiet.md")]
		let result = MorningOverview.withTexts(files, old: old, unchangedTasks: ["O1"]) { "text of \($0.lastPathComponent)" }
		#expect(result.map { $0["text"] as? String } == ["text of check.md", "text of changed.md", "text of pr.md", nil, nil, nil, nil, nil])
		// Without an old overview, each file can have new facts.
		#expect(MorningOverview.withTexts([file("quiet.md")], old: nil, unchangedTasks: []) { _ in "t" }.first?["text"] as? String == "t")
	}

	@Test func aLongTextStopsAtALineEndAndTheTotalHasALimit() {
		let line = String(repeating: "a", count: 999) + "\n"
		let long = String(repeating: line, count: 60)
		let files = (1...5).map { file("f\($0).md", ["changedAfterOldOverview": true, "changedOn": "2026-10-0\($0)"]) }
		let result = MorningOverview.withTexts(files, old: "# Morning overview\n", unchangedTasks: []) { _ in long }
		let texts = result.map { $0["text"] as? String }
		// The newest files come first, and each text stops at 50 lines. After 3 texts, the total is full.
		#expect(texts.map { $0 == nil } == [true, true, false, false, false])
		#expect(texts.compactMap { $0 }.allSatisfy { $0.utf8.count == 50_000 && $0.hasSuffix("\n") })
		#expect(result.filter { $0["textCut"] as? Bool == true }.count == 3)
	}
}

@Suite struct MorningOverviewFileTextPlanTests {
	private func file(_ name: String, _ extra: [String: Any] = [:]) -> [String: Any] {
		["name": name, "url": "file:///p/\(name)", "changedAfterOldOverview": false, "newCommits": false, "changedOn": "2026-10-20"]
			.merging(extra) { $1 }
	}

	@Test func aChangedPlanNeedsRecentButAPlanOfAnOldTaskDoesNot() {
		let old = "# Morning overview\n\n## My Open PRs\n\n- [ ] `M1` [`#12`](https://bb/12) [old-plan.md](file:///p/old-plan.md) Fix\n"
		let files = [file("old-plan.md", ["recent": false]), file("stale-plan.md", ["recent": false, "changedAfterOldOverview": true]),
			file("new-plan.md", ["recent": true, "changedAfterOldOverview": true]), file("report.md", ["changedAfterOldOverview": true])]
		let result = MorningOverview.withTexts(files, planCount: 3, old: old, unchangedTasks: []) { _ in "t" }
		#expect(result.map { $0["text"] != nil } == [true, false, true, true])
	}

	@Test func theTotalNeverGoesAboveTheLimit() {
		let text = String(repeating: String(repeating: "a", count: 99) + "\n", count: 490)
		let files = (1...4).map { file("f\($0).md", ["changedAfterOldOverview": true, "changedOn": "2026-10-0\($0)"]) }
			+ [file("small.md", ["changedAfterOldOverview": true, "changedOn": "2026-09-01"])]
		let result = MorningOverview.withTexts(files, old: "# Morning overview\n", unchangedTasks: []) { $0.lastPathComponent == "small.md" ? "s\n" : text }
		let texts = result.compactMap { $0["text"] as? String }
		// 3 texts of 49,000 bytes fit, the 4th does not, and the small file still fits.
		#expect(texts.count == 4)
		#expect(texts.reduce(0) { $0 + $1.utf8.count } <= MorningOverview.fileTextsLimit)
		#expect(result.last?["text"] as? String == "s\n")
	}
}
