import Foundation
import Testing
@testable import ClaudeCodeNotifier

/// A ticket in an answer of Jira.
func jiraIssue(_ key: String, status: String = "In Progress", category: String = "indeterminate", links: [[String: Any]] = []) -> [String: Any] {
	["key": key, "fields": ["summary": "Title of \(key)", "status": ["name": status, "statusCategory": ["key": category]], "issuelinks": links]]
}

/// An »is blocked by« link to `key` on the ticket that `key` blocks.
func blockedByLink(_ key: String, done: Bool = false) -> [String: Any] {
	["type": ["name": "Blocks", "inward": "is blocked by", "outward": "blocks"],
		"inwardIssue": ["key": key, "fields": ["status": ["name": done ? "Done" : "Open", "statusCategory": ["key": done ? "done" : "new"]]]]]
}

/// A »blocks« link to `key` on the ticket that blocks `key`.
func blocksLink(_ key: String, done: Bool = false) -> [String: Any] {
	["type": ["name": "Blocks", "inward": "is blocked by", "outward": "blocks"],
		"outwardIssue": ["key": key, "fields": ["status": ["name": done ? "Done" : "Open", "statusCategory": ["key": done ? "done" : "new"]]]]]
}

func jiraJSON(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

extension ReportFixture {
	/// The credentials with a Jira token. The site comes from the old overview.
	nonisolated static let jiraCredentials = credentials.merging([Jira.tokenVariable: "jira-token"]) { $1 }

	/// The answers of Jira: two sprint tickets, one forgotten ticket, and a done ticket for each other ID.
	nonisolated static func jiraBody(of request: URLRequest) -> Data {
		let url = request.url!
		if url.path.hasSuffix("/_edge/tenant_info") { return jiraJSON(["cloudId": "abc-123"]) }
		if url.path.hasSuffix("/issue/bulkfetch") {
			let keys = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])?["issueIdsOrKeys"] as? [String] ?? []
			return jiraJSON(["issues": keys.map { jiraIssue($0, status: "Done", category: "done") }, "issueErrors": []])
		}
		if url.query?.contains("openSprints") == true {
			return jiraJSON(["issues": [jiraIssue("PROJ-1", links: [blockedByLink("PROJ-9"), blockedByLink("PROJ-8", done: true)]),
				jiraIssue("PROJ-2", status: "Blocked", links: [blocksLink("PROJ-7")])], "isLast": true])
		}
		return jiraJSON(["issues": [jiraIssue("PROJ-3", status: "Untested")], "isLast": true])
	}

	/// An old overview with a ticket link of the site `drplano.atlassian.net`.
	func writeOldOverviewWithTicketLink() throws {
		try """
			# Morning overview

			Updated: 2026-10-26 06:30

			## Open Branches

			- [ ] [PROJ-4](https://drplano.atlassian.net/browse/PROJ-4) Old ticket with a UTF-8 text, also for PROJ-1

			""".write(to: fileURL, atomically: true, encoding: .utf8)
	}
}

@Suite struct JiraTests {
	private static let environment = [Jira.tokenVariable: "jira-token", Jira.emailVariable: "me@example.com", Jira.siteVariable: "drplano.atlassian.net"]

	/// A Jira that answers each request with `answer`, and the requests that it got.
	private static func jira(_ answer: @escaping @Sendable (URLRequest) -> (Data, Int)) -> (Jira, Locked<[URLRequest]>) {
		let requests = Locked<[URLRequest]>([])
		let jira = Jira(api: URL(string: "https://api.atlassian.com/ex/jira/abc-123/rest/api/3")!, browseURL: "https://x.atlassian.net/browse/",
			authorization: "Basic x") { request in
			requests.update { $0.append(request) }
			return answer(request)
		}
		return (jira, requests)
	}

	@Test(arguments: [
		("drplano.atlassian.net", "https://drplano.atlassian.net"),
		(" https://drplano.atlassian.net/browse/ \n", "https://drplano.atlassian.net"),
		("http://drplano.atlassian.net", nil),
		("", nil),
	] as [(String, String?)])
	func siteFromAHostOrAURL(text: String, site: String?) {
		#expect(Jira.site(of: text)?.absoluteString == site)
	}

	@Test func siteFromTheVariableBeforeTheOldOverview() {
		let old = "- [ ] [PROJ-4](https://old.atlassian.net/browse/PROJ-4) Title"
		#expect(Jira.site(environment: [Jira.siteVariable: "new.atlassian.net"], old: old)?.absoluteString == "https://new.atlassian.net")
		#expect(Jira.site(environment: [:], old: old)?.absoluteString == "https://old.atlassian.net")
		#expect(Jira.site(environment: [:], old: nil) == nil)
	}

