import Foundation

extension Report.Kind {
	/// `didi.md`: the summary of the current sprint. The app fetches the merged pull requests of the user and the Slack
	/// messages of the sprint. The run only picks the highlights, and the app writes the file. The user's own text under
	/// »Notes« stays.
	static let didi = Report.Kind(
		title: "DiDi",
		fileName: "didi.md",
		promptResource: "didi-prompt",
		settingsKey: SettingsKey.updatesDiDi,
		schedule: Report.Schedule(weekdays: [DiDi.sprintWeekday], hour: 6),
		notificationID: "didi",
		access: .readsInputOnly(schema: DiDi.schema),
		timeout: 10 * 60,
		collect: DiDi.collect,
		render: DiDi.render,
		readyBody: DiDi.readyBody,
		backupName: DiDi.backupName
	)
}

enum DiDi {
	/// A sprint starts on Tuesday at 11:00.
	static let sprintWeekday = 3
	static let sprintHour = 11
	/// The most bytes of Slack messages for the run. The newest messages come first.
	static let slackBudget = 250_000
	static let descriptionLimit = 2000
	static let commentLimit = 10

	/// The kind of a merge. The run picks it, and the app writes its emoji in front of the title line.
	enum Kind: String, CaseIterable {
		case feature, improvement, bugfix, performance, maintenance, tests, docs

		var emoji: String {
			switch self {
			case .feature: "✨"
			case .improvement: "👌"
			case .bugfix: "🐛"
			case .performance: "⚡️"
			case .maintenance: "🧹"
			case .tests: "🧪"
			case .docs: "📝"
			}
		}
	}

	/// The shape of the answer of the run.
	static let schema = """
		{"type":"object","additionalProperties":false,"required":["merges","slack"],"properties":{\
		"merges":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["id","kind","highlights"],"properties":{\
		"id":{"type":"integer"},"kind":{"type":"string","enum":[\(Kind.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ","))]},\
		"highlights":{"type":"array","maxItems":3,"items":{"type":"string"}}}}},\
		"slack":{"type":"array","maxItems":10,"items":{"type":"object","additionalProperties":false,"required":["permalink","text"],\
		"properties":{"permalink":{"type":"string"},"text":{"type":"string"}}}}}}
		"""

	/// The start of the sprint of `now`: the last Tuesday at 11:00, or `now` itself at that time.
	static func sprintStart(before now: Date, calendar: Calendar) -> Date {
		let daysBack = (calendar.component(.weekday, from: now) - sprintWeekday + 7) % 7
		let day = calendar.date(byAdding: .day, value: -daysBack, to: calendar.startOfDay(for: now))!
		let start = calendar.date(bySettingHour: sprintHour, minute: 0, second: 0, of: day)!
		return start <= now ? start : calendar.date(byAdding: .day, value: -7, to: start)!
	}

	// MARK: - Data

	/// The merged pull requests of the user and the Slack messages of the sprint. A failed source leaves its error in the
	/// data. When both fail, when the network fails, or when the Slack token is missing, the run does not start, so that
	/// the next try can work.
	@MainActor
	static func collect(_ report: Report) async throws -> Report.Input {
		let slack: Slack
		do {
			slack = try await report.slack()
		} catch {
			throw Report.Failure("\(error)")
		}
		let system = report.system
		let now = system.now()
		let start = sprintStart(before: now, calendar: system.calendar)
		let formatter = Report.timestampFormatter(system.calendar)
		var data: [String: Any] = ["sprint": ["start": formatter.string(from: start), "end": formatter.string(from: now)]]
		var errors: [String] = []
		do {
			let me = await report.me()
			data["me"] = me
			data["pullRequests"] = try await mergedPullRequests(report.bitbucket(), me: me, since: start)
		} catch let error as URLError {
			throw Report.Failure("No connection to Bitbucket: \(error.localizedDescription)")
		} catch {
			data["pullRequestError"] = "\(error)"
			errors.append("Bitbucket: \(error)")
		}
		do {
			let (messages, isCut) = try await slack.messages(since: start, calendar: system.calendar)
			data["slack"] = slackData(messages, isCut: isCut, formatter: formatter)
		} catch let error as URLError {
			throw Report.Failure("No connection to Slack: \(error.localizedDescription)")
		} catch {
			data["slackError"] = "\(error)"
			errors.append("Slack: \(error)")
		}
		if errors.count == 2 { throw Report.Failure("No data. " + errors.joined(separator: " ")) }
		return Report.Input(data: data)
	}

