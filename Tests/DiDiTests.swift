import Foundation
import Testing
@testable import ClaudeCodeNotifier

/// The answer of a run with `--output-format json`.
private func claudeAnswer(merges: [[String: Any]] = [["id": 7, "kind": "feature", "highlights": ["Needs a new token", "  "]],
	["id": 9, "kind": "bugfix", "highlights": []]],
	slack: [[String: Any]] = [["permalink": "https://x.slack.com/archives/C1/p1", "text": "Release 11.1 goes live on Thursday.\nBe ready."]]) -> String {
	let json: [String: Any] = ["type": "result", "is_error": false, "result": "{}", "structured_output": ["merges": merges, "slack": slack]]
	return String(decoding: try! JSONSerialization.data(withJSONObject: json), as: UTF8.self)
}

/// Bitbucket and Slack for DiDi: two merged pull requests of Nils, one of Rui, and one message in a channel of Nils.
private func didiBody(of request: URLRequest) -> Data {
	let path = request.url!.path
	if request.url!.host == "slack.com" {
		let json: [String: Any] = switch path {
		case "/api/users.list": ["ok": true, "members": [["id": "U2", "name": "milad", "profile": ["display_name": "Milad"]]]]
		case "/api/users.conversations": ["ok": true, "channels": [["id": "C1"]]]
		default: ["ok": true, "messages": ["paging": ["pages": 1], "matches": [
			["ts": "1793000000.000100", "user": "U2", "channel": ["id": "C1", "name": "dev"], "text": "Release 11.1 goes live on Thursday.",
				"permalink": "https://x.slack.com/archives/C1/p1"],
		]]]
		}
		return try! JSONSerialization.data(withJSONObject: json)
	}
	if path.hasSuffix("/comments") {
		return bitbucketPage([
			["content": ["raw": "The run takes 40 minutes."], "user": ["display_name": "Rui"], "inline": ["path": "a.yml"]],
			["content": ["raw": "gone"], "user": ["display_name": "Rui"], "deleted": true],
		])
	}
	let merged: [[String: Any]] = [
		["id": 9, "title": "PLANO-9 Second", "author": ["display_name": "Nils"], "closed_on": "2026-10-23T10:00:00+00:00", "comment_count": 0,
			"summary": ["raw": "Text ![shot](https://x/y.png) <!-- template -->more"], "links": ["html": ["href": "https://bb/9"]]],
		["id": 8, "title": "Of Rui", "author": ["display_name": "Rui"], "closed_on": "2026-10-22T10:00:00+00:00", "comment_count": 3],
		["id": 7, "title": "First\nline", "author": ["display_name": "Nils"], "closed_on": "2026-10-21T10:00:00+00:00", "comment_count": 2,
			"summary": ["raw": "Adds a step."], "links": ["html": ["href": "https://bb/7"]], "destination": ["branch": ["name": "dev"]]],
	]
	return bitbucketPage(merged)
}

private let expectedFile = """
	# DiDi

	Sprint: 2026-10-20 11:00 – 2026-10-27 07:00
	Updated: 2026-10-27 07:00

	## Merges

	- ✨ [`#7`](https://bb/7) First line
	    - Needs a new token
	- 🐛 [`#9`](https://bb/9) PLANO-9 Second

	## Slack

	- [`#dev`](https://x.slack.com/archives/C1/p1) Release 11.1 goes live on Thursday. Be ready.

	## Notes

	"""

extension ReportFixture {
	init(didi claudeOutput: String = claudeAnswer(), now: Date = tuesdayMorning, environment: [String: String] = credentials,
		status: Int = 200, beforeAnswer: @escaping @Sendable () -> Void = {}) throws {
		try self.init(kind: .didi, now: now, claudeOutput: claudeOutput, environment: environment, body: { didiBody(of: $0) }, status: status,
			beforeAnswer: beforeAnswer)
	}

	func writeFile(_ text: String) throws {
		try text.write(to: fileURL, atomically: true, encoding: .utf8)
	}