	@Test func connectGetsTheCloudIDWithoutCredentials() async throws {
		let requests = Locked<[URLRequest]>([])
		let jira = try await Jira.connect(environment: Self.environment, old: nil) { request in
			requests.update { $0.append(request) }
			return (jiraJSON(["cloudId": "abc-123"]), 200)
		}
		let request = try #require(requests.update { $0 }.first)
		#expect(request.url?.absoluteString == "https://drplano.atlassian.net/_edge/tenant_info")
		#expect(request.value(forHTTPHeaderField: "Authorization") == nil)
		#expect(jira.api.absoluteString == "https://api.atlassian.com/ex/jira/abc-123/rest/api/3")
		#expect(jira.browseURL == "https://drplano.atlassian.net/browse/")
		#expect(jira.authorization == "Basic " + Data("me@example.com:jira-token".utf8).base64EncodedString())
	}

	@Test func connectAcceptsTheCloudIDOfAnOldSite() async throws {
		let jira = try await Jira.connect(environment: Self.environment, old: nil) { _ in
			(jiraJSON(["cloudId": "fff89a1a-52c8-11e5-91b2-3c15c2bd8caa-ecosystem"]), 200)
		}
		#expect(jira.api.absoluteString == "https://api.atlassian.com/ex/jira/fff89a1a-52c8-11e5-91b2-3c15c2bd8caa-ecosystem/rest/api/3")
	}

	@Test func siteOfTheOldOverviewComesFromTheSectionsOfClaude() {
		let old = """
			# Morning overview

			## My Notes

			- [ ] See [JRACLOUD-1](https://jira.atlassian.com/browse/JRACLOUD-1)

			## Optional Work

			- [ ] [PROJ-4](https://drplano.atlassian.net/browse/PROJ-4) Title

			"""
		#expect(Jira.site(environment: [:], old: old)?.absoluteString == "https://drplano.atlassian.net")
	}

	@Test func aRefusedTokenSaysWhatToDo() {
		#expect(Jira.Failure.status(401).description.contains("expired. Make a new token."))
		#expect(Jira.Failure.status(403).description.contains("read:jira-work"))
		#expect(Jira.Failure.status(500).description == "Jira answered with HTTP 500.")
	}

	@Test func connectTakesTheBitbucketEmailWithoutAJiraEmail() async throws {
		let environment = [Jira.tokenVariable: "jira-token", Bitbucket.emailVariable: "bb@example.com", Jira.siteVariable: "x.atlassian.net"]
		let jira = try await Jira.connect(environment: environment, old: nil) { _ in (jiraJSON(["cloudId": "abc"]), 200) }
		#expect(jira.authorization == "Basic " + Data("bb@example.com:jira-token".utf8).base64EncodedString())
	}

