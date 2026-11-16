import Foundation

extension Report.Kind {
	/// `YYYY-MM-DD.md` in the folder of the setting: a short list of the open work of the user. The run reads the project, and the app adds the
	/// open pull requests and the state of the git workspaces.
	static let morningOverview = Report.Kind(
		title: "Morning Overview",
		fileName: "morning-overview.md",
		promptResource: "morning-overview-prompt",
		settingsKey: SettingsKey.updatesMorningOverview,
		schedule: Report.Schedule(weekdays: [2, 3, 4, 5, 6], hour: 6),
		notificationID: "morning-overview",
		access: .readsProject(folders: [MorningOverview.plansFolder]),
		timeout: 15 * 60,
		collect: MorningOverview.collect,
		render: MorningOverview.render,
		readyBody: { text, _ in "\(text.components(separatedBy: "\n- [ ]").count - 1) open tasks. Click to open the file." },
		backupName: nil,
		folderKey: SettingsKey.morningOverviewFolder,
		heading: "# Morning overview",
		statsFileName: "stats.md",
		didWrite: { report, input in
			if let heads = input.appData[MorningOverview.headsKey] as? [Int: String] { MorningOverview.saveHeads(heads, report) }
		}
	)
}

enum MorningOverview {
	/// The plans of Claude Code, for all projects.
	static let plansFolder = claudeConfigDirectory.appendingPathComponent("plans")
	/// The most pull requests that get their tasks and comments fetched.
	static let detailLimit = 20