	var text: String {
		get throws { try String(contentsOf: fileURL, encoding: .utf8) }
	}
}

@MainActor @Suite struct DiDiTests {
	@Test(arguments: [
		(0, "2026-10-20 11:00"), // Tuesday, 7:00: the sprint of the last week
		(14_399, "2026-10-20 11:00"), // Tuesday, 10:59:59
		(14_400, "2026-10-27 11:00"), // Tuesday, 11:00
		(86_400, "2026-10-27 11:00"), // Wednesday
		(-86_400, "2026-10-20 11:00"), // Monday
	] as [(TimeInterval, String)])
	func sprintStartsOnTuesdayAtEleven(offset: TimeInterval, start: String) {
		let date = DiDi.sprintStart(before: tuesdayMorning.addingTimeInterval(offset), calendar: utcCalendar)
		#expect(Report.timestampFormatter(utcCalendar).string(from: date) == start)
	}

	@Test func sprintStartKeepsElevenInAWeekWithATimeChange() {
		var berlin = Calendar(identifier: .gregorian)
		berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
		// Tuesday, 2026-10-27, 7:00 in Berlin. The clocks went back on Sunday, 2026-10-25.
		let now = Date(timeIntervalSince1970: 1_793_080_800)
		#expect(Report.timestampFormatter(berlin).string(from: DiDi.sprintStart(before: now, calendar: berlin)) == "2026-10-20 11:00")
	}

	@Test(arguments: [
		(nil, -3_601, false), // Tuesday, 5:59:59
		(nil, -3_600, true), // Tuesday, 6:00
		("2026-10-26 18:00", 0, true), // a file of Monday
		("2026-10-27 06:30", 0, false), // a file of this morning
		(nil, 86_400, false), // Wednesday
	] as [(String?, TimeInterval, Bool)])
	func dueOnTuesdayFromSixOn(updated: String?, offset: TimeInterval, isDue: Bool) throws {
		let fixture = try ReportFixture(didi: "")
		defer { fixture.cleanUp() }
		if let updated { try fixture.writeFile("# DiDi\n\nSprint: x\nUpdated: \(updated)\n") }
		#expect(fixture.report.isDue(at: tuesdayMorning.addingTimeInterval(offset)) == isDue)
	}

	@Test func updateWritesTheMergesOfTheUserAndTheSlackPoints() async throws {
		let fixture = try ReportFixture(didi: claudeAnswer())
		defer { fixture.cleanUp() }
		await fixture.report.update()
		#expect(fixture.report.failure == nil)
		#expect(try fixture.text == expectedFile)
		#expect(fixture.log.posts.map(\.identifier) == ["didi"])
		#expect(fixture.log.posts.first?.subtitle == "DiDi")
		#expect(fixture.log.posts.first?.body == "2 merges, 1 Slack points. Click to open the file.")
	}

	@Test func inputHasTheMergedPullRequestsOfTheUserWithComments() async throws {
		let fixture = try ReportFixture(didi: claudeAnswer())
		defer { fixture.cleanUp() }
		await fixture.report.update()
		let input = try fixture.input
		#expect(input["sprint"] as? [String: String] == ["start": "2026-10-20 11:00", "end": "2026-10-27 07:00"])
		let pullRequests = try #require(input["pullRequests"] as? [[String: Any]])
		#expect(pullRequests.map { $0["id"] as? Int } == [7, 9])
		#expect(pullRequests[1]["description"] as? String == "Text  more")
		#expect(pullRequests[0]["comments"] as? [[String: String]] == [["author": "Rui", "text": "The run takes 40 minutes.", "file": "a.yml"]])
		#expect(pullRequests[1]["comments"] == nil)
		let messages = try #require((input["slack"] as? [String: Any])?["messages"] as? [[String: Any]])
		#expect(messages.map { $0["channel"] as? String } == ["#dev"])

		let merged = try #require(fixture.log.requests.first { $0.url!.path == "/2.0/repositories/ws/repo/pullrequests" })
		let query = URLComponents(url: merged.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
		#expect(query.first { $0.name == "q" }?.value == "state=\"MERGED\" AND closed_on >= 2026-10-20T11:00:00Z")
		#expect(query.first { $0.name == "state" } == nil)
		// Only the pull requests of Nils with comments get a comment request.
		#expect(fixture.log.requests.filter { $0.url!.path.hasSuffix("/comments") }.map(\.url!.path)
			== ["/2.0/repositories/ws/repo/pullrequests/7/comments"])
	}

