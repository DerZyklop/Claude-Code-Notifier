import Foundation

extension Report.Kind {
	/// `morning-overview.md`: a short list of the open work of the user. The run reads the project, and the app adds the
	/// open pull requests and the state of the git workspaces.
	static let morningOverview = Report.Kind(
		title: "Morning Overview",
		fileName: "morning-overview.md",
		promptResource: "morning-overview-prompt",
		settingsKey: SettingsKey.updatesMorningOverview,
		schedule: Report.Schedule(weekdays: [2, 3, 4, 5, 6], hour: 6),
		notificationID: "morning-overview",
		access: .readsProject(folders: [MorningOverview.plansFolder], mcpTools: MorningOverview.jiraReadTools),
		timeout: 15 * 60,
		collect: MorningOverview.collect,
		render: MorningOverview.render,
		readyBody: { text, _ in "\(text.components(separatedBy: "\n- [ ]").count - 1) open tasks. Click to open the file." },
		backupName: nil
	)
}

enum MorningOverview {
	/// The read tools of the Atlassian MCP. The run gets no other MCP tool, so it cannot change a ticket.
	static let jiraReadTools = ["atlassianUserInfo", "getAccessibleAtlassianResources", "searchJiraIssuesUsingJql", "getJiraIssue"]
		.map { "mcp__com_atlassian_atlassian-mcp-server__\($0)" }
	/// The plans of Claude Code, for all projects.
	static let plansFolder = claudeConfigDirectory.appendingPathComponent("plans")
	/// The most pull requests that get their tasks and comments fetched.
	static let detailLimit = 20