	/// The open pull requests, the Jira tickets and the git workspaces on stdin, and the places to read in the facts.
	@MainActor
	static func collect(_ report: Report) async throws -> Report.Input {
		let system = report.system
		let old = report.fileURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
		// The Jira searches run while the other steps run.
		async let jiraSearch = jiraSearch(report, old: old)
		let me = await report.me()
		report.step("Git user name")
		let branches = await branches(report, me: me)
		report.step("Local branches")
		let workspaces = await workspaces(report)
		report.step("Git workspaces")
		let remoteBranches = await remoteBranches(report, me: me, local: Set(branches.compactMap { $0["name"] as? String }))
		report.step("Remote branches")
		var data: [String: Any] = ["me": me, "workspaces": workspaces, "branches": branches, "remoteBranches": remoteBranches]
		var appData: [String: Any] = [:]
		var pullRequests: [[String: Any]]
		do {
			let bitbucket = try await report.bitbucket()
			report.step("Bitbucket login")
			pullRequests = try await Self.pullRequests(bitbucket, me: me).map { pullRequest in
				var pullRequest = pullRequest
				pullRequest["isStale"] = isStale(pullRequest, now: system.now())
				return pullRequest
			}
			report.step("Open pull requests")
			appData[staleKey] = ids(of: pullRequests.filter { $0["isStale"] as? Bool == true })
			appData[blockedKey] = ids(of: pullRequests.filter { ($0["title"] as? String)?.contains(blockedMark) == true })
			let since = old.flatMap { Report.updated(in: $0, calendar: system.calendar) } ?? days(mergeDays, before: system.now())
			appData[otherMergesSection] = try await otherMerges(bitbucket, me: me, since: since)
			report.step("Merges of other devs")
		} catch let error as URLError {
			// Without a network, the run of the day waits for the next try.
			throw Report.Failure("No connection to Bitbucket: \(error.localizedDescription)")
		} catch {
			throw Report.Failure("Bitbucket: \(error)")
		}
		let heads = heads(of: pullRequests)
		let lastHeads = lastHeads(report)
		// A pull request without a known head counts as changed, so that its tasks get checked again.
		let changedPullRequests = ids(of: pullRequests).filter { id in heads[id].map { lastHeads[String(id)] != $0 } ?? true }
		// The pull requests that were open at the last run and are merged or declined now.
		let closedPullRequests = Set(lastHeads.keys.compactMap { Int($0) }).subtracting(ids(of: pullRequests))
		appData[headsKey] = heads
		let refs = await report.git(["for-each-ref", "--format=%(refname:short)%09%(committerdate:unix)", "refs/heads", "refs/remotes"])
			.split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
		let withoutRemote = { (name: String) in name.replacingOccurrences(of: #"^origin/"#, with: "", options: .regularExpression) }
		let known = Set(refs.compactMap(\.first).map(withoutRemote))
		// A commit on `origin` counts too, e.g. a push from a worktree without a local branch.
		let branchDates = Dictionary(refs.filter { $0.count == 2 }
			.compactMap { fields in Double(fields[1]).map { (withoutRemote(fields[0]), Date(timeIntervalSince1970: $0)) } }, uniquingKeysWith: max)
		let fileFacts = { (files: [URL]) in
			Self.plans(of: files, old: old, now: system.now(), calendar: system.calendar, branches: branches, knownBranches: known,
				pullRequests: pullRequests, branchDates: branchDates, changedPullRequests: changedPullRequests,
				closedPullRequests: closedPullRequests)
		}
		var plans: [[String: Any]] = []
		if FileManager.default.fileExists(atPath: plansFolder.path) {
			let names = ((try? FileManager.default.contentsOfDirectory(atPath: plansFolder.path)) ?? []).filter { $0.hasSuffix(".md") }
			plans = fileFacts(names.map(plansFolder.appendingPathComponent))
			data["plans"] = plans
		}
		let untracked = await report.git(["ls-files", "--others", "--exclude-standard"]).split(separator: "\n").map(String.init)
		let projectFiles = untracked.filter { $0.hasSuffix(".md") }.map(system.folder.appendingPathComponent)
		data["projectFiles"] = fileFacts(projectFiles)
		let reviews = newReviews(in: projectFiles, pullRequests: pullRequests, me: me)
		appData[newReviewsKey] = reviews
		pullRequests = withNewReviews(reviews, in: pullRequests)
		data["pullRequests"] = pullRequests
		appData[othersTurnKey] = ids(of: pullRequests.filter { $0["isMyTurn"] as? Bool == false })
		if let old { appData[oldOverviewKey] = old }
		report.step("Plans")
		let sessions = await sessions(in: claudeProjectFolder(of: system.folder.path), now: system.now(), calendar: system.calendar,
			archived: system.archivedSessionIDs() ?? [])
		report.step("Sessions")
		data["sessions"] = sessions.open
		data["archivedSessions"] = sessions.archivedTitles
		let texts = branches.compactMap { $0["name"] as? String } + remoteBranches.compactMap { $0["name"] as? String }
			+ pullRequests.flatMap { [$0["title"] as? String, sourceBranch(of: $0)].compactMap { $0 } }
			+ plans.flatMap { $0["tickets"] as? [String] ?? [] } + sessions.open.compactMap { $0["title"] as? String }
			+ untracked.map { ($0 as NSString).lastPathComponent } + [old ?? ""]
		var search = await jiraSearch
		// The Bitbucket requests worked, so the network works now, e.g. after a wake.
		if case .failure(let error) = search.result, error is URLError { search = await Self.jiraSearch(report, old: old) }
		let jira = await jiraData(search, texts: texts, projectKeys: projectKeys(branches: branches, pullRequests: pullRequests))
		data["jira"] = jira
		report.step("Jira")
		if let old {
			data["unchangedTasks"] = unchangedTasks(in: old, files: plans + (data["projectFiles"] as? [[String: Any]] ?? []),
				changedPullRequests: changedPullRequests, tickets: jira["tickets"] as? [String: [String: Any]],
				blockedPullRequests: appData[blockedKey] as? Set<Int> ?? [])
		}
		return Report.Input(data: data, facts: facts(report), appData: appData)
	}

	/// The IDs of `pullRequests`.
	private static func ids(of pullRequests: [[String: Any]]) -> Set<Int> { Set(pullRequests.compactMap { $0["id"] as? Int }) }

	/// The time `count` days before `date`.
	private static func days(_ count: Int, before date: Date) -> Date { date.addingTimeInterval(-Double(count) * 24 * 60 * 60) }

	@MainActor
	private static func facts(_ report: Report) -> [String] {
		let system = report.system
		let projectFolder = claudeProjectFolder(of: system.folder.path)
		let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
		var facts = ["Project folder: \(system.folder.path)"]
		if let file = report.fileURL, exists(file) { facts.append("Old overview: \(file.path)") }
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

	/// The facts of each plan in `files` that the app can find without Claude, sorted by name:
	/// - `recent`: the plan changed in the last 14 days.
	/// - `changedAfterOldOverview`: the plan changed at or after the `Updated:` time of `old`. Only with such a time.
	/// - `changedAfterOldOverview`: `changeDate` of the plan is at or after the `Updated:` time of `old`. Only with such a
	///   time. The default is the newer of the content and the attribute change, so that a moved file counts as changed.
	/// - `newCommits`: a pull request in `openPullRequests` is in `changedPullRequests`, the text names a pull request in
	///   `closedPullRequests`, or a branch that the text names has a commit in `branchDates` at or after the `Updated:`
	///   time of `old`. Only with such a time.
	/// - `oldSections`: the sections of `old` that name the plan file.
	/// - `tickets`: the ticket IDs in the name and the text, with a project key that a branch or a pull request also has.
	/// - `branches`: the local branches that the text names, with their `mergedInto`.
	/// - `unknownBranches`: the branch names in the text that git does not know.
	/// - `openPullRequests`: the IDs of the open pull requests that the text names, by number or by source branch.
	/// - `openSteps` and `doneSteps`: the number of checkboxes without and with a tick.
	static func plans(of files: [URL], old: String?, now: Date, calendar: Calendar, branches: [[String: Any]], knownBranches: Set<String>,
		pullRequests: [[String: Any]], branchDates: [String: Date] = [:], changedPullRequests: Set<Int> = [],
		closedPullRequests: Set<Int> = [], changeDate: (URL) -> Date? = changeDate(of:)) -> [[String: Any]] {
		let since = old.flatMap { Report.updated(in: $0, calendar: calendar) }
		let oldSections = old.map(sections) ?? [:]
		let projectKeys = projectKeys(branches: branches, pullRequests: pullRequests)
		let day = DateFormatter()
		day.calendar = calendar
		day.timeZone = calendar.timeZone
		day.locale = Locale(identifier: "en_US_POSIX")
		day.dateFormat = "yyyy-MM-dd"
		return files.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { file in
			let name = file.lastPathComponent
			guard let text = try? String(contentsOf: file, encoding: .utf8),
				let date = file.modificationDate else { return nil }
			var plan: [String: Any] = ["name": name, "url": file.absoluteString, "changedOn": day.string(from: date),
				"recent": date >= days(recentDays, before: now)]
			if let since { plan["changedAfterOldOverview"] = (changeDate(file) ?? date) >= since }
			plan["oldSections"] = oldSections.filter { $0.value.contains(name) }.keys.sorted()
			plan["tickets"] = Array(Set(matches(of: ticketPattern, in: (name + "\n" + text).uppercased())
				.filter { projectKeys.contains(projectKey(of: $0)) })).sorted()
			let namedBranches = branches.compactMap { $0["name"] as? String }.filter { text.contains($0) }
			plan["branches"] = branches.filter { ($0["name"] as? String).map(namedBranches.contains) ?? false }
				.map { ["name": $0["name"] as Any, "mergedInto": $0["mergedInto"] as? [String] ?? []] }
			plan["unknownBranches"] = Array(Set(matches(of: branchPattern, in: text).filter { !knownBranches.contains($0) })).sorted()
			let numbers = Set(matches(of: #"(?<=#|PR |pull-requests/)\d+\b"#, in: text).compactMap { Int($0) })
			let openPullRequests = pullRequests.compactMap { pullRequest -> Int? in
				guard let id = pullRequest["id"] as? Int else { return nil }
				let byBranch = sourceBranch(of: pullRequest).map { text.contains($0) } ?? false
				return numbers.contains(id) || byBranch ? id : nil
			}
			plan["openPullRequests"] = openPullRequests
			if let since {
				let datedBranches = Set(namedBranches + matches(of: branchPattern, in: text))
				plan["newCommits"] = openPullRequests.contains(where: changedPullRequests.contains) || !numbers.isDisjoint(with: closedPullRequests)
					|| datedBranches.contains { (branchDates[$0] ?? .distantPast) >= since }
			}
			plan["openSteps"] = matches(of: #"(?m)^\s*- \[ \]"#, in: text).count
			plan["doneSteps"] = matches(of: #"(?m)^\s*- \[[xX]\]"#, in: text).count
			return plan
		}
	}

	/// The days of the sessions in the input.
	static let sessionDays = 3

	/// The days of the archived sessions in the input. An old task of a session can stay in the overview this long.
	static let archivedSessionDays = 14

	/// The sessions in the transcripts `folder`:
	/// - `open`: the sessions that changed in the last 3 days and that are not in `archived`, the newest first, with their
	///   `id`, their `title` and the time of their `lastChange`.
	/// - `archivedTitles`: the titles of the sessions in `archived` that changed in the last 14 days, sorted. A title that
	///   an open session also has is not in it, because its work can still go on.
	///
	/// The title is the newest custom title, else the newest title of Claude. The function runs off the main actor, so the
	/// menu does not block while it reads.
	static func sessions(in folder: URL, now: Date, calendar: Calendar, archived: Set<String> = []) async
		-> (open: [[String: Any]], archivedTitles: [String]) {
		let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".jsonl") }
		let start = days(sessionDays, before: now)
		let archivedStart = days(archivedSessionDays, before: now)
		let files = names.compactMap { name -> (file: URL, id: String, date: Date)? in
			let file = folder.appendingPathComponent(name)
			let id = file.deletingPathExtension().lastPathComponent
			guard let date = file.modificationDate, date >= (archived.contains(id) ? archivedStart : start) else { return nil }
			return (file, id, date)
		}.sorted { $0.date > $1.date }
		let titles = await titles(of: files.map(\.file))
		var open: [[String: Any]] = []
		var archivedTitles: [String: String] = [:]
		for ((_, id, date), title) in zip(files, titles) {
			if archived.contains(id) {
				if let title { archivedTitles[title.lowercased()] = title }
				continue
			}
			var session: [String: Any] = ["id": id, "lastChange": Report.timestampFormatter(calendar).string(from: date)]
			if let title { session["title"] = title }
			open.append(session)
		}
		for title in open.compactMap({ $0["title"] as? String }) { archivedTitles[title.lowercased()] = nil }
		return (open, archivedTitles.values.sorted())
	}

	/// The titles of the transcripts `files`, in the same order. The files load at the same time.
	private static func titles(of files: [URL]) async -> [String?] {
		await withTaskGroup(of: (Int, String?).self) { group in
			for (index, file) in files.enumerated() { group.addTask { (index, title(of: file)) } }
			var titles = [String?](repeating: nil, count: files.count)
			for await (index, title) in group { titles[index] = title }
			return titles
		}
	}

	/// The newest custom title of the transcript `file`, else the newest title of Claude. The file is not decoded as text,
	/// and only its lines with a title get parsed, because a transcript can have many MB.
	private static func title(of file: URL) -> String? {
		var custom: String?
		var ai: String?
		let data = (try? Data(contentsOf: file)) ?? Data()
		for line in lines(containing: Array(#"-title""#.utf8), in: data) {
			guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
			switch object["type"] as? String {
			case "custom-title": custom = object["customTitle"] as? String ?? custom
			case "ai-title": ai = object["aiTitle"] as? String ?? ai
			default: break
			}
		}
		return custom ?? ai
	}

	/// The lines of `data` that contain `marker`, in their order and without the line break.
	static func lines(containing marker: [UInt8], in data: Data) -> [Data] {
		data.withUnsafeBytes { bytes in
			guard let base = bytes.baseAddress, !marker.isEmpty else { return [] }
			var lines: [Data] = []
			// `position` is always the start of a line.
			var position = 0
			while position < bytes.count, let hit = memmem(base + position, bytes.count - position, marker, marker.count) {
				let offset = base.distance(to: UnsafeRawPointer(hit))
				var start = offset
				while start > position, bytes[start - 1] != UInt8(ascii: "\n") { start -= 1 }
				let end = memchr(base + offset, Int32(UInt8(ascii: "\n")), bytes.count - offset)
					.map { base.distance(to: UnsafeRawPointer($0)) } ?? bytes.count
				lines.append(Data(bytes: base + start, count: end - start))
				position = end + 1
			}
			return lines
		}
	}

	/// A ticket ID, e.g. `PROJ-123`, in upper case.
	static let ticketPattern = #"\b[A-Z][A-Z0-9]+-\d+\b"#
	/// A branch name with a usual prefix, e.g. `feature/PROJ-123-fix`.
	static let branchPattern = #"\b(?:feature|bugfix|hotfix|fix|release|chore)/[A-Za-z0-9._/-]*[A-Za-z0-9]"#

	/// The project key of a ticket ID, e.g. `PROJ` for `PROJ-123`.
	private static func projectKey(of ticket: String) -> String { String(ticket.prefix { $0 != "-" }) }

	private static func sourceBranch(of pullRequest: [String: Any]) -> String? {
		((pullRequest["source"] as? [String: Any])?["branch"] as? [String: Any])?["name"] as? String
	}

	/// The first capture group of the first match of `pattern` in `text`.
	private static func firstGroup(of pattern: String, in text: String) -> String? {
		guard let regex = try? NSRegularExpression(pattern: pattern),
			let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges > 1,
			let range = Range(match.range(at: 1), in: text) else { return nil }
		return String(text[range])
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
		let old = old ?? ""
		let isSameDay = isSameDay(old, now: system.now(), calendar: system.calendar)
		var text = withKeptByID(in: withoutAppSections(output), old: input.appData[oldOverviewKey] as? String ?? "")
		text = withoutDoneCleanupTasks(in: text)
		text = withKeptTasks(keptTasks(in: old, lastWritten: report.lastWritten), in: text)
		text = withNewReviewTasks(input.appData[newReviewsKey] as? [NewReview] ?? [],
			jiraBrowseURL: (input.data["jira"] as? [String: Any])?["browseURL"] as? String, in: text)
		text = withWeekdayTasks(tasks(of: system), done: isSameDay ? doneWeekdayTasks(in: old) : [], in: text)
		text = Report.hashLinksAsCode(in: subItemsIndented(in: text))
		text = withMarks(othersTurn: input.appData[othersTurnKey] as? Set<Int> ?? [], stale: input.appData[staleKey] as? Set<Int> ?? [],
			blocked: input.appData[blockedKey] as? Set<Int> ?? [], in: text)
		text = numbered(withTasksSorted(in: text))
		if let file = report.newFileURL { text = withVSCodeLink(to: file, in: text) }
		let merges = input.appData[otherMergesSection] as? [Merge] ?? []
		return withKeptSections(from: old, keepingTicks: isSameDay, in: text)
			+ (otherMergesSection(merges, old: old) ?? "")
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

	/// The index of the section `title` in `parts`, the overview split at `"\n## "`. The text above the first section does
	/// not count.
	private static func index(ofSection title: String, in parts: [String]) -> Int? {
		parts.indices.dropFirst().first { self.title(of: parts[$0]) == title }
	}

	/// The line is a task with a tick, at any indent.
	private static func isTicked(_ line: String) -> Bool { line.range(of: #"^\s*- \[[xX]\] "#, options: .regularExpression) != nil }

	/// The section that Claude writes and the app moves below »My Notes«.
	static let cleanupSection = "Cleanup Work"

	/// The overview without the ticked tasks of »Cleanup Work«, and without a `###` subheading with no task left. A section
	/// with no task left gets »Nothing open.«.
	static func withoutDoneCleanupTasks(in overview: String) -> String {
		var parts = overview.components(separatedBy: "\n## ")
		guard let index = index(ofSection: cleanupSection, in: parts) else { return overview }
		let ending = String(parts[index].reversed().prefix { $0 == "\n" })
		var lines = parts[index].components(separatedBy: "\n").filter { !isTicked($0) }
		lines = lines.indices.filter { line in
			guard lines[line].hasPrefix("### ") else { return true }
			return lines[(line + 1)...].prefix { !$0.hasPrefix("### ") }.contains { $0.hasPrefix("- ") }
		}.map { lines[$0] }
		var section = lines.joined(separator: "\n").replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
			.trimmingCharacters(in: .newlines)
		if !lines.contains(where: { $0.hasPrefix("- ") || $0 == "Nothing open." }) { section += "\n\nNothing open." }
		parts[index] = section + ending
		return parts.joined(separator: "\n## ")
	}

	/// The overview with the kept sections of `old` above its first section, and »Cleanup Work« below »My Notes«. »My Notes«
	/// loses only its ticked tasks without an open sub-item. The tasks in »Daily« lose their tick on a new day. A section that `old` does not have starts empty.
	static func withKeptSections(from old: String, keepingTicks: Bool, in overview: String) -> String {
		let oldSections = sections(in: old)
		var parts = overview.components(separatedBy: "\n## ")
		var cleanup = ""
		if let index = index(ofSection: cleanupSection, in: parts) {
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

	/// The text without the ticked tasks that have no open sub-item. A ticked task goes away with its sub-items, e.g. a note
	/// without a checkbox. A sub-item is a next line with more indent. An open sub-item has a checkbox without a tick, e.g.
	/// `[ ]` or `[/]`. The lines go from the bottom up, so that a ticked task whose sub-items are all ticked goes away too.
	static func withoutDoneLeafTasks(in text: String) -> String {
		// The kept lines in reverse order, so that `kept.last` is the next line.
		var kept: [String] = []
		// A removed task left an empty line below it, so that an empty line above it is one too many.
		var dropsEmptyLine = false
		for line in text.components(separatedBy: "\n").reversed() {
			let isEmpty = line.trimmingCharacters(in: .whitespaces).isEmpty
			if isEmpty, dropsEmptyLine { continue }
			dropsEmptyLine = false
			if line.range(of: #"^\s*[-*] \[[xX]\] "#, options: .regularExpression) != nil {
				// The number of next lines up to the last sub-item. Empty lines after the last sub-item stay.
				var count = 0
				var subItems = 0
				for next in kept.reversed() {
					count += 1
					if next.trimmingCharacters(in: .whitespaces).isEmpty { continue }
					guard indent(of: next) > indent(of: line) else { break }
					subItems = count
				}
				let isOpen = kept.suffix(subItems).contains { $0.range(of: #"^\s*[-*] \[[^xX]\] "#, options: .regularExpression) != nil }
				if !isOpen {
					kept.removeLast(subItems)
					dropsEmptyLine = kept.last?.trimmingCharacters(in: .whitespaces).isEmpty == true
					continue
				}
			}
			kept.append(line)
		}
		return kept.reversed().joined(separator: "\n")
	}

	/// The newer of the content change and the attribute change of `file`. `mv` and `cp -p` keep the content change, but
	/// set the attribute change to now.
	static func changeDate(of file: URL) -> Date? {
		var info = stat()
		guard stat(file.path, &info) == 0 else { return nil }
		let date = { (time: timespec) in Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1e9) }
		return max(date(info.st_mtimespec), date(info.st_ctimespec))
	}

	/// The project keys of the ticket IDs in the branch names, the PR titles and the source branches, e.g. `PROJ`.
	static func projectKeys(branches: [[String: Any]], pullRequests: [[String: Any]]) -> Set<String> {
		Set((branches.compactMap { $0["name"] as? String } + pullRequests.flatMap { [$0["title"] as? String, sourceBranch(of: $0)].compactMap { $0 } })
			.flatMap { matches(of: ticketPattern, in: $0.uppercased()) }.map(projectKey))
	}

	/// The key of the IDs of the pull requests where it is not the turn of the user, in ``Report/Input/appData``.
	static let othersTurnKey = "othersTurn"
	/// The sign before the link of a pull request where it is not the turn of the user.
	static let othersTurnMark = "🏓"
	/// The key of the IDs of the pull requests that nobody changed for ``staleTime``, in ``Report/Input/appData``.
	static let staleKey = "stale"
	/// The sign before the link of a pull request that nobody changed for ``staleTime``.
	static let staleMark = "⌛"
	/// The time without a change after which a pull request gets ``staleMark``.
	static let staleTime: TimeInterval = 24 * 60 * 60
	/// The signs that the app puts before the link of a pull request, in their order.
	static let marks = [othersTurnMark, staleMark]
	/// The sign that Claude puts before the first link of a task whose ticket is blocked. It comes after ``marks``.
	static let blockedMark = "🚫"
	/// The key of the IDs of the pull requests with ``blockedMark`` in their title, in ``Report/Input/appData``.
	static let blockedKey = "blocked"
	/// The sections where a pull request gets ``marks``.
	static let turnSections = ["Their Open PRs", "My Open PRs"]

	/// Nobody changed the pull request for ``staleTime``. Bitbucket changes `updated_on` on a push, a comment, a task and
	/// a review.
	static func isStale(_ pullRequest: [String: Any], now: Date) -> Bool {
		// `ISO8601DateFormatter` cannot read the 6 digits of the fraction of a second.
		guard let text = (pullRequest["updated_on"] as? String)?.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression),
			let updated = ISO8601DateFormatter().date(from: text) else { return false }
		return now.timeIntervalSince(updated) > staleTime
	}

	/// The overview with ``othersTurnMark`` and ``staleMark`` before the link of each task in ``turnSections`` whose pull
	/// request is in `othersTurn` and in `stale`. A mark of Claude goes away, but ``blockedMark`` stays. A task in any
	/// section whose pull request is in `blocked` gets ``blockedMark``.
	static func withMarks(othersTurn: Set<Int>, stale: Set<Int>, blocked: Set<Int> = [], in overview: String) -> String {
		let anyMark = (marks + [blockedMark]).joined(separator: "|")
		guard let regex = try? NSRegularExpression(pattern: #"^(- \[[^\]]\] (?:`[A-Z]\d+` )?)((?:(?:\#(anyMark)) )*)(\[`#(\d+)`\])"#)
		else { return overview }
		var parts = overview.components(separatedBy: "\n## ")
		for index in parts.indices.dropFirst() {
			let isTurnSection = turnSections.contains(title(of: parts[index]))
			parts[index] = parts[index].components(separatedBy: "\n").map { line in
				guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
					let start = Range(match.range(at: 1), in: line), let old = Range(match.range(at: 2), in: line),
					let link = Range(match.range(at: 3), in: line),
					let id = Range(match.range(at: 4), in: line).flatMap({ Int(line[$0]) }) else { return line }
				let mark = (isTurnSection && othersTurn.contains(id) ? othersTurnMark + " " : "")
					+ (isTurnSection && stale.contains(id) ? staleMark + " " : "")
					+ (line[old].contains(blockedMark) || blocked.contains(id) ? blockedMark + " " : "")
				return line[start] + mark + line[link.lowerBound...]
			}.joined(separator: "\n")
		}
		return parts.joined(separator: "\n## ")
	}

	/// The overview with the tasks of each list in 3 groups: first the tasks of the user, then the tasks with
	/// ``othersTurnMark``, then the tasks with ``blockedMark``. A list is a run of tasks with their sub-items. A blank line
	/// or a heading ends it. In a group, the tasks keep their order.
	static func withTasksSorted(in overview: String) -> String {
		var result: [String] = []
		var tasks: [(rank: Int, lines: [String])] = []
		func flush() {
			result += (0...2).flatMap { rank in tasks.filter { $0.rank == rank } }.flatMap(\.lines)
			tasks = []
		}
		for line in overview.components(separatedBy: "\n") {
			if line.hasPrefix("- ") {
				let marks = leadingMarks(of: line)
				tasks.append((marks.contains(blockedMark) ? 2 : marks.contains(othersTurnMark) ? 1 : 0, [line]))
			} else if !tasks.isEmpty, line.first == " " || line.first == "\t", !line.trimmingCharacters(in: .whitespaces).isEmpty {
				tasks[tasks.count - 1].lines.append(line)
			} else {
				flush()
				result.append(line)
			}
		}
		flush()
		return result.joined(separator: "\n")
	}

	/// The start of a task up to the end of its marks. A mark in the title does not count.
	private static func leadingMarks(of line: String) -> Substring {
		let anyMark = (marks + [blockedMark]).joined(separator: "|")
		guard let range = line.range(of: #"^- (\[[^\]]\] )?(`[A-Z]\d+[a-z]*` )?((\#(anyMark)) )*"#, options: .regularExpression)
		else { return "" }
		return line[range]
	}

	/// A task of the old overview that a new overview keeps as it is: the section title, and the lines of the task with
	/// its sub-items.
	struct KeptTask: Equatable {
		var section: String
		var lines: [String]
	}

	/// The text of a task line without its indent, checkbox, ID, ``marks`` and ``blockedMark``, or `nil` for another line.
	static func taskKey(of line: String) -> String? {
		guard let range = line.range(of: #"^\s*- (\[[^\]]\] )?(`[A-Z]\d+[a-z]*` )?"#, options: .regularExpression) else { return nil }
		var rest = line[range.upperBound...]
		while let mark = (marks + [blockedMark]).first(where: { rest.hasPrefix($0 + " ") }) { rest = rest.dropFirst(mark.count + 1) }
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

	/// The tasks in the sections of Claude in `old` that the next overview keeps: a task with a line that the user added,
	/// and a ticked task with a sub-item that is not ticked. A line is added when `lastWritten` does not have it. Without
	/// `lastWritten`, no line counts as added. A ticked task without an open sub-item goes away. Of a kept task, only the
	/// title line, the added and ticked lines, their parents and their sub-items stay. The new sub-items of Claude replace
	/// the other lines.
	static func keptTasks(in old: String, lastWritten: String?) -> [KeptTask] {
		let written = lastWritten.map { Set($0.components(separatedBy: "\n").compactMap(taskKey)) }
		return old.components(separatedBy: "\n## ").dropFirst().filter { !appSections.contains(title(of: $0)) }.flatMap { part in
			let lines = part.components(separatedBy: "\n")
			return taskBlocks(in: part).map { Array(lines[$0]) }.compactMap { block -> KeptTask? in
				// A ticked task without an open sub-item is done, also when the user wrote it.
				if isTicked(block[0]), !isTickedWithOpenChild(0, in: block) { return nil }
				let reasons = block.indices.filter { isReason($0, in: block, written: written) }
				guard !reasons.isEmpty else { return nil }
				let lines = block.indices.filter { index in
					index == 0 || reasons.contains { reason in
						reason == index || isDescendant(index, of: reason, in: block) || isDescendant(reason, of: index, in: block)
					}
				}.map { block[$0] }
				return KeptTask(section: title(of: part), lines: lines)
			}
		}
	}

	/// The line at `index` makes the task stay: the user added it, or it is ticked and has a sub-item that is not ticked.
	private static func isReason(_ index: Int, in block: [String], written: Set<String>?) -> Bool {
		guard let key = taskKey(of: block[index]) else { return false }
		return written.map { !$0.contains(key) } ?? false || isTickedWithOpenChild(index, in: block)
	}

	/// The line at `index` is ticked and has a sub-item that is not ticked.
	private static func isTickedWithOpenChild(_ index: Int, in block: [String]) -> Bool {
		isTicked(block[index]) && block[(index + 1)...].prefix { indent(of: $0) > indent(of: block[index]) }
			.contains { $0.range(of: #"^\s*- \[ \] "#, options: .regularExpression) != nil }
	}

	/// The line at `index` is a sub-item of the line at `parent`, at any depth.
	private static func isDescendant(_ index: Int, of parent: Int, in block: [String]) -> Bool {
		index > parent && block[(parent + 1)...index].allSatisfy { indent(of: $0) > indent(of: block[parent]) }
	}

	/// The overview with each task in `kept` in its section. It replaces the task of Claude with the same title line, and
	/// gets the sub-items of that task that it does not have at its end. Another kept task comes at the end of its section.
	/// A section that the overview does not have comes at its end.
	static func withKeptTasks(_ kept: [KeptTask], in overview: String) -> String {
		var parts = overview.components(separatedBy: "\n## ")
		for task in kept {
			guard let index = index(ofSection: task.section, in: parts) else {
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
			let name = title(of: String(line.dropFirst(3)))
			guard titles.insert(name).inserted, !appSections.contains(name) else {
				letters.append(nil)
				continue
			}
			if let letter = sectionLetters[name] {
				letters.append(letter)
				continue
			}
			let letter = (name.uppercased().map(String.init) + alphabet).first { alphabet.contains($0) && !used.contains($0) }
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
			if let range = body.range(of: #"^\[[^\]]\] "#, options: .regularExpression) {
				box = String(body[range])
				body = body[range.upperBound...]
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
			lines[heading] = "## \(count) × \(title(of: String(lines[heading].dropFirst(3))))"
		}
		for index in lines.indices {
			if lines[index].hasPrefix("## ") {
				writeCount()
				heading = appSections.contains(title(of: String(lines[index].dropFirst(3)))) ? nil : index
				count = 0
			} else if lines[index].range(of: #"^- \[[^\]xX]\] "#, options: .regularExpression) != nil {
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

	/// Keeps the counts in the headings right while the user ticks tasks in an editor. It pauses while a run is active,
	/// so that each ID names the same task for collect, for Claude and for ``withKeptByID(in:old:)``.
	@MainActor static let countKeeper = SectionCountKeeper(isPaused: { Report.morningOverview.isRunning }) { Report.morningOverview.fileURL }

	/// The overview with a link below its `Updated:` line that opens `file` in the VS Code window that had focus last, e.g.
	/// from Obsidian or a browser.
	static func withVSCodeLink(to file: URL, in overview: String) -> String {
		guard let path = file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
			let line = overview.range(of: "(?m)^Updated: .*$", options: .regularExpression) else { return overview }
		return overview.replacingCharacters(in: line, with: overview[line] + "\n[Open in VS Code](vscode://file\(path))")
	}

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
	/// The local base branches. The input leaves them out.
	static let localBaseBranches: Set<String> = ["main", "master", "dev", "develop"]
	/// The most local branches in the input, the newest first.
	static let branchLimit = 100

	/// The local branches of `me` and the empty local branches, the newest first, with their upstream state and the base
	/// branches that hold all their commits.
	@MainActor
	private static func branches(_ report: Report, me: String) async -> [[String: Any]] {
		let format = "%(refname:short)%09%(upstream:short)%09%(upstream:track)%09%(committerdate:short)%09%(subject)"
		var result = branches(in: await report.git(["for-each-ref", "--sort=-committerdate", "--count=\(branchLimit)", "--format=\(format)", "refs/heads"]))
		await addMerges(to: &result, report: report, remote: false)
		return ofMe(result, authors: await authors(of: result, report: report, prefix: "refs/heads/"), me: me, keepingEmpty: true)
	}

	/// The author of the newest commit that is no merge commit, for each branch in `branches` that is not empty.
	@MainActor
	private static func authors(of branches: [[String: Any]], report: Report, prefix: String) async -> [String: String] {
		var result: [String: String] = [:]
		for branch in branches where branch["empty"] == nil {
			guard let name = branch["name"] as? String else { continue }
			result[name] = await report.git(["log", "-1", "--no-merges", "--format=%an", prefix + name]).trimmingCharacters(in: .whitespacesAndNewlines)
		}
		return result
	}

	/// The branches in `branches` whose author in `authors` is `me`. A merge commit does not count, so a merge of `dev`
	/// into the branch of a colleague does not make it a branch of `me`. Git cannot tell who made an empty branch, so
	/// `keepingEmpty` decides about them.
	static func ofMe(_ branches: [[String: Any]], authors: [String: String], me: String, keepingEmpty: Bool) -> [[String: Any]] {
		branches.filter { branch in
			if branch["empty"] as? Bool == true { return keepingEmpty }
			return authors[branch["name"] as? String ?? ""] == me
		}
	}

	/// Adds `mergedInto` to each branch in `branches` that a base branch holds, and `empty: true` if it also has no commit of
	/// its own. A merge commit puts the commits of a branch beside the first-parent line of the base. The newest commit of an
	/// empty branch is on that line.
	@MainActor
	private static func addMerges(to branches: inout [[String: Any]], report: Report, remote: Bool) async {
		var tips: [String: String]?
		for base in baseBranches {
			guard !(await report.git(["rev-parse", "--verify", "--quiet", base])).isEmpty else { continue }
			let merged = Set(await report.git(["branch"] + (remote ? ["-r"] : []) + ["--merged", base, "--format=%(refname:short)"])
				.split(separator: "\n").map(String.init))
			guard branches.contains(where: { merged.contains($0["name"] as? String ?? "") }) else { continue }
			if tips == nil {
				let names = branches.compactMap { $0["name"] as? String }
				let hashes = await report.git(["rev-parse"] + names.map { (remote ? "refs/remotes/" : "refs/heads/") + $0 }).split(separator: "\n").map(String.init)
				tips = hashes.count == names.count ? Dictionary(zip(names, hashes), uniquingKeysWith: { first, _ in first }) : [:]
			}
			let firstParent = Set(await report.git(["rev-list", "--first-parent", base]).split(separator: "\n").map(String.init))
			markMerges(&branches, base: base, merged: merged, tips: tips ?? [:], firstParent: firstParent)
		}
	}

	/// Adds `base` to `mergedInto` of each branch in `merged`, and `empty: true` if the newest commit of the branch in `tips`
	/// is in `firstParent`.
	static func markMerges(_ branches: inout [[String: Any]], base: String, merged: Set<String>, tips: [String: String], firstParent: Set<String>) {
		for index in branches.indices {
			let name = branches[index]["name"] as? String ?? ""
			guard merged.contains(name) else { continue }
			branches[index]["mergedInto"] = (branches[index]["mergedInto"] as? [String] ?? []) + [base]
			if let tip = tips[name], firstParent.contains(tip) { branches[index]["empty"] = true }
		}
	}

	/// The branches on `origin` of `me` that a base branch holds and that have no local branch, the newest first. An empty
	/// branch does not count, because git cannot tell who made it.
	@MainActor
	private static func remoteBranches(_ report: Report, me: String, local: Set<String>) async -> [[String: Any]] {
		let format = "%(refname:short)%09%(authorname)%09%(committerdate:short)%09%(subject)"
		var result = remoteBranches(in: await report.git(["for-each-ref", "--sort=-committerdate", "--format=\(format)", "refs/remotes/origin"]),
			me: me, local: local)
		await addMerges(to: &result, report: report, remote: true)
		result = result.filter { $0["mergedInto"] != nil }
		return Array(ofMe(result, authors: await authors(of: result, report: report, prefix: "refs/remotes/"), me: me, keepingEmpty: false)
			.prefix(branchLimit))
	}

	/// The branches in the output of `git for-each-ref` with the format of ``remoteBranches(_:me:local:)``, without
	/// `origin/HEAD`, the base branches and the branches in `local`. Only a branch whose newest commit has `me` as author
	/// counts. This keeps the later checks of the authors few.
	static func remoteBranches(in output: String, me: String, local: Set<String>) -> [[String: Any]] {
		output.split(separator: "\n").compactMap { line in
			let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
			guard fields.count == 4, fields[1] == me, fields[0].hasPrefix("origin/") else { return nil }
			let name = String(fields[0].dropFirst("origin/".count))
			guard name != "HEAD", !localBaseBranches.contains(name), !local.contains(name) else { return nil }
			return ["name": fields[0], "lastCommit": fields[2], "subject": fields[3]]
		}
	}

	/// The branches in the output of `git for-each-ref` with the format of ``branches(_:)``, without the local base branches.
	static func branches(in output: String) -> [[String: Any]] {
		output.split(separator: "\n").compactMap { line in
			let fields = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
			guard fields.count == 5, !localBaseBranches.contains(fields[0]) else { return nil }
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

	// MARK: - Changes since the last run

	/// The key of the newest commit of each open pull request, in ``Report/Input/appData``. Render saves them for the next run.
	static let headsKey = "heads"
	/// The key of the old overview that Claude read, in ``Report/Input/appData``. ``withKeptByID(in:old:)`` copies its tasks.
	static let oldOverviewKey = "oldOverview"
	/// The key of the ``NewReview`` items, in ``Report/Input/appData``.
	static let newReviewsKey = "newReviews"

	/// The hash of the newest commit of each pull request, by its ID.
	static func heads(of pullRequests: [[String: Any]]) -> [Int: String] {
		Dictionary(pullRequests.compactMap { pullRequest in
			guard let id = pullRequest["id"] as? Int,
				let hash = ((pullRequest["source"] as? [String: Any])?["commit"] as? [String: Any])?["hash"] as? String else { return nil }
			return (id, hash)
		}, uniquingKeysWith: { first, _ in first })
	}

	/// The file with the heads of the pull requests at the last run that wrote an overview.
	@MainActor
	private static func headsFile(_ report: Report) -> URL { report.supportFolder.appendingPathComponent("pull-request-heads.json") }

	/// The heads of the pull requests at the last run that wrote an overview, by the ID as text.
	@MainActor
	static func lastHeads(_ report: Report) -> [String: String] {
		(try? Data(contentsOf: headsFile(report))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
	}

	/// Saves `heads` for the next run.
	@MainActor
	static func saveHeads(_ heads: [Int: String], _ report: Report) {
		let text = Dictionary(uniqueKeysWithValues: heads.map { (String($0.key), $0.value) })
		guard let data = try? JSONSerialization.data(withJSONObject: text, options: .sortedKeys) else { return }
		try? FileManager.default.createDirectory(at: report.supportFolder, withIntermediateDirectories: true)
		try? data.write(to: headsFile(report), options: .atomic)
	}

	/// An open pull request whose newest commit is not the commit of any of its review reports.
	struct NewReview: Equatable {
		var id: Int
		/// The commit of the newest report that names one.
		var reviewedCommit: String
		var url: String
		var title: String
		/// The section of the task of the pull request: »Their Open PRs«, »My Open PRs« or »Draft PRs«.
		var section: String
		var hasMergeConflict = false
		var destination = ""
	}

	/// The open pull requests in `pullRequests` with a review report in `files`, where no report names the newest commit
	/// of the pull request. A report is a file in a folder `reviews` whose name starts with the number of the pull
	/// request, e.g. `reviews/4341-fix.md`. Its reviewed commit is the first hash after »reviewed commit« or »reviewed at«
	/// in its text, else the hash at the end of its name, e.g. `4341-fix-6e460fc.md`. A report without a commit does not
	/// count.
	static func newReviews(in files: [URL], pullRequests: [[String: Any]], me: String) -> [NewReview] {
		var reports: [Int: [(date: Date, commit: String)]] = [:]
		for file in files where file.deletingLastPathComponent().lastPathComponent == "reviews" {
			let name = file.deletingPathExtension().lastPathComponent
			guard let id = matches(of: #"^\d+(?=-)"#, in: name).first.flatMap({ Int($0) }), let date = file.modificationDate else { continue }
			let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
			guard let commit = reviewedCommit(in: text) ?? matches(of: #"(?<=-)(?=[0-9a-f]*\d)[0-9a-f]{7,40}$"#, in: name).first else { continue }
			reports[id, default: []].append((date, commit))
		}
		return pullRequests.compactMap { pullRequest in
			guard let id = pullRequest["id"] as? Int, let reports = reports[id], let head = heads(of: [pullRequest])[id],
				!reports.contains(where: { head.hasPrefix($0.commit) || $0.commit.hasPrefix(head) }),
				let newest = reports.max(by: { $0.date < $1.date }) else { return nil }
			let section = !Bitbucket.isAuthor(of: pullRequest, me: me) ? "Their Open PRs" : pullRequest["draft"] as? Bool == true ? "Draft PRs" : "My Open PRs"
			return NewReview(id: id, reviewedCommit: newest.commit,
				url: ((pullRequest["links"] as? [String: Any])?["html"] as? [String: Any])?["href"] as? String ?? "",
				title: pullRequest["title"] as? String ?? "", section: section, hasMergeConflict: pullRequest["hasMergeConflict"] as? Bool == true,
				destination: ((pullRequest["destination"] as? [String: Any])?["branch"] as? [String: Any])?["name"] as? String ?? "")
		}
	}

	/// The first commit hash after »reviewed commit« or »reviewed at« in the text of a review report, in lower case.
	static func reviewedCommit(in text: String) -> String? {
		matches(of: #"(?i)(?<=reviewed (?:commit|at))\W{0,6}[0-9a-f]{7,40}\b"#, in: text).first
			.map { String($0.drop { !$0.isHexDigit }).lowercased() }
	}

	/// The pull requests with `needsNewReview` and `reviewedCommit` for each pull request in `reviews`. The next step of
	/// such a pull request is for the user.
	static func withNewReviews(_ reviews: [NewReview], in pullRequests: [[String: Any]]) -> [[String: Any]] {
		let byID = Dictionary(reviews.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
		return pullRequests.map { pullRequest in
			guard let id = pullRequest["id"] as? Int, let review = byID[id] else { return pullRequest }
			var pullRequest = pullRequest
			pullRequest["needsNewReview"] = true
			pullRequest["reviewedCommit"] = review.reviewedCommit
			pullRequest["isMyTurn"] = true
			return pullRequest
		}
	}

	/// The overview with the next action »Run `/nn-review #<ID>` again« for each pull request in `reviews`: the first
	/// sub-item of its task, or the one after the merge of a merge conflict. A pull request without a task in a PR section
	/// gets a new task in its section.
	static func withNewReviewTasks(_ reviews: [NewReview], jiraBrowseURL: String?, in overview: String) -> String {
		let parts = overview.components(separatedBy: "\n## ")
		let tasks = reviews.map { review -> KeptTask in
			let action = "    - [ ] Run `/nn-review #\(review.id)` again, because the PR has new commits after the review of `\(review.reviewedCommit)`."
			for part in parts.dropFirst() where (turnSections + ["Draft PRs"]).contains(title(of: part)) {
				let lines = part.components(separatedBy: "\n")
				guard let block = taskBlocks(in: part).first(where: { block in
					let line = lines[block.lowerBound]
					return line.contains("[`#\(review.id)`](") || line.contains("[#\(review.id)](")
				}) else { continue }
				// The merge comes first, because it makes a new commit that the review must see.
				let merge = review.hasMergeConflict ? lines[block].dropFirst().first { $0.lowercased().contains("merge conflict") } : nil
				return KeptTask(section: title(of: part), lines: [lines[block.lowerBound]] + (merge.map { [$0] } ?? []) + [action])
			}
			let titleLine = DiDi.titleLine(id: review.id, url: review.url, title: review.title, jiraBrowseURL: jiraBrowseURL)
			let merge = review.hasMergeConflict ? ["    - [ ] Merge `\(review.destination)` into the branch and solve the merge conflict."] : []
			return KeptTask(section: review.section, lines: ["- [ ] " + titleLine] + merge + [action])
		}
		return withKeptTasks(tasks, in: overview)
	}

	/// The sections where Claude can write `KEEP <ID>`.
	static let keepSections = ["Remaining Tickets in this Sprint", "Open Branches", "Optional Work", cleanupSection]

	/// The IDs of the old tasks in ``keepSections`` whose plans and reports did not change and got no new commits:
	/// - The task names at least one file of `files`, by a `file://` link or by a path in backticks that ends in `.md`.
	/// - Each named file has `changedAfterOldOverview` and `newCommits` false. A file that `files` does not have counts as
	///   changed, and so does a file of `files` whose name the task text has and that changed.
	/// - No pull request of the title line is in `changedPullRequests`.
	/// - With `tickets`, no ticket of the title line is done, and the 🚫 of the title line is still right: a ticket of the
	///   title line is blocked, or a pull request of the title line is in `blockedPullRequests`.
	/// A ticked task does not count.
	static func unchangedTasks(in old: String, files: [[String: Any]], changedPullRequests: Set<Int>, tickets: [String: [String: Any]]? = nil,
		blockedPullRequests: Set<Int> = []) -> [String] {
		let isUnchanged = { (file: [String: Any]) in file["changedAfterOldOverview"] as? Bool == false && file["newCommits"] as? Bool == false }
		var byPath: [String: Bool] = [:]
		var byName: [String: Bool] = [:]
		for file in files {
			guard let url = (file["url"] as? String).flatMap(URL.init(string:)) else { continue }
			byPath[url.path] = (byPath[url.path] ?? true) && isUnchanged(file)
			byName[url.lastPathComponent] = (byName[url.lastPathComponent] ?? true) && isUnchanged(file)
		}
		let changedNames = byName.filter { !$0.value }.keys
		return old.components(separatedBy: "\n## ").dropFirst().filter { keepSections.contains(title(of: $0)) }.flatMap { part in
			let lines = part.components(separatedBy: "\n")
			return taskBlocks(in: part).compactMap { block -> String? in
				let title = lines[block.lowerBound]
				guard !isTicked(title), let id = firstGroup(of: #"^- \[[^\]]\] `([A-Z]\d+)`"#, in: title) else { return nil }
				let text = lines[block].joined(separator: "\n")
				let links = matches(of: #"(?<=\]\()file://[^)\s]+(?=\))"#, in: text).compactMap { URL(string: $0)?.path }
				let codePaths = matches(of: #"(?<=`)[^`\s]+\.md(?=`)"#, in: text).map { ($0 as NSString).lastPathComponent }
				let pullRequests = matches(of: #"(?<=#)\d+(?=`?\]\()"#, in: title).compactMap { Int($0) }
				guard !links.isEmpty || !codePaths.isEmpty, links.allSatisfy({ byPath[$0] == true }), codePaths.allSatisfy({ byName[$0] == true }),
					!changedNames.contains(where: text.contains), pullRequests.allSatisfy({ !changedPullRequests.contains($0) }) else { return nil }
				if let tickets {
					let keys = matches(of: #"(?<=\[)[A-Z][A-Z0-9]+-\d+(?=\]\()"#, in: title)
					guard !keys.contains(where: { tickets[$0]?["done"] as? Bool == true }) else { return nil }
					let isBlocked = keys.contains { tickets[$0]?["blocked"] as? Bool == true } || pullRequests.contains(where: blockedPullRequests.contains)
					guard isBlocked == leadingMarks(of: title).contains(blockedMark) else { return nil }
				}
				return id
			}
		}
	}

	/// The overview with each KEEP line of Claude, e.g. `- [ ] KEEP O8`, replaced by the task with this ID in the sections
	/// of Claude in `old`, with its sub-items. A ticked sub-item goes away with its own sub-items. A task whose sub-items
	/// with a checkbox are all ticked is done and goes away. A KEEP with the ID of a next action, e.g. `O8a`, gives that
	/// next action as a task. A KEEP line with an ID that `old` does not have goes away.
	static func withKeptByID(in overview: String, old: String) -> String {
		let oldLines = withoutAppSections(old).components(separatedBy: "\n")
		var blocks: [String: [String]] = [:]
		for (index, line) in oldLines.enumerated() {
			if let id = firstGroup(of: #"^\s+- \[[^xX\]]\] `([A-Z]\d+[a-z]+)` "#, in: line), blocks[id] == nil {
				blocks[id] = [String(line.drop { $0 == " " || $0 == "\t" })]
				continue
			}
			guard let id = firstGroup(of: #"^- \[[^\]]\] `([A-Z]\d+)`"#, in: line), blocks[id] == nil else { continue }
			var block = [line]
			var skipIndent: Int?
			var steps = 0
			var openSteps = 0
			for next in oldLines[(index + 1)...] {
				guard indent(of: next) > 0, !next.trimmingCharacters(in: .whitespaces).isEmpty else { break }
				if let skip = skipIndent, indent(of: next) > skip { continue }
				let hasBox = next.range(of: #"^\s*- \[[^\]]\] "#, options: .regularExpression) != nil
				steps += hasBox ? 1 : 0
				skipIndent = isTicked(next) ? indent(of: next) : nil
				if skipIndent == nil {
					openSteps += hasBox ? 1 : 0
					block.append(next)
				}
			}
			blocks[id] = steps > 0 && openSteps == 0 ? [] : block
		}
		return overview.components(separatedBy: "\n").flatMap { line -> [String] in
			guard let id = firstGroup(of: #"^\s*- \[ \] (?:\S+ )*?KEEP:? `?([A-Z]\d+[a-z]*)`?\.?(?:\s.*)?$"#, in: line) else { return [line] }
			return blocks[id] ?? []
		}.joined(separator: "\n")
	}

	// MARK: - Jira

	/// The open tickets of the user in the open sprints.
	static let sprintJQL = "sprint in openSprints() AND assignee = currentUser() AND statusCategory != Done"
	/// The tickets of the user that are in ``forgottenStates`` and in no sprint.
	static let forgottenJQL = #"assignee = currentUser() AND status in ("In Progress", "Untested") AND sprint is EMPTY"#
	/// ``forgottenJQL`` for a Jira that does not know one of the states. The app keeps only the tickets in ``forgottenStates``.
	static let forgottenFallbackJQL = #"assignee = currentUser() AND statusCategory = "In Progress" AND sprint is EMPTY"#
	static let forgottenStates: Set<String> = ["In Progress", "Untested"]
	/// The most other tickets that the app fetches, so that a long old overview cannot cause many requests.
	static let ticketLimit = 300

	/// The Jira searches of a run: the start of the ticket links, if the site is known, and the sprint and forgotten
	/// tickets, or the reason why Jira is not available.
	struct JiraSearch {
		var browseURL: String?
		var result: Result<(jira: Jira, sprint: [[String: Any]], forgotten: [[String: Any]]), Error>
	}

	/// Connects to Jira and searches the sprint and the forgotten tickets at the same time.
	@MainActor
	static func jiraSearch(_ report: Report, old: String?) async -> JiraSearch {
		let environment = await report.loginEnvironment(Jira.variables)
		let browseURL = Jira.site(environment: environment, old: old).map(Jira.browseURL)
		do {
			let jira = try await Jira.connect(environment: environment, old: old, get: report.system.get)
			async let sprint = jira.search(sprintJQL)
			async let forgotten = forgottenTickets(jira)
			return JiraSearch(browseURL: browseURL, result: .success((jira, try await sprint, try await forgotten)))
		} catch {
			return JiraSearch(browseURL: browseURL, result: .failure(error))
		}
	}

	/// The tickets of ``forgottenJQL``. A Jira that does not know one of the states answers with HTTP 400.
	static func forgottenTickets(_ jira: Jira) async throws -> [[String: Any]] {
		do {
			return try await jira.search(forgottenJQL)
		} catch Jira.Failure.status(400) {
			return try await jira.search(forgottenFallbackJQL).filter { Jira.status(of: $0).map(forgottenStates.contains) ?? false }
		}
	}

	/// The Jira data of the run:
	/// - `browseURL`: the start of each ticket link, if the site is known.
	/// - `sprint` and `forgotten`: the IDs of the tickets of the two searches.
	/// - `tickets`: the facts of each ticket by its ID: of the two searches, and of the other tickets in `texts` with a
	///   project key in `projectKeys` or of a ticket of the two searches. If the request for the other tickets fails,
	///   only the tickets of the two searches are in it.
	/// - `error`: the reason, in place of `sprint`, `forgotten` and `tickets`, if Jira is not available.
	static func jiraData(_ search: JiraSearch, texts: [String], projectKeys: Set<String>) async -> [String: Any] {
		var data: [String: Any] = [:]
		data["browseURL"] = search.browseURL
		do {
			let (jira, sprint, forgotten) = try search.result.get()
			let found = sprint + forgotten
			let known = Set(found.compactMap { $0["key"] as? String })
			let keys = ticketKeys(in: texts, projectKeys: projectKeys.union(known.map(projectKey))).filter { !known.contains($0) }
			let others = (try? await jira.tickets(Array(keys.prefix(ticketLimit)))) ?? []
			data["browseURL"] = jira.browseURL
			data["sprint"] = sprint.compactMap { $0["key"] as? String }
			data["forgotten"] = forgotten.compactMap { $0["key"] as? String }
			data["tickets"] = Dictionary((found + others).compactMap(Jira.facts), uniquingKeysWith: { first, _ in first })
		} catch let error as URLError {
			data["error"] = "No connection to Jira: \(error.localizedDescription)"
		} catch {
			data["error"] = "\(error)"
		}
		return data
	}

	/// The ticket IDs in `texts` with a project key in `projectKeys`, sorted. A text like `UTF-8` has no such key.
	static func ticketKeys(in texts: [String], projectKeys: Set<String>) -> [String] {
		Set(texts.flatMap { matches(of: ticketPattern, in: $0.uppercased()) }.filter { projectKeys.contains(projectKey(of: $0)) }).sorted()
	}

	// MARK: - Pull requests

	/// The most pull requests that get their details at the same time. Each one sends four requests.
	static let parallelDetails = 5

	/// The open pull requests. The ones of the user, as author or reviewer, also get their open tasks, newest comments,
	/// newest build states and merge conflict.
	private static func pullRequests(_ bitbucket: Bitbucket, me: String) async throws -> [[String: Any]] {
		let fields = ["id", "title", "draft", "author.display_name", "participants.role", "participants.approved", "participants.state",
			"participants.user.display_name", "links.html.href", "comment_count", "task_count", "updated_on", "source.branch.name",
			"source.commit.hash", "destination.branch.name"]
		var pullRequests = try await bitbucket.values("/pullrequests", query: ["state": "OPEN", "pagelen": "50"], fields: fields)
			.filter { !isDraftOfOthers($0, me: me) }
		let detailed = pullRequests.indices.filter { concerns(pullRequests[$0], me: me) }.prefix(detailLimit)
			.compactMap { index in (pullRequests[index]["id"] as? Int).map { (index: index, id: $0) } }
		let allDetails = try await inParallel(detailed.map(\.id), limit: parallelDetails) { try await details(bitbucket, id: $0) }
		for (pullRequest, details) in zip(detailed, allDetails) {
			let index = pullRequest.index
			pullRequests[index].merge(details.values) { $1 }
			pullRequests[index]["waitsForMyReview"] = waitsForReview(pullRequests[index], me: me)
			pullRequests[index]["isMyTurn"] = isMyTurn(pullRequests[index], me: me)
		}
		return pullRequests
	}

	/// The fields that ``details(_:id:)`` adds to a pull request.
	private struct Details: @unchecked Sendable {
		var values: [String: Any]
	}

	/// The open tasks, newest comments, newest build states and merge conflict of a pull request. The four requests run at
	/// the same time.
	private static func details(_ bitbucket: Bitbucket, id: Int) async throws -> Details {
		async let tasks = bitbucket.values("/pullrequests/\(id)/tasks", query: ["q": "state=\"UNRESOLVED\"", "pagelen": "50"],
			fields: ["content.raw", "creator.display_name"], maxPages: 1)
		async let comments = bitbucket.values("/pullrequests/\(id)/comments", query: ["sort": "-created_on", "pagelen": "10"],
			fields: ["content.raw", "user.display_name", "user.type", "created_on", "inline.path", "deleted"], maxPages: 1)
		async let statuses = bitbucket.values("/pullrequests/\(id)/statuses", query: ["sort": "-updated_on", "pagelen": "5"],
			fields: ["state", "name", "updated_on"], maxPages: 1)
		async let mergeConflict = hasMergeConflict(bitbucket, id: id)
		return try await Details(values: [
			"openTasks": tasks.map { Bitbucket.shortened($0) },
			"newestComments": comments.filter { $0["deleted"] as? Bool != true }.map { Bitbucket.shortened($0) },
			"buildStatuses": statuses,
			"hasMergeConflict": mergeConflict,
		])
	}

	/// The results of `body` for each of `items`, in the order of `items`. At most `limit` calls run at the same time.
	/// The first error stops the other calls and comes out of this function.
	static func inParallel<Item: Sendable, Result: Sendable>(_ items: [Item], limit: Int,
		_ body: @escaping @Sendable (Item) async throws -> Result) async throws -> [Result] {
		try await withThrowingTaskGroup(of: (Int, Result).self) { group in
			var results = [Result?](repeating: nil, count: items.count)
			for index in items.indices {
				// Each new call waits for the end of an older one.
				if index >= limit, let (done, result) = try await group.next() { results[done] = result }
				group.addTask { (index, try await body(items[index])) }
			}
			for try await (index, result) in group { results[index] = result }
			return results.map { $0! }
		}
	}

	/// A merged pull request of another dev, for ``otherMergesSection(_:old:)``.
	struct Merge {
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
		participants(of: pullRequest).contains { userName(of: $0) == me && ($0["approved"] as? Bool == true || $0["state"] is String) }
	}

	private static func participants(of pullRequest: [String: Any]) -> [[String: Any]] { pullRequest["participants"] as? [[String: Any]] ?? [] }

	/// The display name of the user of a participant or a comment.
	private static func userName(of item: [String: Any]) -> String? { (item["user"] as? [String: Any])?["display_name"] as? String }

	/// The participant entry of the user as a reviewer of the pull request.
	private static func myReview(of pullRequest: [String: Any], me: String) -> [String: Any]? {
		participants(of: pullRequest).first { userName(of: $0) == me && $0["role"] as? String == "REVIEWER" }
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
		Bitbucket.isAuthor(of: pullRequest, me: me) || myReview(of: pullRequest, me: me) != nil
	}

	/// The author waits for the user: the user reviews the pull request, it is no draft, and the user did not pass it
	/// to the author.
	static func waitsForReview(_ pullRequest: [String: Any], me: String) -> Bool {
		myReview(of: pullRequest, me: me) != nil && pullRequest["draft"] as? Bool != true && !isPassedToAuthor(pullRequest, me: me)
	}

	/// The user passed the pull request of another author to the author: the user approved it or asked for changes,
	/// it has an open task of the user, or the newest comment is of the user. A comment of an app does not count.
	static func isPassedToAuthor(_ pullRequest: [String: Any], me: String) -> Bool {
		let mine = participants(of: pullRequest).first { userName(of: $0) == me }
		let tasks = pullRequest["openTasks"] as? [[String: Any]] ?? []
		let newestComment = (pullRequest["newestComments"] as? [[String: Any]])?
			.first { ($0["user"] as? [String: Any])?["type"] as? String != "app_user" }
		return mine?["approved"] as? Bool == true || mine?["state"] as? String == "changes_requested"
			|| tasks.contains { ($0["creator"] as? [String: Any])?["display_name"] as? String == me }
			|| newestComment.map { userName(of: $0) == me } ?? false
	}

	/// The user has the next step. In a pull request of another author, the author waits for the review of the user.
	/// In a pull request of the user, it has an open task, a merge conflict, a
	/// failed newest build, a request for changes, a newest comment of another person, or the approval of each reviewer.
	/// A comment of an app, for example of the pipeline, does not count.
	static func isMyTurn(_ pullRequest: [String: Any], me: String) -> Bool {
		let participants = participants(of: pullRequest)
		guard Bitbucket.isAuthor(of: pullRequest, me: me) else { return waitsForReview(pullRequest, me: me) }
		let reviewers = participants.filter { $0["role"] as? String == "REVIEWER" }
		let newestComment = (pullRequest["newestComments"] as? [[String: Any]])?
			.first { ($0["user"] as? [String: Any])?["type"] as? String != "app_user" }
		return (pullRequest["openTasks"] as? [Any])?.isEmpty == false
			|| pullRequest["hasMergeConflict"] as? Bool == true
			|| (pullRequest["buildStatuses"] as? [[String: Any]])?.first?["state"] as? String == "FAILED"
			|| participants.contains { $0["state"] as? String == "changes_requested" }
			|| newestComment.map { userName(of: $0) != me } ?? false
			|| (!reviewers.isEmpty && reviewers.allSatisfy { $0["approved"] as? Bool == true })
	}
}

/// Counts the tasks in the headings again after the user changes the file, e.g. ticks a task, and gives a new task its ID. It checks the change date
/// every 2 seconds, which works for each way of saving: in place, or as a new file. It writes only after the file stayed
/// the same for one check, so that it does not change the file while the user types.
@MainActor
final class SectionCountKeeper {
	static let interval: TimeInterval = 2
	/// The file to watch. It changes when a run writes a file with a new date.
	let file: @MainActor () -> URL?
	/// While this is true, the keeper does not change the file.
	let isPaused: @MainActor () -> Bool
	private var fileURL: URL?
	private var timer: Timer?
	/// The change date at the last check, and whether the file changed since the last count.
	private var lastDate: Date?
	private var isChanged = false

	init(isPaused: @escaping @MainActor () -> Bool = { false }, file: @escaping @MainActor () -> URL?) {
		self.isPaused = isPaused
		self.file = file
	}

	convenience init(fileURL: URL) {
		self.init { fileURL }
	}

	func start() {
		timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
			Task { @MainActor in self?.check() }
		}
	}

	/// Counts again when the file stayed the same since a change.
	func check() {
		guard !isPaused() else { return }
		let current = file()
		if current != fileURL {
			(fileURL, lastDate, isChanged) = (current, current?.modificationDate, false)
			return
		}
		let date = fileURL?.modificationDate
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
		guard let fileURL, let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
		let counted = MorningOverview.numbered(text)
		guard counted != text else { return }
		try? counted.write(to: fileURL, atomically: true, encoding: .utf8)
		lastDate = fileURL.modificationDate
	}
}

private extension URL {
	/// The change date of the file, read without a cache: `URL.resourceValues` can give an old date for the same URL.
	var modificationDate: Date? {
		(try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
	}
}