	@Test func connectFailsWithoutTokenSiteOrValidCloudID() async {
		let answer: (URLRequest) async throws -> (Data, Int) = { _ in (jiraJSON(["cloudId": "../evil"]), 200) }
		await #expect(throws: Jira.Failure.self) { try await Jira.connect(environment: [Jira.emailVariable: "me@example.com"], old: nil, get: answer) }
		await #expect(throws: Jira.Failure.self) {
			try await Jira.connect(environment: [Jira.tokenVariable: "t", Jira.emailVariable: "me@example.com"], old: nil, get: answer)
		}
		await #expect(throws: Jira.Failure.self) { try await Jira.connect(environment: Self.environment, old: nil, get: answer) }
	}

	@Test func searchFollowsThePageTokensOnTheGateway() async throws {
		let (jira, requests) = Self.jira { request in
			let isFirst = request.url!.query?.contains("nextPageToken") != true
			return (jiraJSON(isFirst ? ["issues": [jiraIssue("A-1")], "nextPageToken": "t2", "isLast": false]
				: ["issues": [jiraIssue("A-2")], "isLast": true]), 200)
		}
		let issues = try await jira.search("assignee = currentUser() AND status in (\"In Progress\")")
		#expect(issues.map { $0["key"] as? String } == ["A-1", "A-2"])
		let urls = requests.update { $0 }.map { $0.url! }
		#expect(urls.map(\.host) == ["api.atlassian.com", "api.atlassian.com"])
		#expect(urls.allSatisfy { $0.path == "/ex/jira/abc-123/rest/api/3/search/jql" })
		let query = URLComponents(url: urls[1], resolvingAgainstBaseURL: false)?.queryItems ?? []
		#expect(query.first { $0.name == "jql" }?.value == "assignee = currentUser() AND status in (\"In Progress\")")
		#expect(query.first { $0.name == "fields" }?.value == "summary,status,issuelinks")
		#expect(query.first { $0.name == "maxResults" }?.value == "100")
		#expect(query.first { $0.name == "nextPageToken" }?.value == "t2")
		#expect(requests.update { $0 }.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Basic x" })
	}

	@Test func searchStopsAfterMaxPages() async throws {
		let (jira, requests) = Self.jira { _ in (jiraJSON(["issues": [jiraIssue("A-1")], "nextPageToken": "next"]), 200) }
		#expect(try await jira.search("x", maxPages: 3).count == 3)
		#expect(requests.update { $0 }.count == 3)
	}

	@Test func ticketsSendOnePostForEachHundredIDs() async throws {
		let (jira, requests) = Self.jira { _ in (jiraJSON(["issues": [jiraIssue("A-1")], "issueErrors": [["errorMessages": ["unknown"]]]]), 200) }
		let keys = (1...150).map { "A-\($0)" }
		#expect(try await jira.tickets(keys).count == 2)
		let sent = requests.update { $0 }
		#expect(sent.map(\.httpMethod) == ["POST", "POST"])
		#expect(sent.allSatisfy { $0.url?.path == "/ex/jira/abc-123/rest/api/3/issue/bulkfetch" })
		let bodies = sent.compactMap { try? JSONSerialization.jsonObject(with: $0.httpBody ?? Data()) as? [String: Any] }
		#expect(bodies.map { ($0["issueIdsOrKeys"] as? [String])?.count } == [100, 50])
		#expect(bodies.first?["fields"] as? [String] == ["summary", "status", "issuelinks"])
		#expect(try await jira.tickets([]).isEmpty)
		#expect(requests.update { $0 }.count == 2)
	}

	@Test func otherStatusThrows() async {
		let (jira, _) = Self.jira { _ in (Data(), 401) }
		await #expect(throws: Jira.Failure.self) { try await jira.search("x") }
	}

	@Test func factsOfATicket() throws {
		let blocked = try #require(Jira.facts(of: jiraIssue("A-1", links: [blockedByLink("A-9"), blockedByLink("A-8", done: true),
			blocksLink("A-7"), blocksLink("A-6", done: true)])))
		#expect(blocked.key == "A-1")
		#expect(blocked.facts["summary"] as? String == "Title of A-1")
		#expect(blocked.facts["status"] as? String == "In Progress")
		#expect(blocked.facts["blocked"] as? Bool == true)
		#expect(blocked.facts["blockedBy"] as? [String] == ["A-9"])
		#expect(blocked.facts["blocks"] as? [String] == ["A-7"])
		#expect(blocked.facts["done"] as? Bool == false)
		let free = try #require(Jira.facts(of: jiraIssue("A-2", links: [blockedByLink("A-8", done: true)])))
		#expect(free.facts["blocked"] as? Bool == false)
		#expect(Jira.facts(of: jiraIssue("A-3", status: "Blocked"))?.facts["blocked"] as? Bool == true)
		#expect(Jira.facts(of: jiraIssue("A-4", status: "Closed", category: "done"))?.facts["done"] as? Bool == true)
		#expect(Jira.facts(of: ["fields": [:]]) == nil)
	}

	@Test func forgottenTicketsWithoutTheStateUntestedKeepOnlyTheTwoStates() async throws {
		let (jira, requests) = Self.jira { request in
			guard request.url!.query?.contains("statusCategory") == true else { return (Data(), 400) }
			return (jiraJSON(["issues": [jiraIssue("A-1"), jiraIssue("A-2", status: "In Review"), jiraIssue("A-3", status: "Untested")],
				"isLast": true]), 200)
		}
		#expect(try await MorningOverview.forgottenTickets(jira).map { $0["key"] as? String } == ["A-1", "A-3"])
		#expect(requests.update { $0 }.count == 2)
	}

	@Test func ticketKeysWithAKnownProjectKeyOnly() {
		#expect(MorningOverview.ticketKeys(in: ["feature/proj-12-fix", "PROJ-3 and UTF-8", "PROJ-3, OTHER-1"], projectKeys: ["PROJ"])
			== ["PROJ-12", "PROJ-3"])
	}

	@Test func aFailedRequestForTheOtherTicketsKeepsTheSearches() async {
		let (jira, _) = Self.jira { _ in (Data(), 500) }
		let search = MorningOverview.JiraSearch(browseURL: nil, result: .success((jira, [jiraIssue("PROJ-1")], [jiraIssue("PROJ-3")])))
		let data = await MorningOverview.jiraData(search, texts: ["PROJ-4"], projectKeys: ["PROJ"])
		#expect(data["error"] == nil)
		#expect(data["sprint"] as? [String] == ["PROJ-1"])
		#expect(data["forgotten"] as? [String] == ["PROJ-3"])
		#expect((data["tickets"] as? [String: Any])?.keys.sorted() == ["PROJ-1", "PROJ-3"])
	}

	@Test func jiraDataWithAFailureKeepsTheTicketLinks() async {
		let search = MorningOverview.JiraSearch(browseURL: "https://x.atlassian.net/browse/", result: .failure(Jira.Failure.noCredentials))
		let data = await MorningOverview.jiraData(search, texts: ["PROJ-1"], projectKeys: ["PROJ"])
		#expect(data["browseURL"] as? String == "https://x.atlassian.net/browse/")
		#expect(data["error"] as? String == Jira.Failure.noCredentials.description)
		#expect(data["tickets"] == nil)
	}
}

