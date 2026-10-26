import Foundation
import Testing
@testable import ClaudeCodeNotifier

/// A Slack workspace for the fake requests: three users, two channels of the user, and one channel of others.
private func slackAnswer(to request: URLRequest, matches: [[String: Any]], pages: Int = 1) -> (Data, Int) {
	let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
	let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
	let json: [String: Any] = switch components.path {
	case "/api/users.list" where query["cursor"] == nil:
		["ok": true, "members": [
			["id": "U1", "name": "nils", "profile": ["display_name": "Nils"]],
			["id": "U2", "name": "milad", "real_name": "Milad M", "profile": ["display_name": ""]],
		], "response_metadata": ["next_cursor": "c2"]]
	case "/api/users.list":
		["ok": true, "members": [["id": "B1", "name": "ci", "is_bot": true]], "response_metadata": ["next_cursor": ""]]
	case "/api/users.conversations":
		["ok": true, "channels": [["id": "C1"], ["id": "D1"], ["id": "G1"]]]
	case "/api/search.messages":
		["ok": true, "messages": ["matches": matches, "paging": ["pages": pages, "page": Int(query["page"] ?? "1") ?? 1]]]
	default:
		["ok": false, "error": "unknown_method"]
	}
	return (try! JSONSerialization.data(withJSONObject: json), 200)
}

private func match(_ ts: TimeInterval, user: String = "U2", channel: [String: Any] = ["id": "C1", "name": "dev"],
	text: String = "Release 11.1 goes live on Thursday.", permalink: String = "https://x.slack.com/archives/C1/p1") -> [String: Any] {
	["ts": String(format: "%.6f", ts), "user": user, "channel": channel, "text": text, "permalink": permalink]
}

/// The sprint of the tests starts on Tuesday, 2026-10-20, 11:00 UTC.
private let start = Date(timeIntervalSince1970: 1_792_494_000)

@Suite struct SlackTests {
	@Test func callSendsTheTokenInTheHeaderAndThrowsOnAnError() async {
		let requests = Locked<[URLRequest]>([])
		let slack = Slack(token: "xoxp-1") { request in
			requests.update { $0.append(request) }
			return (Data(#"{"ok": false, "error": "missing_scope"}"#.utf8), 200)
		}
		await #expect {
			try await slack.call("search.messages", ["query": "x"])
		} throws: { ($0 as? Slack.Failure)?.description == "Slack answered with the error »missing_scope«." }
		let request = requests.update { $0.first }
		#expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer xoxp-1")
		#expect(request?.httpMethod == "GET")
		#expect(request?.url?.absoluteString.contains("xoxp") == false)
	}

	@Test func tooManyRequestsThrows() async {
		let slack = Slack(token: "t") { _ in (Data(), 429) }
		await #expect(throws: Slack.Failure.self) { try await slack.call("users.list", [:]) }
	}

	@Test func usersFollowTheCursorAndKnowTheBots() async throws {
		let slack = Slack(token: "t") { slackAnswer(to: $0, matches: []) }
		let users = try await slack.users()
		#expect(users["U1"]?.name == "Nils")
		#expect(users["U2"]?.name == "Milad M")
		#expect(users["B1"]?.isBot == true)
	}

	@Test func messagesKeepOnlyPeopleInTheConversationsOfTheUserSinceTheStart() async throws {
		let requests = Locked<[URLRequest]>([])
		let matches = [
			match(start.timeIntervalSince1970 + 7_200),
			match(start.timeIntervalSince1970 + 3_600, user: "B1"), // bot
			match(start.timeIntervalSince1970 + 3_000, channel: ["id": "C9", "name": "other-team"]), // not a member
			match(start.timeIntervalSince1970 + 2_000, text: "ok, thanks"), // short
			match(start.timeIntervalSince1970 + 1_000, channel: ["id": "D1", "name": "U2", "is_im": true],
				text: "Can you review <@U1> my PR <https://bitbucket.org/x|#4270>?", permalink: "https://x.slack.com/archives/D1/p2?thread_ts=1"),
			match(start.timeIntervalSince1970 - 60), // before the sprint
		]
		let slack = Slack(token: "t") { request in
			requests.update { $0.append(request) }
			return slackAnswer(to: request, matches: matches, pages: 3)
		}
		let (messages, isCut) = try await slack.messages(since: start, calendar: utcCalendar)
		#expect(!isCut)
		#expect(messages.map(\.channel) == ["#dev", "DM with Milad M"])
		#expect(messages.map(\.user) == ["Milad M", "Milad M"])
		#expect(messages[1].text == "Can you review @Nils my PR #4270?")
		#expect(messages.map(\.isReply) == [false, true])
		// The page with a message before the start is the last one.
		let searches = requests.update { $0 }.filter { $0.url!.path == "/api/search.messages" }
		#expect(searches.count == 1)
		let query = URLComponents(url: searches[0].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
		#expect(query.first { $0.name == "query" }?.value == "after:2026-10-19")
		#expect(query.first { $0.name == "sort_dir" }?.value == "desc")
	}

	@Test func messagesSayWhenPagesWereLeft() async throws {
		let slack = Slack(token: "t") { slackAnswer(to: $0, matches: [match(start.timeIntervalSince1970 + 60)], pages: 50) }
		let (messages, isCut) = try await slack.messages(since: start, calendar: utcCalendar, maxPages: 2)
		#expect(messages.count == 2)
		#expect(isCut)
	}

	@Test(arguments: [
		(["id": "C1", "name": "dev"], "#dev"),
		(["id": "D1", "name": "U2", "is_im": true], "DM with Milad"),
		(["id": "D2", "name": "U9"], "DM with U9"),
		(["id": "G1", "name": "mpdm-anna--ben--nils-1", "is_mpim": true], "Group DM with anna, ben, nils"),
	] as [([String: Any], String)])
	func labelNamesTheConversation(channel: [String: Any], label: String) {
		#expect(Slack.label(of: channel, users: ["U2": .init(name: "Milad", isBot: false)]) == label)
	}

	@Test func readableReplacesTheMarkup() {
		let users = ["U1": Slack.User(name: "Nils", isBot: false)]
		#expect(Slack.readable("<@U1> and <@U7|rui> in <#C1|dev>: <!here> see <https://a.b|the doc> or <https://c.d> &amp; &lt;3",
			users: users) == "@Nils and @rui in #dev: @here see the doc or https://c.d & <3")
		#expect(Slack.readable("<!subteam^S1|@frontend> ping", users: users) == "@frontend ping")
		#expect(Slack.readable("no markup", users: users) == "no markup")
	}

	@Test func readableNamesAChannelWithAnEmptyLabel() {
		#expect(Slack.readable("see <#C1|> and <#C9|>", users: [:], channels: ["C1": "dev"]) == "see #dev and #C9")
	}

	@Test func callTriesOnceMoreAfterANetworkError() async throws {
		let count = Locked(0)
		let slack = Slack(token: "t") { _ in
			if count.update({ $0 += 1; return $0 }) == 1 { throw URLError(.networkConnectionLost) }
			return (Data(#"{"ok": true}"#.utf8), 200)
		}
		_ = try await slack.call("users.list", [:])
		#expect(count.update { $0 } == 2)
	}
}