	/// The pull requests that the user wrote and that were merged from `start` on, oldest first, with their comments.
	static func mergedPullRequests(_ bitbucket: Bitbucket, me: String, since start: Date) async throws -> [[String: Any]] {
		// With `q`, Bitbucket ignores a `state` parameter. The time is in UTC with `Z`: a `+` of an offset stays unencoded in
		// the URL, and Bitbucket would read it as a space.
		let utc = ISO8601DateFormatter()
		let fields = ["id", "title", "summary.raw", "author.display_name", "links.html.href", "closed_on", "destination.branch.name",
			"comment_count"]
		let merged = try await bitbucket.values("/pullrequests", query: ["q": "state=\"MERGED\" AND closed_on >= \(utc.string(from: start))",
			"pagelen": "50"], fields: fields)
		var result: [[String: Any]] = []
		for pullRequest in merged where Bitbucket.isAuthor(of: pullRequest, me: me) {
			guard let id = pullRequest["id"] as? Int else { continue }
			var item: [String: Any] = [
				"id": id,
				"title": pullRequest["title"] as? String ?? "",
				"url": (((pullRequest["links"] as? [String: Any])?["html"]) as? [String: Any])?["href"] as? String ?? "",
				"mergedOn": pullRequest["closed_on"] as? String ?? "",
				"into": ((pullRequest["destination"] as? [String: Any])?["branch"] as? [String: Any])?["name"] as? String ?? "",
				"description": description((pullRequest["summary"] as? [String: Any])?["raw"] as? String ?? ""),
			]
			if pullRequest["comment_count"] as? Int ?? 0 > 0 {
				// A failed request costs only the comments of this pull request.
				do {
					let comments = try await bitbucket.values("/pullrequests/\(id)/comments", query: ["pagelen": "100"],
						fields: ["content.raw", "user.display_name", "inline.path", "deleted"], maxPages: 3)
					item["comments"] = comments.filter { $0["deleted"] as? Bool != true }.suffix(commentLimit).map { comment in
						var entry: [String: Any] = [
							"author": (comment["user"] as? [String: Any])?["display_name"] as? String ?? "",
							"text": ((comment["content"] as? [String: Any])?["raw"] as? String ?? "").cut(to: 300),
						]
						if let path = (comment["inline"] as? [String: Any])?["path"] as? String { entry["file"] = path }
						return entry
					}
				} catch let error as URLError {
					throw error
				} catch {
					item["commentError"] = "\(error)"
				}
			}
			result.append(item)
		}
		return result.sorted { ($0["mergedOn"] as? String ?? "") < ($1["mergedOn"] as? String ?? "") }
	}