	@Test func notesOfAHandWrittenFileStay() async throws {
		let fixture = try ReportFixture(didi: claudeAnswer())
		defer { fixture.cleanUp() }
		try fixture.writeFile("# DiDi\n\n- 🎉 enforce pipline-run\n")
		await fixture.report.update()
		#expect(try fixture.text == expectedFile + "\n- 🎉 enforce pipline-run\n")
		let backup = fixture.root.appendingPathComponent("support/didi/hand-written.md")
		#expect(try String(contentsOf: backup, encoding: .utf8) == "# DiDi\n\n- 🎉 enforce pipline-run\n")
	}

	@Test func notesWrittenDuringTheRunStay() async throws {
		let fileURL = Locked<URL?>(nil)
		let fixture = try ReportFixture(didi: claudeAnswer(), beforeAnswer: {
			try? "# DiDi\n\nSprint: 2026-10-13 11:00 – x\nUpdated: 2026-10-20 07:00\n\n## Notes\n\n  - new note\n".write(
				to: fileURL.update { $0! }, atomically: true, encoding: .utf8)
		})
		defer { fixture.cleanUp() }
		fileURL.update { $0 = fixture.fileURL }
		try fixture.writeFile("# DiDi\n\nUpdated: 2026-10-20 07:00\n\n## Notes\n\nold note\n")
		await fixture.report.update()
		#expect(try fixture.text.hasSuffix("## Notes\n\n  - new note\n"))
		#expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("support/didi/sprint-2026-10-13.md").path))
	}

	@Test(arguments: [
		(nil, ""),
		("# DiDi\n\n- 🎉 enforce pipline-run\n\n", "- 🎉 enforce pipline-run"),
		("Only text\n", "Only text"),
		("# DiDi\n\nUpdated: the README of X\n- mine\n", "Updated: the README of X\n- mine"),
		("# DiDi\n\nUpdated: 2026-10-27 07:00\n\n## Merges\n\n## Notes\n\nmine\n\n## More of mine\n", "mine\n\n## More of mine"),
	] as [(String?, String)])
	func notesComeFromTheOldFile(old: String?, notes: String) throws {
		#expect(try DiDi.notes(in: old) == notes)
	}

	@Test func fileOfTheAppWithoutTheNotesHeadingFails() async throws {
		let fixture = try ReportFixture(didi: claudeAnswer())
		defer { fixture.cleanUp() }
		let old = "# DiDi\n\nUpdated: 2026-10-27 06:30\n\n## Notizen\n\nmine\n"
		try fixture.writeFile(old)
		await fixture.report.update()
		#expect(fixture.report.failure == "didi.md has no »## Notes« heading. Add it again, so that the app keeps your notes.")
		#expect(try fixture.text == old)
	}

	@Test func networkErrorStopsTheRunForTheNextTry() async throws {
		let fixture = try ReportFixture(kind: .didi, claudeOutput: claudeAnswer(), body: { didiBody(of: $0) }, failure: { request in
			request.url!.host == "slack.com" ? URLError(.notConnectedToInternet) : nil
		})
		defer { fixture.cleanUp() }
		await fixture.report.update()
		#expect(fixture.claudeRun == nil)
		#expect(fixture.report.failure?.hasPrefix("No connection to Slack: ") == true)
	}

