import Foundation

/// GET requests to the Slack Web API with the user token of the user. A user token is the only kind that can search.
struct Slack {
	static let tokenVariable = "SLACK_USER_TOKEN"
	/// Messages shorter than this, e.g. »ok« or »thanks«, say nothing special.
	static let minimumLength = 15
	static let textLimit = 300

	let token: String
	let get: (URLRequest) async throws -> (Data, Int)

	enum Failure: Error, CustomStringConvertible {
		case noToken, status(Int), api(String)

		var description: String {
			switch self {
			case .noToken: "\(Slack.tokenVariable) is not set in the login shell."
			case .status(429): "Slack answered with HTTP 429: too many requests."
			case .status(let code): "Slack answered with HTTP \(code)."
			case .api(let error): "Slack answered with the error »\(error)«."
			}
		}
	}

	struct User {
		var name: String
		var isBot: Bool
	}

	struct Message {
		/// `#name`, `DM with <name>`, or `Group DM with <names>`.
		var channel: String
		var user: String
		var time: Date
		var text: String
		var permalink: String
		/// An answer in a thread.
		var isReply: Bool
	}

	/// The answer of a method. Slack answers an error with HTTP 200 and `ok: false`.
	func call(_ method: String, _ query: [String: String]) async throws -> [String: Any] {
		var components = URLComponents(string: "https://slack.com/api/\(method)")!
		components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
		var request = URLRequest(url: components.url!)
		// The token goes in the header, never in the URL.
		request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		let data: Data, status: Int
		do {
			(data, status) = try await get(request)
		} catch is URLError {
			// A second try covers a short network error, e.g. right after the Mac woke up.
			(data, status) = try await get(request)
		}
		guard status == 200 else { throw Failure.status(status) }
		let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
		guard json["ok"] as? Bool == true else { throw Failure.api(json["error"] as? String ?? "no answer") }
		return json
	}

	/// The items of all pages of a method with cursor paging.
	private func pages(_ method: String, _ query: [String: String], key: String, maxPages: Int = 50) async throws -> [[String: Any]] {
		var items: [[String: Any]] = []
		var cursor: String?
		for _ in 0..<maxPages {
			var query = query
			if let cursor { query["cursor"] = cursor }
			let json = try await call(method, query)
			items += json[key] as? [[String: Any]] ?? []
			guard let next = (json["response_metadata"] as? [String: Any])?["next_cursor"] as? String, !next.isEmpty else { break }
			cursor = next
		}
		return items
	}

	/// The users of the workspace by ID.
	func users() async throws -> [String: User] {
		var users: [String: User] = [:]
		for member in try await pages("users.list", ["limit": "200"], key: "members") {
			guard let id = member["id"] as? String else { continue }
			let profile = member["profile"] as? [String: Any]
			let name = [profile?["display_name"], member["real_name"], member["name"]].lazy
				.compactMap { $0 as? String }.first { !$0.isEmpty } ?? id
			users[id] = User(name: name, isBot: member["is_bot"] as? Bool == true || id == "USLACKBOT")
		}
		return users
	}

	/// The channels, DMs and group DMs that the user is a member of: the name by ID. A DM has no name.
	func memberChannels() async throws -> [String: String] {
		let channels = try await pages("users.conversations",
			["types": "public_channel,private_channel,mpim,im", "exclude_archived": "true", "limit": "200"], key: "channels")
		return Dictionary(channels.compactMap { channel in (channel["id"] as? String).map { ($0, channel["name"] as? String ?? "") } },
			uniquingKeysWith: { first, _ in first })
	}