	/// The open pull requests and the git workspaces on stdin, and the places to read in the facts.
	@MainActor
	static func collect(_ report: Report) async throws -> Report.Input {
		let me = await report.me()
		let branches = await branches(report)
		var data: [String: Any] = ["me": me, "workspaces": await workspaces(report), "branches": branches]
		var appData: [String: Any] = [:]
		do {
			let bitbucket = try await report.bitbucket()
			let pullRequests = try await pullRequests(bitbucket, me: me)
			data["pullRequests"] = pullRequests
			appData[othersTurnKey] = Set(pullRequests.filter { $0["isMyTurn"] as? Bool == false }.compactMap { $0["id"] as? Int })
			let old = try? String(contentsOf: report.fileURL, encoding: .utf8)
			let since = old.flatMap { Report.updated(in: $0, calendar: report.system.calendar) }
				?? report.system.now().addingTimeInterval(-Double(mergeDays) * 24 * 60 * 60)
			appData[otherMergesSection] = try await otherMerges(bitbucket, me: me, since: since)
		} catch let error as URLError {
			// Without a network, the run of the day waits for the next try.
			throw Report.Failure("No connection to Bitbucket: \(error.localizedDescription)")
		} catch {
			throw Report.Failure("Bitbucket: \(error)")
		}
		if FileManager.default.fileExists(atPath: plansFolder.path) {
			let known = Set(await report.git(["for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes"])
				.split(separator: "\n").map { $0.replacingOccurrences(of: #"^origin/"#, with: "", options: .regularExpression) })
			data["plans"] = plans(in: plansFolder, old: try? String(contentsOf: report.fileURL, encoding: .utf8), now: report.system.now(),
				calendar: report.system.calendar, branches: branches, knownBranches: known,
				pullRequests: data["pullRequests"] as? [[String: Any]] ?? [])
		}
		data["sessions"] = sessions(in: claudeProjectFolder(of: report.system.folder.path), now: report.system.now(),
			calendar: report.system.calendar)
		return Report.Input(data: data, facts: facts(report), appData: appData)
	}

	@MainActor
	private static func facts(_ report: Report) -> [String] {
		let system = report.system
		let projectFolder = claudeProjectFolder(of: system.folder.path)
		let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
		var facts = ["Project folder: \(system.folder.path)"]
		if exists(report.fileURL) { facts.append("Old overview: \(report.fileURL.path)") }
		let todayTasks = tasks(of: system)
		if !todayTasks.isEmpty {
			facts.append("Weekday tasks: \(todayTasks.joined(separator: ", ")). The app puts them at the top. Leave them out, and also the tickets that they cover.")
		}
		let names = appSections.map { "»\($0)«" }
		facts.append("The app writes the sections \(names.dropLast().joined(separator: ", ")) and \(names.last!). Leave them out, and also the tasks in them.")
		let memory = projectFolder.appendingPathComponent("memory")
		if exists(memory) { facts.append("Memory folder: \(memory.path)") }
		if exists(plansFolder) { facts.append("Plans folder: \(plansFolder.path)") }
		return facts
	}

	/// The days of the plans that Optional Work reads.
	static let recentDays = 14

	/// The facts of each plan in `folder` that the app can find without Claude, sorted by name:
	/// - `recent`: the plan changed in the last 14 days.
	/// - `changedAfterOldOverview`: the plan changed at or after the `Updated:` time of `old`. Only with such a time.
	/// - `oldSections`: the sections of `old` that name the plan file.
	/// - `tickets`: the ticket IDs in the name and the text, with a project key that a branch or a pull request also has.
	/// - `branches`: the local branches that the text names, with their `mergedInto`.
	/// - `unknownBranches`: the branch names in the text that git does not know.
	/// - `openPullRequests`: the IDs of the open pull requests that the text names, by number or by source branch.
	/// - `openSteps` and `doneSteps`: the number of checkboxes without and with a tick.
	static func plans(in folder: URL, old: String?, now: Date, calendar: Calendar, branches: [[String: Any]], knownBranches: Set<String>,
		pullRequests: [[String: Any]]) -> [[String: Any]] {
		let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".md") }.sorted()
		let since = old.flatMap { Report.updated(in: $0, calendar: calendar) }
		let oldSections = old.map(sections) ?? [:]
		let projectKeys = Set((branches.compactMap { $0["name"] as? String }
			+ pullRequests.flatMap { [$0["title"] as? String, sourceBranch(of: $0)].compactMap { $0 } })
			.flatMap { matches(of: ticketPattern, in: $0.uppercased()) }.map { String($0.prefix { $0 != "-" }) })
		let day = DateFormatter()
		day.calendar = calendar
		day.timeZone = calendar.timeZone
		day.locale = Locale(identifier: "en_US_POSIX")
		day.dateFormat = "yyyy-MM-dd"
		return names.compactMap { name in
			let file = folder.appendingPathComponent(name)
			guard let text = try? String(contentsOf: file, encoding: .utf8),
				let date = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date else { return nil }
			var plan: [String: Any] = ["name": name, "url": file.absoluteString, "changedOn": day.string(from: date),
				"recent": date >= now.addingTimeInterval(-Double(recentDays) * 24 * 60 * 60)]
			if let since { plan["changedAfterOldOverview"] = date >= since }
			plan["oldSections"] = oldSections.filter { $0.value.contains(name) }.keys.sorted()
			plan["tickets"] = Array(Set(matches(of: ticketPattern, in: name.uppercased() + "\n" + text.uppercased())
				.filter { projectKeys.contains(String($0.prefix { $0 != "-" })) })).sorted()
			plan["branches"] = branches.filter { ($0["name"] as? String).map { text.contains($0) } ?? false }
				.map { ["name": $0["name"] as Any, "mergedInto": $0["mergedInto"] as? [String] ?? []] }
			plan["unknownBranches"] = Array(Set(matches(of: branchPattern, in: text).filter { !knownBranches.contains($0) })).sorted()
			plan["openPullRequests"] = pullRequests.compactMap { pullRequest -> Int? in
				guard let id = pullRequest["id"] as? Int else { return nil }
				let byNumber = text.range(of: #"(#|PR |pull-requests/)\#(id)\b"#, options: .regularExpression) != nil
				let byBranch = sourceBranch(of: pullRequest).map { text.contains($0) } ?? false
				return byNumber || byBranch ? id : nil
			}
			plan["openSteps"] = matches(of: #"(?m)^\s*- \[ \]"#, in: text).count
			plan["doneSteps"] = matches(of: #"(?m)^\s*- \[[xX]\]"#, in: text).count
			return plan
		}
	}

	/// The days of the sessions in the input.
	static let sessionDays = 3

	/// The sessions in the transcripts `folder` that changed in the last 3 days, the newest first, with their `id`, their
	/// `title` and the time of their `lastChange`. The title is the newest custom title, else the newest title of Claude.
	static func sessions(in folder: URL, now: Date, calendar: Calendar) -> [[String: Any]] {
		let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".jsonl") }
		let start = now.addingTimeInterval(-Double(sessionDays) * 24 * 60 * 60)
		let files = names.compactMap { name -> (URL, Date)? in
			let file = folder.appendingPathComponent(name)
			guard let date = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date, date >= start
			else { return nil }
			return (file, date)
		}.sorted { $0.1 > $1.1 }
		return files.map { file, date in
			var custom: String?
			var ai: String?
			let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
			for line in text.split(separator: "\n") where line.contains("-title\"") {
				guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
				switch object["type"] as? String {
				case "custom-title": custom = object["customTitle"] as? String ?? custom
				case "ai-title": ai = object["aiTitle"] as? String ?? ai
				default: break
				}
			}
			var session: [String: Any] = ["id": file.deletingPathExtension().lastPathComponent,
				"lastChange": Report.timestampFormatter(calendar).string(from: date)]
			if let title = custom ?? ai { session["title"] = title }
			return session
		}
	}

	/// A ticket ID, e.g. `PROJ-123`, in upper case.
	static let ticketPattern = #"\b[A-Z][A-Z0-9]+-\d+\b"#
	/// A branch name with a usual prefix, e.g. `feature/PROJ-123-fix`.
	static let branchPattern = #"\b(?:feature|bugfix|hotfix|fix|release|chore)/[A-Za-z0-9._/-]*[A-Za-z0-9]"#

	private static func sourceBranch(of pullRequest: [String: Any]) -> String? {
		((pullRequest["source"] as? [String: Any])?["branch"] as? [String: Any])?["name"] as? String
	}

	private static func matches(of pattern: String, in text: String) -> [String] {
		guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
		return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
	}

	/// The overview in the output, with the weekday tasks and the kept sections of the old overview.
	@MainActor
	static func render(_ report: Report, _ result: Report.CommandResult, _ input: Report.Input, _ old: String?) throws -> String {
		guard let output = overview(in: result.output) else {
			let reason = (result.error + result.output).split(separator: "\n").last.map(String.init) ?? "no output"
			throw Report.Failure("Claude gave no overview: \(reason)")
		}
		let system = report.system
		let isSameDay = old.map { isSameDay($0, now: system.now(), calendar: system.calendar) } ?? false
		let done = isSameDay ? old.map(doneWeekdayTasks) ?? [] : []
		let othersTurn = input.appData[othersTurnKey] as? Set<Int> ?? []
		let kept = keptTasks(in: old ?? "", lastWritten: report.lastWritten)
		let text = withTurnMarks(othersTurn, in: Report.hashLinksAsCode(in: numbered(subItemsIndented(in: withWeekdayTasks(
			tasks(of: system), done: done, in: withKeptTasks(kept, in: withoutDoneCleanupTasks(in: withoutAppSections(output))))))))
		let merges = input.appData[otherMergesSection] as? [Merge] ?? []
		return withKeptSections(from: old ?? "", keepingTicks: isSameDay, in: text)
			+ (otherMergesSection(merges, old: old ?? "") ?? "")
			+ (system.notifierPlansFolder.flatMap(notifierSection) ?? "")
	}

	/// The old overview is of the same day as `now`.
	static func isSameDay(_ old: String, now: Date, calendar: Calendar) -> Bool {
		Report.updated(in: old, calendar: calendar).map { calendar.isDate($0, inSameDayAs: now) } ?? false
	}

	/// The ticked tasks above the first section of the old overview.
	static func doneWeekdayTasks(in old: String) -> Set<String> {
		let top = old.components(separatedBy: "\n## ").first ?? ""
		return Set(top.components(separatedBy: "\n").compactMap { line in
			["- [x] ", "- [X] "].contains(where: { line.hasPrefix($0) }) ? String(line.dropFirst(6)) : nil
		})
	}

	/// The tasks of today's weekday.
	static func tasks(of system: Report.System) -> [String] {
		system.weekdayTasks[system.calendar.component(.weekday, from: system.now())] ?? []
	}

	/// The sections that the user writes. A new overview copies them from the old one, and the app gives their tasks no ID
	/// and their headings no count.
	static let keptSections = ["My Notes", "Daily"]
	/// The sections that the app writes, not Claude. Their tasks get no ID and their headings get no count.
	static let appSections = keptSections + [otherMergesSection, "Notifier App"]

	/// The text of each section in `overview`, by its title without a count, from its heading to the next heading.
	static func sections(in overview: String) -> [String: String] {
		var result: [String: String] = [:]
		for part in overview.components(separatedBy: "\n## ").dropFirst() {
			let name = title(of: part)
			result[name] = result[name] ?? "## " + part
		}
		return result
	}

	/// The overview without the app sections.
	static func withoutAppSections(_ overview: String) -> String {
		var parts = overview.components(separatedBy: "\n## ")
		parts = [parts[0]] + parts.dropFirst().filter { part in !appSections.contains(title(of: part)) }
		return parts.joined(separator: "\n## ")
	}

	/// The title of a section part after `"\n## "`, without the count of the app.
	private static func title(of part: String) -> String {
		String(part.prefix { $0 != "\n" }).replacingOccurrences(of: #"^\d+ × "#, with: "", options: .regularExpression)
	}

	/// The section that Claude writes and the app moves below »My Notes«.
	static let cleanupSection = "Cleanup Work"

	/// The overview without the ticked tasks of »Cleanup Work«. A section with no task left gets »Nothing open.«.
	static func withoutDoneCleanupTasks(in overview: String) -> String {
		var parts = overview.components(separatedBy: "\n## ")
		guard let index = parts.indices.dropFirst().first(where: { title(of: parts[$0]) == cleanupSection }) else { return overview }
		let ending = String(parts[index].reversed().prefix { $0 == "\n" })
		let lines = parts[index].components(separatedBy: "\n")
			.filter { $0.range(of: #"^\s*- \[[xX]\] "#, options: .regularExpression) == nil }
		var section = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
		if !lines.contains(where: { $0.hasPrefix("- ") || $0 == "Nothing open." }) { section += "\n\nNothing open." }
		parts[index] = section + ending
		return parts.joined(separator: "\n## ")
	}

	/// The overview with the kept sections of `old` above its first section, and »Cleanup Work« below »My Notes«. »My Notes«
	/// loses only its ticked tasks without sub-items. The tasks in »Daily« lose their tick on a new day. A section that `old` does not have starts empty.
	static func withKeptSections(from old: String, keepingTicks: Bool, in overview: String) -> String {
		let oldSections = sections(in: old)
		var parts = overview.components(separatedBy: "\n## ")
		var cleanup = ""
		if let index = parts.indices.dropFirst().first(where: { title(of: parts[$0]) == cleanupSection }) {
			cleanup = "## " + parts.remove(at: index).trimmingCharacters(in: .newlines) + "\n\n"
		}
		let overview = parts.joined(separator: "\n## ")
		let kept = keptSections.map { title in
			// The heading loses an old count, so that the section keeps no wrong number.
			let body = oldSections[title].map { $0.drop { $0 != "\n" } } ?? "\n"
			var text = ("## \(title)" + body).trimmingCharacters(in: .newlines)
			if title == "My Notes" { text = withoutDoneLeafTasks(in: text) }
			if title == "Daily", !keepingTicks {
				text = text.replacingOccurrences(of: #"(?m)^(\s*- )\[[xX]\] "#, with: "$1[ ] ", options: .regularExpression)
			}
			return text + "\n\n" + (title == "My Notes" ? cleanup : "")
		}.joined()
		guard let section = overview.range(of: "\n## ") else { return overview + "\n" + kept }
		return overview.replacingCharacters(in: section, with: "\n" + kept + "## ")
	}

	/// The text without the ticked tasks that have no sub-item. A sub-item is a next line with more indent.
	static func withoutDoneLeafTasks(in text: String) -> String {
		let lines = text.components(separatedBy: "\n")
		let indent = { (line: String) in line.prefix { $0 == " " || $0 == "\t" }.count }
		return lines.indices.filter { index in
			guard lines[index].range(of: #"^\s*[-*] \[[xX]\] "#, options: .regularExpression) != nil else { return true }
			let next = lines.dropFirst(index + 1).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
			return next.map { indent($0) > indent(lines[index]) } ?? false
		}.map { lines[$0] }.joined(separator: "\n")
	}

	/// The key of the IDs of the pull requests where it is not the turn of the user, in ``Report/Input/appData``.
	static let othersTurnKey = "othersTurn"
	/// The sign before the link of a pull request where it is not the turn of the user.
	static let othersTurnMark = "🏓"
	/// The sections where a pull request gets ``othersTurnMark``.
	static let turnSections = ["Their Open PRs", "My Open PRs"]

	/// The overview with ``othersTurnMark`` before the link of each task in ``turnSections`` whose pull request is in
	/// `othersTurn`. A mark of Claude goes away.
	static func withTurnMarks(_ othersTurn: Set<Int>, in overview: String) -> String {
		var parts = overview.components(separatedBy: "\n## ")
		for index in parts.indices.dropFirst() where turnSections.contains(title(of: parts[index])) {
			parts[index] = parts[index].components(separatedBy: "\n").map { line in
				let pattern = #"^(- \[[ xX]\] (?:`[A-Z]\d+` )?)(?:\#(othersTurnMark) )?(\[`#(\d+)`\])"#
				guard let regex = try? NSRegularExpression(pattern: pattern),
					let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
					let start = Range(match.range(at: 1), in: line), let link = Range(match.range(at: 2), in: line),
					let id = Range(match.range(at: 3), in: line).flatMap({ Int(line[$0]) }) else { return line }
				let mark = othersTurn.contains(id) ? othersTurnMark + " " : ""
				return line[start] + mark + line[link.lowerBound...]
			}.joined(separator: "\n")
		}
		return parts.joined(separator: "\n## ")
	}

	/// A task of the old overview that a new overview keeps as it is: the section title, and the lines of the task with
	/// its sub-items.
	struct KeptTask: Equatable {
		var section: String
		var lines: [String]
	}

	/// The text of a task line without its indent, checkbox, ID and ``othersTurnMark``, or `nil` for another line.
	static func taskKey(of line: String) -> String? {
		guard let range = line.range(of: #"^\s*- (\[[ xX]\] )?(`[A-Z]\d+[a-z]*` )?"#, options: .regularExpression) else { return nil }
		var rest = line[range.upperBound...]
		if rest.hasPrefix(othersTurnMark + " ") { rest = rest.dropFirst(2) }
		return rest.trimmingCharacters(in: .whitespaces)
	}

	private static func indent(of line: String) -> Int { line.prefix { $0 == " " || $0 == "\t" }.count }

	/// The tasks of each section in `part`, a section without its `## `: each task line at the start of a line, with the
	/// indented lines after it.
	private static func taskBlocks(in part: String) -> [Range<Int>] {
		let lines = part.components(separatedBy: "\n")
		var blocks: [Range<Int>] = []
		var index = 1
		while index < lines.count {
			guard lines[index].hasPrefix("- ") else {
				index += 1
				continue
			}
			var end = index + 1
			while end < lines.count, indent(of: lines[end]) > 0, !lines[end].trimmingCharacters(in: .whitespaces).isEmpty { end += 1 }
			blocks.append(index..<end)
			index = end
		}
		return blocks
	}

	/// The tasks in the sections of Claude in `old` that the next overview keeps as they are: a task with a line that the
	/// user added, and a ticked task with a sub-item that is not ticked. A line is added when `lastWritten` does not have
	/// it. Without `lastWritten`, no line counts as added. A ticked task without an open sub-item goes away.
	static func keptTasks(in old: String, lastWritten: String?) -> [KeptTask] {
		let written = lastWritten.map { Set($0.components(separatedBy: "\n").compactMap(taskKey)) }
		return old.components(separatedBy: "\n## ").dropFirst().filter { !appSections.contains(title(of: $0)) }.flatMap { part in
			let lines = part.components(separatedBy: "\n")
			return taskBlocks(in: part).map { Array(lines[$0]) }.filter { block in
				let isDoneWithOpenChild = { (index: Int) in
					block[index].range(of: #"^\s*- \[[xX]\] "#, options: .regularExpression) != nil
						&& block[(index + 1)...].prefix { indent(of: $0) > indent(of: block[index]) }
							.contains { $0.range(of: #"^\s*- \[ \] "#, options: .regularExpression) != nil }
				}
				// A ticked task without an open sub-item is done, also when the user wrote it.
				if block[0].range(of: #"^- \[[xX]\] "#, options: .regularExpression) != nil, !isDoneWithOpenChild(0) { return false }
				return block.indices.contains { index in
					guard let key = taskKey(of: block[index]) else { return false }
					return written.map { !$0.contains(key) } ?? false || isDoneWithOpenChild(index)
				}
			}.map { KeptTask(section: title(of: part), lines: $0) }
		}
	}

	/// The overview with each task in `kept` in its section. It replaces the task of Claude with the same title line, and
	/// gets the sub-items of that task that it does not have at its end. Another kept task comes at the end of its section.
	/// A section that the overview does not have comes at its end.
	static func withKeptTasks(_ kept: [KeptTask], in overview: String) -> String {
		var parts = overview.components(separatedBy: "\n## ")
		for task in kept {
			guard let index = parts.indices.dropFirst().first(where: { title(of: parts[$0]) == task.section }) else {
				let text = parts.joined(separator: "\n## ")
				parts = (text + (text.hasSuffix("\n") ? "" : "\n") + "\n## \(task.section)\n\n" + task.lines.joined(separator: "\n") + "\n")
					.components(separatedBy: "\n## ")
				continue
			}
			var lines = parts[index].components(separatedBy: "\n")
			let blocks = taskBlocks(in: parts[index])
			if let block = blocks.first(where: { taskKey(of: lines[$0.lowerBound]) == taskKey(of: task.lines[0]) }) {
				let keys = Set(task.lines.compactMap(taskKey))
				let new = lines[block].dropFirst().filter { taskKey(of: $0).map { !keys.contains($0) } ?? true }
				lines.replaceSubrange(block, with: task.lines + new)
			} else if let last = blocks.last {
				lines.insert(contentsOf: task.lines, at: last.upperBound)
			} else {
				lines.removeAll { $0 == "Nothing open." }
				while lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
				lines += [""] + task.lines + [""]
			}
			parts[index] = lines.joined(separator: "\n")
		}
		return parts.joined(separator: "\n## ")
	}

	/// The section of the frontend merges of other devs that the user did not review.
	static let otherMergesSection = "Other Devs' Merges"

	/// The section with a task for each merge in `merges`, and the open tasks of the section in `old`, the new ones first.
	/// A ticked task of `old` goes away. `nil` without a task.
	static func otherMergesSection(_ merges: [Merge], old: String) -> String? {
		let new = merges.map { "- [ ] [`#\($0.id)`](\($0.url)) \($0.title), by \($0.author)" }
		let ids = Set(merges.map(\.id))
		let kept = (sections(in: old)[otherMergesSection] ?? "").components(separatedBy: "\n").filter { line in
			guard line.hasPrefix("- [ ] ") else { return false }
			return matches(of: #"(?<=#)\d+"#, in: line).first.flatMap { Int($0) }.map { !ids.contains($0) } ?? true
		}
		let lines = new + kept
		return lines.isEmpty ? nil : "\n## \(otherMergesSection)\n\n" + lines.map { $0 + "\n" }.joined()
	}

	/// The last section: a link to each plan of this app in `folder`, by name. Its `README.md` is no plan. `nil` without
	/// the folder.
	static func notifierSection(plansIn folder: URL) -> String? {
		guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
		let plans = names.filter { $0.hasSuffix(".md") && $0 != "README.md" }.sorted().map(folder.appendingPathComponent)
		let lines = plans.isEmpty ? "No plans.\n" : plans.map { "- [\($0.deletingPathExtension().lastPathComponent)](\($0.absoluteString))\n" }.joined()
		return "\n## Notifier App\n\n" + lines
	}

	/// The overview with an ID for each task and the number of open tasks in each heading.
	static func numbered(_ overview: String) -> String {
		withSectionCounts(in: withTaskIDs(in: overview))
	}

	/// The letter of the IDs in each section. Another section gets the first letter of its title that no other section has.
	static let sectionLetters = ["Their Open PRs": "R", "My Open PRs": "M", "Draft PRs": "D", "Remaining Tickets in this Sprint": "T",
		"Open Branches": "B", "Optional Work": "O", "Cleanup Work": "C"]

	/// The letter of each section heading in `overview`, in order. Each letter is unique, so that each ID is unique. The
	/// letters in `sectionLetters` stay free for their sections, also when a section is missing, so that the letters stay the
	/// same from run to run. A section without a free letter, a second section with the same title and an app section get
	/// `nil`.
	static func letters(in overview: String) -> [String?] {
		let alphabet = (UnicodeScalar("A").value...UnicodeScalar("Z").value).map { String(UnicodeScalar($0)!) }
		var used = Set(sectionLetters.values)
		var letters: [String?] = []
		var titles = Set<String>()
		for line in overview.components(separatedBy: "\n") where line.hasPrefix("## ") {
			let title = line.dropFirst(3).replacingOccurrences(of: #"^\d+ × "#, with: "", options: .regularExpression)
			guard titles.insert(title).inserted, !appSections.contains(title) else {
				letters.append(nil)
				continue
			}
			if let letter = sectionLetters[title] {
				letters.append(letter)
				continue
			}
			let letter = (title.uppercased().map(String.init) + alphabet).first { alphabet.contains($0) && !used.contains($0) }
			if let letter { used.insert(letter) }
			letters.append(letter)
		}
		return letters
	}

	/// Each task with an ID after its checkbox, e.g. `` `M2` `` for the second task under »My Open PRs«, and each of its next
	/// actions with a letter, e.g. `` `M2a` ``. Only a sub-item with a checkbox is a next action. A sub-item without one is
	/// no task and gets no ID. Done tasks keep their place in the count, so that a tick changes no ID. An ID that the file
	/// already has gets replaced. Tasks above the first section and in the app sections get no ID.
	static func withTaskIDs(in overview: String) -> String {
		var letters = letters(in: overview)[...]
		var letter: String?
		var task = 0
		var step = 0
		return overview.components(separatedBy: "\n").map { line in
			if line.hasPrefix("## ") {
				letter = letters.popFirst() ?? nil
				task = 0
				return line
			}
			let indent = line.prefix { $0 == " " }
			var body = line.dropFirst(indent.count)
			guard let letter, body.hasPrefix("- ") else { return line }
			body = body.dropFirst(2)
			var box = ""
			if ["[ ] ", "[x] ", "[X] "].contains(where: { body.hasPrefix($0) }) {
				box = String(body.prefix(4))
				body = body.dropFirst(4)
			}
			if let old = body.range(of: #"^`[A-Z]\d+[a-z]*` "#, options: .regularExpression) { body = body[old.upperBound...] }
			let id: String
			if indent.isEmpty {
				task += 1
				step = 0
				id = "\(letter)\(task)"
			} else {
				guard !box.isEmpty else { return "\(indent)- \(body)" }
				guard task > 0, step < 26 else { return line }
				step += 1
				id = "\(letter)\(task)\(Character(UnicodeScalar(UInt8(96 + step))))"
			}
			return "\(indent)- \(box)`\(id)` \(body)"
		}.joined(separator: "\n")
	}

	/// Each section heading with the number of its tasks, e.g. `## 3 × My Open PRs`. Only the tasks at the start of a line
	/// count, not their next actions. A number that Claude already wrote gets replaced. The app sections get no number.
	static func withSectionCounts(in overview: String) -> String {
		var lines = overview.components(separatedBy: "\n")
		var heading: Int?
		var count = 0
		func writeCount() {
			guard let heading else { return }
			let title = lines[heading].dropFirst(3).replacingOccurrences(of: #"^\d+ × "#, with: "", options: .regularExpression)
			lines[heading] = "## \(count) × \(title)"
		}
		for index in lines.indices {
			if lines[index].hasPrefix("## ") {
				writeCount()
				heading = appSections.contains(title(of: String(lines[index].dropFirst(3)))) ? nil : index
				count = 0
			} else if lines[index].hasPrefix("- [ ]") {
				count += 1
			}
		}
		writeCount()
		return lines.joined(separator: "\n")
	}

	/// The overview in the output of the run, or `nil` if the output is no overview. Text before the title and a Markdown
	/// fence around the overview do not count.
	static func overview(in output: String) -> String? {
		guard let start = output.range(of: "(?m)^# Morning overview", options: .regularExpression) else { return nil }
		var lines = output[start.lowerBound...].components(separatedBy: "\n")
		while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty || last.hasPrefix("```") { lines.removeLast() }
		let text = lines.joined(separator: "\n")
		return Report.updated(in: text, calendar: .current) == nil ? nil : text + "\n"
	}

	/// Keeps the counts in the headings right while the user ticks tasks in an editor.
	@MainActor static let countKeeper = SectionCountKeeper(fileURL: Report.morningOverview.fileURL)

	/// The overview with each sub-item indented by 4 spaces. Claude sometimes writes 2.
	static func subItemsIndented(in overview: String) -> String {
		overview.replacingOccurrences(of: "(?m)^  (?=- )", with: "    ", options: .regularExpression)
	}

	/// The overview with the weekday tasks above its first section. The tasks in `done` get a tick.
	static func withWeekdayTasks(_ tasks: [String], done: Set<String> = [], in overview: String) -> String {
		guard !tasks.isEmpty, let section = overview.range(of: "\n## ") else { return overview }
		let lines = tasks.map { "- [\(done.contains($0) ? "x" : " ")] \($0)\n" }.joined()
		return overview.replacingCharacters(in: section, with: "\n" + lines + "\n## ")
	}

	// MARK: - Git workspaces

	/// The main folder and each worktree, with uncommitted changes and commits that are on no remote.
	@MainActor
	private static func workspaces(_ report: Report) async -> [[String: Any]] {
		var result: [[String: Any]] = []
		for entry in worktrees(in: await report.git(["worktree", "list", "--porcelain"])) {
			let folder = URL(fileURLWithPath: entry.path)
			let changes = await report.git(["status", "--porcelain"], in: folder).split(separator: "\n").prefix(30).map(String.init)
			let commits = await report.git(["log", "--oneline", "-n", "20", "HEAD", "--not", "--remotes"], in: folder)
				.split(separator: "\n").map(String.init)
			result.append(["path": entry.path, "branch": entry.branch ?? "detached HEAD", "uncommittedChanges": changes,
				"commitsOnNoRemote": commits])
		}
		return result
	}

	/// The remote branches that other branches merge into, if the remote has them.
	static let baseBranches = ["origin/HEAD", "origin/dev", "origin/develop"]
	/// The most local branches in the input, the newest first.
	static let branchLimit = 100

	/// The local branches, the newest first, with their upstream state and the base branches that hold all their commits.
	@MainActor
	private static func branches(_ report: Report) async -> [[String: Any]] {
		let format = "%(refname:short)%09%(upstream:short)%09%(upstream:track)%09%(committerdate:short)%09%(subject)"
		var result = branches(in: await report.git(["for-each-ref", "--sort=-committerdate", "--count=\(branchLimit)", "--format=\(format)", "refs/heads"]))
		for base in baseBranches {
			guard !(await report.git(["rev-parse", "--verify", "--quiet", base])).isEmpty else { continue }
			let merged = Set(await report.git(["branch", "--merged", base, "--format=%(refname:short)"]).split(separator: "\n").map(String.init))
			for index in result.indices where merged.contains(result[index]["name"] as? String ?? "") {
				result[index]["mergedInto"] = (result[index]["mergedInto"] as? [String] ?? []) + [base]
			}
		}
		return result
	}

	/// The branches in the output of `git for-each-ref` with the format of ``branches(_:)``.
	static func branches(in output: String) -> [[String: Any]] {
		output.split(separator: "\n").compactMap { line in
			let fields = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
			guard fields.count == 5 else { return nil }
			var branch: [String: Any] = ["name": fields[0], "lastCommit": fields[3], "subject": fields[4]]
			if !fields[1].isEmpty { branch["upstream"] = fields[1] }
			if !fields[2].isEmpty { branch["track"] = fields[2] }
			return branch
		}
	}

	/// The worktrees in the output of `git worktree list --porcelain`.
	static func worktrees(in output: String) -> [(path: String, branch: String?)] {
		output.components(separatedBy: "\n\n").compactMap { block in
			let lines = block.split(separator: "\n")
			guard let path = lines.first(where: { $0.hasPrefix("worktree ") })?.dropFirst("worktree ".count) else { return nil }
			let branch = lines.first(where: { $0.hasPrefix("branch refs/heads/") })?.dropFirst("branch refs/heads/".count)
			return (String(path), branch.map(String.init))
		}
	}

	// MARK: - Pull requests

	/// The open pull requests. The ones of the user, as author or reviewer, also get their open tasks, newest comments,
	/// newest build states and merge conflict.
	private static func pullRequests(_ bitbucket: Bitbucket, me: String) async throws -> [[String: Any]] {
		let fields = ["id", "title", "draft", "author.display_name", "participants.role", "participants.approved", "participants.state",
			"participants.user.display_name", "links.html.href", "comment_count", "task_count", "updated_on", "source.branch.name",
			"destination.branch.name"]
		var pullRequests = try await bitbucket.values("/pullrequests", query: ["state": "OPEN", "pagelen": "50"], fields: fields)
			.filter { !isDraftOfOthers($0, me: me) }
		for index in pullRequests.indices.filter({ concerns(pullRequests[$0], me: me) }).prefix(detailLimit) {
			guard let id = pullRequests[index]["id"] as? Int else { continue }
			// A failed detail request costs only the details of this pull request.
			do {
				let tasks = try await bitbucket.values("/pullrequests/\(id)/tasks", query: ["q": "state=\"UNRESOLVED\"", "pagelen": "50"],
					fields: ["content.raw", "creator.display_name"], maxPages: 1)
				let comments = try await bitbucket.values("/pullrequests/\(id)/comments", query: ["sort": "-created_on", "pagelen": "10"],
					fields: ["content.raw", "user.display_name", "created_on", "inline.path", "deleted"], maxPages: 1)
				let statuses = try await bitbucket.values("/pullrequests/\(id)/statuses", query: ["sort": "-updated_on", "pagelen": "5"],
					fields: ["state", "name", "updated_on"], maxPages: 1)
				pullRequests[index]["openTasks"] = tasks.map { Bitbucket.shortened($0) }
				pullRequests[index]["newestComments"] = comments.filter { $0["deleted"] as? Bool != true }.map { Bitbucket.shortened($0) }
				pullRequests[index]["buildStatuses"] = statuses
				pullRequests[index]["hasMergeConflict"] = try await hasMergeConflict(bitbucket, id: id)
				pullRequests[index]["waitsForMyReview"] = waitsForReview(pullRequests[index], me: me)
				pullRequests[index]["isMyTurn"] = isMyTurn(pullRequests[index], me: me)
			} catch {
				pullRequests[index]["detailError"] = "\(error)"
			}
		}
		return pullRequests
	}

	/// A merged pull request of another dev, for ``otherMergesSection(_:old:)``.
	struct Merge: Equatable {
		var id: Int
		var title: String
		var author: String
		var url: String
	}

	/// The days of merges that a run without an old overview reads.
	static let mergeDays = 7
	/// The folder of the frontend code. A merge that changes a file in it is frontend work.
	static let frontendFolder = "scheduler.frontend.ng2/"

	/// The pull requests of other devs that changed after `since`, are merged, change the frontend, and that the user
	/// did not review. The newest come first.
	private static func otherMerges(_ bitbucket: Bitbucket, me: String, since: Date) async throws -> [Merge] {
		let time = DateFormatter()
		time.locale = Locale(identifier: "en_US_POSIX")
		time.timeZone = TimeZone(identifier: "UTC")
		time.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
		// With `q`, Bitbucket ignores a `state` parameter, so the state goes into `q`.
		let pullRequests = try await bitbucket.values("/pullrequests", query: ["q": "state=\"MERGED\" AND updated_on > \(time.string(from: since))",
			"sort": "-updated_on", "pagelen": "50"], fields: ["id", "title", "author.display_name", "participants.approved",
			"participants.state", "participants.user.display_name", "links.html.href"], maxPages: 2)
		var merges: [Merge] = []
		for pullRequest in pullRequests.filter({ !Bitbucket.isAuthor(of: $0, me: me) && !isReviewed($0, by: me) }).prefix(detailLimit) {
			guard let id = pullRequest["id"] as? Int else { continue }
			let files = try await bitbucket.values("/pullrequests/\(id)/diffstat", query: ["pagelen": "500"], fields: ["new.path", "old.path"])
			let paths = files.flatMap { file in ["new", "old"].compactMap { ((file[$0] as? [String: Any])?["path"] as? String) } }
			guard paths.contains(where: { $0.hasPrefix(frontendFolder) }) else { continue }
			merges.append(Merge(id: id, title: pullRequest["title"] as? String ?? "",
				author: (pullRequest["author"] as? [String: Any])?["display_name"] as? String ?? "",
				url: ((pullRequest["links"] as? [String: Any])?["html"] as? [String: Any])?["href"] as? String ?? ""))
		}
		return merges
	}

	/// The user approved the pull request or asked for changes.
	static func isReviewed(_ pullRequest: [String: Any], by me: String) -> Bool {
		let participants = pullRequest["participants"] as? [[String: Any]] ?? []
		return participants.contains { participant in
			(participant["user"] as? [String: Any])?["display_name"] as? String == me
				&& (participant["approved"] as? Bool == true || participant["state"] is String)
		}
	}

	/// A file of the pull request has a merge conflict with the destination branch.
	private static func hasMergeConflict(_ bitbucket: Bitbucket, id: Int) async throws -> Bool {
		try await bitbucket.values("/pullrequests/\(id)/diffstat", query: ["pagelen": "500"], fields: ["status"])
			.contains { $0["status"] as? String == "merge conflict" }
	}

	/// The pull request is a draft of another author. No section lists it, so the run does not get it.
	static func isDraftOfOthers(_ pullRequest: [String: Any], me: String) -> Bool {
		pullRequest["draft"] as? Bool == true && !Bitbucket.isAuthor(of: pullRequest, me: me)
	}

	/// The user wrote the pull request or reviews it.
	static func concerns(_ pullRequest: [String: Any], me: String) -> Bool {
		if Bitbucket.isAuthor(of: pullRequest, me: me) { return true }
		let participants = pullRequest["participants"] as? [[String: Any]] ?? []
		return participants.contains { ($0["user"] as? [String: Any])?["display_name"] as? String == me && $0["role"] as? String == "REVIEWER" }
	}

	/// The author waits for the user: the user reviews the pull request and did not approve it yet, and it is no draft
	/// and has no open task. An open task is for the author, so with one, it is the author's turn.
	static func waitsForReview(_ pullRequest: [String: Any], me: String) -> Bool {
		let participants = pullRequest["participants"] as? [[String: Any]] ?? []
		guard let mine = participants.first(where: { ($0["user"] as? [String: Any])?["display_name"] as? String == me && $0["role"] as? String == "REVIEWER" })
		else { return false }
		return mine["approved"] as? Bool != true && pullRequest["draft"] as? Bool != true && (pullRequest["openTasks"] as? [Any])?.isEmpty == true
	}

	/// The user has the next step. In a pull request of another author, the author waits for the review of the user,
	/// and the user did not ask for changes. In a pull request of the user, it has an open task, a merge conflict, a
	/// failed newest build, a request for changes, a newest comment of another person, or the approval of each reviewer.
	static func isMyTurn(_ pullRequest: [String: Any], me: String) -> Bool {
		let participants = pullRequest["participants"] as? [[String: Any]] ?? []
		let name = { (item: [String: Any], key: String) in (item[key] as? [String: Any])?["display_name"] as? String }
		guard Bitbucket.isAuthor(of: pullRequest, me: me) else {
			let mine = participants.first { name($0, "user") == me }
			return waitsForReview(pullRequest, me: me) && mine?["state"] as? String != "changes_requested"
		}
		let reviewers = participants.filter { $0["role"] as? String == "REVIEWER" }
		let newestComment = (pullRequest["newestComments"] as? [[String: Any]])?.first
		return (pullRequest["openTasks"] as? [Any])?.isEmpty == false
			|| pullRequest["hasMergeConflict"] as? Bool == true
			|| (pullRequest["buildStatuses"] as? [[String: Any]])?.first?["state"] as? String == "FAILED"
			|| participants.contains { $0["state"] as? String == "changes_requested" }
			|| newestComment.map { name($0, "user") != me } ?? false
			|| (!reviewers.isEmpty && reviewers.allSatisfy { $0["approved"] as? Bool == true })
	}
}

/// Counts the tasks in the headings again after the user changes the file, e.g. ticks a task, and gives a new task its ID. It checks the change date
/// every 2 seconds, which works for each way of saving: in place, or as a new file. It writes only after the file stayed
/// the same for one check, so that it does not change the file while the user types.
@MainActor
final class SectionCountKeeper {
	static let interval: TimeInterval = 2
	let fileURL: URL
	private var timer: Timer?
	/// The change date at the last check, and whether the file changed since the last count.
	private var lastDate: Date?
	private var isChanged = false

	init(fileURL: URL) {
		self.fileURL = fileURL
	}

	func start() {
		timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
			Task { @MainActor in self?.check() }
		}
	}

	/// Counts again when the file stayed the same since a change.
	func check() {
		let date = changeDate()
		if date != lastDate {
			isChanged = lastDate != nil || isChanged
			lastDate = date
			return
		}
		guard isChanged else { return }
		isChanged = false
		updateCounts()
	}

	/// Writes the counts, if they changed.
	func updateCounts() {
		guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
		let counted = MorningOverview.numbered(text)
		guard counted != text else { return }
		try? counted.write(to: fileURL, atomically: true, encoding: .utf8)
		lastDate = changeDate()
	}

	/// Read without a cache: `URL.resourceValues` can give an old date for the same URL.
	private func changeDate() -> Date? {
		(try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
	}
}