	@Test func textOfClaudeCannotAddLinks() async throws {
		let fixture = try ReportFixture(didi: claudeAnswer(
			merges: [["id": 7, "highlights": ["-40% bundle size", "# Heading", "see [this](https://evil) ![x](https://evil/i.png)"]],
				["id": 9, "highlights": ["<img src=https://evil> **Risk:** slow"]]],
			slack: [["permalink": "https://x.slack.com/archives/C1/p1", "text": "#release is frozen"]]))
		defer { fixture.cleanUp() }
		await fixture.report.update()
		let text = try fixture.text
		#expect(text.contains("    - -40% bundle size\n    - Heading\n    - see \\[this\\](https://evil) !\\[x\\](https://evil/i.png)\n"))
		#expect(text.contains("    - \\<img src=https://evil\\> **Risk:** slow\n"))
		#expect(text.contains("- [`#dev`](https://x.slack.com/archives/C1/p1) #release is frozen\n"))
	}

	@Test func readyBodyCountsOnlyTheSlackSectionOfTheApp() {
		let text = "# DiDi\n\n## Slack\n\n- [#dev](x) a\n\n## Notes\n\n## Slack\n\n- [#a](y) b\n- [#b](z) c\n"
		#expect(DiDi.readyBody(text, Report.Input(data: [:])) == "0 merges, 1 Slack points. Click to open the file.")
	}

	@Test func missingSlackTokenStopsTheRun() async throws {
		var environment = ReportFixture.credentials
		environment[Slack.tokenVariable] = nil
		let fixture = try ReportFixture(didi: claudeAnswer(slack: []), environment: environment)
		defer { fixture.cleanUp() }
		await fixture.report.update()
		#expect(fixture.claudeRun == nil)
		#expect(fixture.report.failure == "SLACK_USER_TOKEN is not set in the login shell.")
		#expect(fixture.log.posts.map(\.identifier) == ["didi-failed"])
	}

	@Test func bothSourcesFailingStopsTheRun() async throws {
		let fixture = try ReportFixture(didi: claudeAnswer(), status: 500)
		defer { fixture.cleanUp() }
		await fixture.report.update()
		#expect(fixture.claudeRun == nil)
		#expect(fixture.report.failure?.hasPrefix("No data. Bitbucket: ") == true)
		#expect(fixture.log.posts.map(\.identifier) == ["didi-failed"])
	}