	/// The messages from `start` on, newest first, from people and in the conversations of the user.
	/// - Parameter maxPages: Each page has 100 messages.
	/// - Returns: The messages, and whether more pages were left.
	func messages(since start: Date, calendar: Calendar, maxPages: Int = 10) async throws -> (messages: [Message], isCut: Bool) {
		let users = try await users()
		let channels = try await memberChannels()
		// `after:` names a day and leaves that day out, so the search starts a day early and the time filter cuts.
		let dayFormatter = DateFormatter()
		dayFormatter.locale = Locale(identifier: "en_US_POSIX")
		dayFormatter.calendar = calendar
		dayFormatter.timeZone = calendar.timeZone
		dayFormatter.dateFormat = "yyyy-MM-dd"
		let dayBefore = calendar.date(byAdding: .day, value: -1, to: start)!
		var messages: [Message] = []
		for page in 1...maxPages {
			let json = try await call("search.messages", ["query": "after:\(dayFormatter.string(from: dayBefore))", "sort": "timestamp",
				"sort_dir": "desc", "count": "100", "page": "\(page)"])
			let result = json["messages"] as? [String: Any]
			let matches = result?["matches"] as? [[String: Any]] ?? []
			var reachedStart = false
			for match in matches {
				guard let time = (match["ts"] as? String).flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) else { continue }
				if time < start {
					reachedStart = true
					continue
				}
				if let message = Self.message(match, time: time, users: users, channels: channels) { messages.append(message) }
			}
			let pages = (result?["paging"] as? [String: Any])?["pages"] as? Int ?? 1
			if reachedStart || page >= pages { return (messages, false) }
		}
		return (messages, true)
	}

	/// A match of the search as a message, or `nil` for a bot, a conversation of others, or a short text.
	/// - Parameter channels: The conversations of the user, the name by ID.
	static func message(_ match: [String: Any], time: Date, users: [String: User], channels: [String: String]) -> Message? {
		guard match["bot_id"] == nil, let userID = match["user"] as? String, let user = users[userID], !user.isBot,
			let channel = match["channel"] as? [String: Any], let channelID = channel["id"] as? String, channels[channelID] != nil,
			let permalink = match["permalink"] as? String else { return nil }
		let text = readable(match["text"] as? String ?? "", users: users, channels: channels).trimmingCharacters(in: .whitespacesAndNewlines)
		guard text.count >= minimumLength else { return nil }
		return Message(channel: label(of: channel, users: users), user: user.name, time: time, text: text.cut(to: textLimit),
			permalink: permalink, isReply: permalink.contains("thread_ts="))
	}

	/// `#name`, `DM with <name>`, or `Group DM with <names>`. A DM has an ID that starts with `D` and the user ID of the
	/// other person as its name, a group DM a name like `mpdm-anna--ben--me-1`.
	static func label(of channel: [String: Any], users: [String: User]) -> String {
		let name = channel["name"] as? String ?? "?"
		let id = channel["id"] as? String ?? ""
		if channel["is_im"] as? Bool == true || id.hasPrefix("D") {
			return "DM with \(users[name]?.name ?? name)"
		}
		if channel["is_mpim"] as? Bool == true || name.hasPrefix("mpdm-") {
			var names = name.dropFirst("mpdm-".count)
			if let suffix = names.range(of: "-[0-9]+$", options: .regularExpression) { names.removeSubrange(suffix) }
			return "Group DM with " + names.components(separatedBy: "--").joined(separator: ", ")
		}
		return "#" + name
	}

	/// The text with names instead of the IDs of mentions, and labels instead of the markup of links. The run cannot look
	/// up an ID. A mention can have an empty label, e.g. `<#C1|>`.
	/// - Parameter channels: The names of channels by ID.
	static func readable(_ text: String, users: [String: User], channels: [String: String] = [:]) -> String {
		let markup = try! NSRegularExpression(pattern: "<([^<>]+)>")
		var result = ""
		var rest = text[...]
		for match in markup.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
			guard let range = Range(match.range, in: text), let inner = Range(match.range(at: 1), in: text) else { continue }
			result += text[rest.startIndex..<range.lowerBound]
			let parts = text[inner].split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
			let target = parts[0], label = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
			let id = String(target.dropFirst())
			if target.hasPrefix("@") {
				result += "@" + (label ?? users[id]?.name ?? id)
			} else if target.hasPrefix("#") {
				result += "#" + (label ?? channels[id].flatMap { $0.isEmpty ? nil : $0 } ?? id)
			} else if target.hasPrefix("!") {
				// `<!here>`, `<!channel>`, `<!subteam^ID|@team>`.
				result += label ?? "@" + id
			} else {
				result += label ?? target
			}
			rest = text[range.upperBound...]
		}
		result += rest
		return result.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
			.replacingOccurrences(of: "&amp;", with: "&")
	}
}