	/// The description without images and HTML comments, cut to ``descriptionLimit``.
	static func description(_ raw: String) -> String {
		let text = raw.replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]*\\)", with: "", options: .regularExpression)
			.replacingOccurrences(of: "(?s)<!--.*?-->", with: "", options: .regularExpression)
			.trimmingCharacters(in: .whitespacesAndNewlines)
		return text.cut(to: descriptionLimit)
	}

	/// The messages for the run, newest first, until they reach ``slackBudget``. The data says how many were left out.
	static func slackData(_ messages: [Slack.Message], isCut: Bool, formatter: DateFormatter) -> [String: Any] {
		var kept: [[String: Any]] = []
		var size = 0
		for message in messages {
			size += [message.text, message.permalink, message.channel, message.user].map(\.utf8.count).reduce(80, +)
			if size > slackBudget { break }
			var item: [String: Any] = ["channel": message.channel, "user": message.user, "time": formatter.string(from: message.time),
				"text": message.text, "permalink": message.permalink]
			if message.isReply { item["threadReply"] = true }
			kept.append(item)
		}
		var data: [String: Any] = ["messages": kept]
		if kept.count < messages.count || isCut {
			data["leftOut"] = isCut ? "more than \(messages.count - kept.count) older messages" : "\(messages.count - kept.count) older messages"
		}
		return data
	}

	// MARK: - The file

	/// The file: the merges and Slack points from the answer of the run, and the notes of the old file.
	@MainActor
	static func render(_ report: Report, _ result: Report.CommandResult, _ input: Report.Input, _ old: String?) throws -> String {
		let answer = try structuredOutput(of: result)
		let data = input.data
		let pullRequests = data["pullRequests"] as? [[String: Any]] ?? []
		let messages = (data["slack"] as? [String: Any])?["messages"] as? [[String: Any]] ?? []

		var highlights: [Int: [String]] = [:]
		var kinds: [Int: Kind] = [:]
		for merge in answer["merges"] as? [[String: Any]] ?? [] {
			guard let id = merge["id"] as? Int, highlights[id] == nil else { throw Report.Failure("Claude named a pull request twice.") }
			highlights[id] = Array((merge["highlights"] as? [String] ?? []).map(markdownText).filter { !$0.isEmpty }.prefix(3))
			kinds[id] = (merge["kind"] as? String).flatMap(Kind.init(rawValue:))
		}
		guard Set(highlights.keys) == Set(pullRequests.compactMap { $0["id"] as? Int }) else {
			throw Report.Failure("Claude did not answer for exactly the merged pull requests.")
		}
		let channels = Dictionary(messages.compactMap { message in
			(message["permalink"] as? String).map { ($0, message["channel"] as? String ?? "Slack") }
		}, uniquingKeysWith: { first, _ in first })
		let points = try (answer["slack"] as? [[String: Any]] ?? []).map { point in
			guard let permalink = point["permalink"] as? String, let channel = channels[permalink] else {
				throw Report.Failure("Claude named a Slack message that is not in the data.")
			}
			return "- " + Report.hashLinksAsCode(in: "[\(markdownText(channel))](\(permalink))") + " " + markdownText(point["text"] as? String ?? "")
		}
		let notes = try notes(in: old)
		let morningOverview = try? String(contentsOf: report.system.folder.appendingPathComponent(Report.Kind.morningOverview.fileName),
			encoding: .utf8)
		let jiraBrowseURL = morningOverview.flatMap(jiraBrowseURL(in:))

		let sprint = data["sprint"] as? [String: String] ?? [:]
		let updated = Report.timestampFormatter(report.system.calendar).string(from: report.system.now())
		var lines = ["# DiDi", "", "Sprint: \(sprint["start"] ?? "?") – \(sprint["end"] ?? "?")", "Updated: \(updated)", "", "## Merges", ""]
		if let error = data["pullRequestError"] as? String {
			lines.append("PR data not available: \(error)")
		} else if pullRequests.isEmpty {
			lines.append("No merges yet.")
		}
		for pullRequest in pullRequests {
			guard let id = pullRequest["id"] as? Int else { continue }
			// A kind that is not in ``Kind`` gets no emoji.
			lines.append("- " + (kinds[id].map { $0.emoji + " " } ?? "") + titleLine(id: id, url: pullRequest["url"] as? String ?? "",
				title: pullRequest["title"] as? String ?? "", jiraBrowseURL: jiraBrowseURL))
			lines += (highlights[id] ?? []).map { "    - " + $0 }
		}
		lines += ["", "## Slack", ""]
		if let error = data["slackError"] as? String {
			lines.append("Slack not available: \(error)")
		} else {
			lines += points.isEmpty ? ["Nothing special."] : points
		}
		lines += ["", "## Notes", ""]
		if !notes.isEmpty { lines += [notes, ""] }
		// The last line is empty, so the file ends with a line break.
		return lines.joined(separator: "\n")
	}

	/// The structured answer of a run with `--output-format json`.
	static func structuredOutput(of result: Report.CommandResult) throws -> [String: Any] {
		let json = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any]
		guard let json, json["is_error"] as? Bool != true, let answer = json["structured_output"] as? [String: Any] else {
			let reason = json?["result"] as? String ?? (result.error + result.output).split(separator: "\n").last.map(String.init) ?? "no output"
			throw Report.Failure("Claude gave no summary: \(reason)")
		}
		return answer
	}

	/// Text that is not from the app, as one line of plain text: without the mark of a heading or a list in front, and
	/// with the marks of links, images and HTML escaped, so that it cannot add a link to the file.
	static func markdownText(_ text: String) -> String {
		text.components(separatedBy: .newlines).joined(separator: " ")
			.trimmingCharacters(in: .whitespaces)
			.replacingOccurrences(of: "^(?:#{1,6}|>|[-*+]|[0-9]+\\.)\\s+", with: "", options: .regularExpression)
			.replacingOccurrences(of: "([\\\\\\[\\]<>])", with: "\\\\$1", options: .regularExpression)
	}

	/// The title line of a merge, as in the morning overview: the PR link, the ticket link, and the title without the
	/// ticket ID. Without the Jira site, the ticket ID stays in the title.
	static func titleLine(id: Int, url: String, title: String, jiraBrowseURL: String?) -> String {
		var links = Report.hashLinksAsCode(in: "[#\(id)](\(url))")
		var title = title
		if let jiraBrowseURL, let ticket = ticket(in: title) {
			links += " [\(ticket.id)](\(jiraBrowseURL)\(ticket.id))"
			title = ticket.title
		}
		return links + " " + markdownText(title)
	}

	/// The ticket ID in a PR title, e.g. `PLANO-197417` in `feature/PLANO-197417 Load the item`, and the title without the
	/// ID and its branch prefix.
	static func ticket(in title: String) -> (id: String, title: String)? {
		guard let range = title.range(of: "(?:[A-Za-z0-9_.-]+/)?[A-Z][A-Z0-9]+-[0-9]+\\b", options: .regularExpression),
			let idRange = title[range].range(of: "[A-Z][A-Z0-9]+-[0-9]+", options: .regularExpression) else { return nil }
		let rest = title.replacingCharacters(in: range, with: " ")
			.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
		return (String(title[range][idRange]), rest)
	}

	/// The start of the ticket links in the morning overview, e.g. `https://x.atlassian.net/browse/`, or `nil` without one.
	static func jiraBrowseURL(in morningOverview: String) -> String? {
		morningOverview.range(of: "https://[^\\s()\\[\\]]+/browse/", options: .regularExpression).map { String(morningOverview[$0]) }
	}

	/// The user's own text of the old file: the text below »## Notes«. A file that the app did not write, e.g. one that
	/// the user started, is all notes, except its title.
	/// - Throws: A file of the app without the »## Notes« heading. The run must not drop the notes below another heading.
	static func notes(in old: String?) throws -> String {
		guard let old else { return "" }
		var text = old[...]
		if Report.updated(in: old, calendar: .current) != nil {
			guard let heading = old.range(of: "(?m)^## Notes[ \\t]*$", options: .regularExpression) else {
				throw Report.Failure("didi.md has no »## Notes« heading. Add it again, so that the app keeps your notes.")
			}
			text = old[heading.upperBound...]
		} else if let title = old.range(of: "(?m)^# DiDi[ \\t]*$", options: .regularExpression),
			old[..<title.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			text = old[title.upperBound...]
		}
		return text.trimmingCharacters(in: .newlines)
	}

	/// One backup for each sprint, so that a new sprint keeps the summary of the last one.
	static func backupName(_ old: String) -> String {
		guard let line = old.split(separator: "\n").prefix(10).first(where: { $0.hasPrefix("Sprint: ") }) else { return "hand-written.md" }
		return "sprint-\(line.dropFirst("Sprint: ".count).prefix(10)).md"
	}

	static func readyBody(_ text: String, _ input: Report.Input) -> String {
		let merges = (input.data["pullRequests"] as? [Any])?.count ?? 0
		// The first »## Slack« is the one of the app. The notes can have one too.
		let slack = text.components(separatedBy: "\n## Slack\n").dropFirst().first?.components(separatedBy: "\n## Notes\n").first ?? ""
		let points = slack.components(separatedBy: "\n- [").count - 1
		return "\(merges) merges, \(points) Slack points. Click to open the file."
	}
}