@MainActor @Suite struct MorningOverviewJiraTests {
	@Test func inputHoldsTheTicketsOfJira() async throws {
		let fixture = try ReportFixture(kind: .morningOverview, claudeOutput: overviewText, environment: ReportFixture.jiraCredentials,
			body: { ReportFixture.morningBody(of: $0) })
		defer { fixture.cleanUp() }
		try fixture.writeOldOverviewWithTicketLink()
		// A plan of the project with a ticket in its name.
		let notes = fixture.folder.appendingPathComponent("notes")
		try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
		try "# Notes\n".write(to: notes.appendingPathComponent("PROJ-5-notes.md"), atomically: true, encoding: .utf8)
		await fixture.report.update()
		let jira = try #require(try fixture.input["jira"] as? [String: Any])
		#expect(jira["error"] == nil)
		#expect(jira["browseURL"] as? String == "https://drplano.atlassian.net/browse/")
		#expect(jira["sprint"] as? [String] == ["PROJ-1", "PROJ-2"])
		#expect(jira["forgotten"] as? [String] == ["PROJ-3"])
		let tickets = try #require(jira["tickets"] as? [String: [String: Any]])
		#expect(tickets.keys.sorted() == ["PROJ-1", "PROJ-2", "PROJ-3", "PROJ-4", "PROJ-5"])
		#expect(tickets["PROJ-1"]?["blockedBy"] as? [String] == ["PROJ-9"])
		#expect(tickets["PROJ-2"]?["blocked"] as? Bool == true)
		#expect(tickets["PROJ-2"]?["blocks"] as? [String] == ["PROJ-7"])
		#expect(tickets["PROJ-4"]?["done"] as? Bool == true)

		// The old overview gives the site. Only the gateway gets the credentials. The bulk request asks only for the IDs
		// that the searches did not give, and not for a text like `UTF-8`.
		let requests = fixture.log.requests.filter { $0.url!.host != Bitbucket.host }
		#expect(requests.first?.url?.absoluteString == "https://drplano.atlassian.net/_edge/tenant_info")
		#expect(requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
		let authorization = "Basic " + Data("me@example.com:jira-token".utf8).base64EncodedString()
		for request in requests.dropFirst() {
			#expect(request.url?.host == Jira.gatewayHost)
			#expect(request.value(forHTTPHeaderField: "Authorization") == authorization)
		}
		let bulk = try #require(requests.first { $0.httpMethod == "POST" })
		let body = try #require(try JSONSerialization.jsonObject(with: bulk.httpBody ?? Data()) as? [String: Any])
		// PROJ-5 is in the name of a plan of the project.
		#expect(body["issueIdsOrKeys"] as? [String] == ["PROJ-4", "PROJ-5"])
		#expect(fixture.report.steps.map(\.name).contains("Jira"))
	}

	@Test func afterANetworkErrorJiraGetsASecondTry() async throws {
		let failed = Locked(false)
		let fixture = try ReportFixture(kind: .morningOverview, claudeOutput: overviewText, environment: ReportFixture.jiraCredentials,
			body: { ReportFixture.morningBody(of: $0) }, failure: { request in
				// The first two tries of the first Jira request fail, as right after a wake.
				guard request.url!.path.hasSuffix("/_edge/tenant_info") else { return nil }
				return failed.update { done in defer { done = true }; return done } ? nil : URLError(.notConnectedToInternet)
			})
		defer { fixture.cleanUp() }
		try fixture.writeOldOverviewWithTicketLink()
		await fixture.report.update()
		let jira = try #require(try fixture.input["jira"] as? [String: Any])
		#expect(jira["error"] == nil)
		#expect(jira["sprint"] as? [String] == ["PROJ-1", "PROJ-2"])
	}

	@Test func withoutATokenTheRunGoesOnWithTheReason() async throws {
		let fixture = try ReportFixture()
		defer { fixture.cleanUp() }
		try fixture.writeOldOverviewWithTicketLink()
		await fixture.report.update()
		let jira = try #require(try fixture.input["jira"] as? [String: Any])
		#expect(jira["error"] as? String == Jira.Failure.noCredentials.description)
		#expect(jira["browseURL"] as? String == "https://drplano.atlassian.net/browse/")
		#expect(fixture.log.requests.allSatisfy { $0.url!.host == Bitbucket.host })
		#expect(fixture.report.failure == nil)
	}
}