	@Test(arguments: [
		(claudeAnswer(merges: [["id": 7, "highlights": []]]), "Claude did not answer for exactly the merged pull requests."),
		(claudeAnswer(merges: [["id": 7, "highlights": []], ["id": 9, "highlights": []], ["id": 8, "highlights": []]]),
			"Claude did not answer for exactly the merged pull requests."),
		(claudeAnswer(merges: [["id": 7, "highlights": []], ["id": 7, "highlights": []]]), "Claude named a pull request twice."),
		(claudeAnswer(slack: [["permalink": "https://evil.example.com", "text": "Click"]]), "Claude named a Slack message that is not in the data."),
		(#"{"is_error": true, "result": "Prompt is too long"}"#, "Claude gave no summary: Prompt is too long"),
		("not json", "Claude gave no summary: not json"),
	])
	func wrongAnswerFailsAndKeepsTheOldFile(output: String, failure: String) async throws {
		let fixture = try ReportFixture(didi: output)
		defer { fixture.cleanUp() }
		try fixture.writeFile("# DiDi\n\nold\n")
		await fixture.report.update()
		#expect(fixture.report.failure == failure)
		#expect(try fixture.text == "# DiDi\n\nold\n")
	}

	@Test func emptySprintGivesAValidFile() async throws {
		let fixture = try ReportFixture(kind: .didi, claudeOutput: claudeAnswer(merges: [], slack: []), body: { request in
			request.url!.host == "slack.com" ? Data(#"{"ok": true, "members": [], "channels": [], "messages": {"matches": []}}"#.utf8) : bitbucketPage([])
		})
		defer { fixture.cleanUp() }
		await fixture.report.update()
		#expect(try fixture.text.contains("## Merges\n\nNo merges yet.\n\n## Slack\n\nNothing special.\n\n## Notes\n"))
		#expect(fixture.log.posts.first?.body == "0 merges, 0 Slack points. Click to open the file.")
	}

	@Test func slackDataKeepsTheNewestWithinTheBudget() {
		let message = Slack.Message(channel: "#dev", user: "Milad", time: tuesdayMorning, text: String(repeating: "x", count: 300),
			permalink: "https://x", isReply: false)
		let data = DiDi.slackData(Array(repeating: message, count: 1_000), isCut: false, formatter: Report.timestampFormatter(utcCalendar))
		let kept = (data["messages"] as? [Any])?.count ?? 0
		#expect(kept > 500 && kept < 1_000)
		#expect(data["leftOut"] as? String == "\(1_000 - kept) older messages")
		#expect(DiDi.slackData([message], isCut: false, formatter: Report.timestampFormatter(utcCalendar))["leftOut"] == nil)
	}

	@Test(arguments: [
		("## Heading\nnext", "Heading next"),
		("- item", "item"),
		("1. first", "first"),
		("-40% size", "-40% size"),
		("#release is frozen", "#release is frozen"),
		("[🔥release relevant] PLANO-1 Fix", "\\[🔥release relevant\\] PLANO-1 Fix"),
	])
	func markdownTextIsOnePlainLine(text: String, result: String) {
		#expect(DiDi.markdownText(text) == result)
	}

	@Test(arguments: [
		("PLANO-197675 Start a run", "PLANO-197675", "Start a run"),
		("feature/PLANO-197417 Load the item", "PLANO-197417", "Load the item"),
		("[🔥release relevant] PLANO-1 Stop it", "PLANO-1", "[🔥release relevant] Stop it"),
		("NO_JIRA_ISSUE Fix NG01354", nil, nil),
	] as [(String, String?, String?)])
	func ticketComesFromTheTitle(title: String, id: String?, rest: String?) {
		let ticket = DiDi.ticket(in: title)
		#expect(ticket?.id == id)
		#expect(ticket?.title == rest)
	}

	@Test func titleLineLinksThePullRequestAndTheTicket() {
		#expect(DiDi.titleLine(id: 4265, url: "https://bb/4265", title: "PLANO-197675 Start a run", jiraBrowseURL: "https://x.atlassian.net/browse/")
			== "[`#4265`](https://bb/4265) [PLANO-197675](https://x.atlassian.net/browse/PLANO-197675) Start a run")
		#expect(DiDi.titleLine(id: 4265, url: "https://bb/4265", title: "PLANO-197675 Start a run", jiraBrowseURL: nil)
			== "[`#4265`](https://bb/4265) PLANO-197675 Start a run")
	}

	@Test func jiraSiteComesFromTheMorningOverview() {
		#expect(DiDi.jiraBrowseURL(in: "- [ ] [PLANO-1](https://x.atlassian.net/browse/PLANO-1) Do it") == "https://x.atlassian.net/browse/")
		#expect(DiDi.jiraBrowseURL(in: "- [ ] Nothing") == nil)
	}

	@Test func mergeLinksTheTicketWithTheSiteOfTheMorningOverview() async throws {
		let fixture = try ReportFixture(didi: claudeAnswer())
		defer { fixture.cleanUp() }
		try "- [ ] [PLANO-1](https://x.atlassian.net/browse/PLANO-1) Do it\n".write(
			to: fixture.folder.appendingPathComponent("morning-overview.md"), atomically: true, encoding: .utf8)
		await fixture.report.update()
		#expect(try fixture.text.contains("- 🐛 [`#9`](https://bb/9) [PLANO-9](https://x.atlassian.net/browse/PLANO-9) Second\n"))
	}

	@Test func mergeWithAnUnknownKindGetsNoEmoji() async throws {
		let fixture = try ReportFixture(didi: claudeAnswer(merges: [["id": 7, "kind": "party", "highlights": []], ["id": 9, "highlights": []]]))
		defer { fixture.cleanUp() }
		await fixture.report.update()
		let text = try fixture.text
		#expect(text.contains("\n- [`#7`](https://bb/7) First line\n- [`#9`](https://bb/9) PLANO-9 Second\n"))
	}
}
