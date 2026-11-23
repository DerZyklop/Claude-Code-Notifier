import CryptoKit
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
		readySound: "Funk",
		backupName: nil,
		folderKey: SettingsKey.morningOverviewFolder,
		readFolderKeys: [SettingsKey.morningOverviewPlansFolder, SettingsKey.morningOverviewReviewsFolder],
		heading: "# Morning overview",
		statsFileName: "stats.md",
		didWrite: { report, input in
			if let heads = input.appData[MorningOverview.headsKey] as? [Int: String] { MorningOverview.saveHeads(heads, report) }
			if let states = input.appData[MorningOverview.statesKey] as? [Int: String] {
				MorningOverview.saveStates(states, written: report.lastWritten ?? "", report)
			}
			if let run = input.appData[MorningOverview.outdatedKey] as? MorningOverview.OutdatedRun {
				MorningOverview.saveOutdated(run.state(written: report.lastWritten ?? ""), report)
			}
			if let states = input.appData[MorningOverview.namedStatesKey] as? MorningOverview.NamedStates {
				MorningOverview.saveNamedStates(states, written: report.lastWritten ?? "", report)
			}
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
		var data: [String: Any] = ["me": me, "workspaces": workspaces.map { $0.filter { $0.key != "head" } }, "branches": branches,
			"remoteBranches": remoteBranches]
		var appData: [String: Any] = [:]
		var pullRequests: [[String: Any]]
		let bitbucket: Bitbucket
		do {
			bitbucket = try await report.bitbucket()
			report.step("Bitbucket login")
			pullRequests = try await Self.pullRequests(bitbucket, me: me)
			report.step("Open pull requests")
			let now = system.now()
			appData[staleKey] = ids(of: pullRequests.filter { isStale($0, now: now) })
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
		let refs = await report.git(["for-each-ref", "--format=%(refname:short)%09%(committerdate:unix)%09%(objectname:short)", "refs/heads",
			"refs/remotes"]).split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
		let withoutRemote = { (name: String) in name.replacingOccurrences(of: #"^origin/"#, with: "", options: .regularExpression) }
		let known = Set(refs.compactMap(\.first).map(withoutRemote))
		// A commit on `origin` counts too, e.g. a push from a worktree without a local branch.
		let branchDates = Dictionary(refs.filter { $0.count == 3 }
			.compactMap { fields in Double(fields[1]).map { (withoutRemote(fields[0]), Date(timeIntervalSince1970: $0)) } }, uniquingKeysWith: max)
		let tips = Dictionary(refs.filter { $0.count == 3 }.map { ($0[0], $0[2]) }, uniquingKeysWith: { first, _ in first })
		let reviewsFolder = folder(SettingsKey.morningOverviewReviewsFolder, system: system)
		let fileFacts = { (files: [URL]) in
			Self.plans(of: files, old: old, now: system.now(), calendar: system.calendar, branches: branches, knownBranches: known,
				pullRequests: pullRequests, branchDates: branchDates, changedPullRequests: changedPullRequests,
				closedPullRequests: closedPullRequests, reviewsFolder: reviewsFolder)
		}
		let plans = fileFacts(markdownFiles(in: plansFolder))
		let projectFiles = projectFiles(system: system)
		let projectFacts = fileFacts(projectFiles)
		// The states of the closed pull requests of the review reports come while the other steps run.
		let reportIDs = Set(projectFacts.compactMap { $0["reviewedPullRequest"] as? Int })
		let closedIDs = reportIDs.subtracting(ids(of: pullRequests)).sorted()
		async let closedStates = closedStates(bitbucket, ids: closedIDs)
		let reviews = await withoutCommitsOfOthers(newReviews(in: projectFiles, reviewsFolder: reviewsFolder, pullRequests: pullRequests, me: me),
			bitbucket, me: me)
		appData[newReviewsKey] = reviews
		pullRequests = withNewReviews(reviews, in: pullRequests)
		data["pullRequests"] = pullRequests.map(withoutTasks)
		appData[othersTurnKey] = ids(of: pullRequests.filter { $0["isMyTurn"] as? Bool == false })
		let pullRequestStates = Dictionary(pullRequests.compactMap { pullRequest in (pullRequest["id"] as? Int).map { ($0, state(of: pullRequest)) } },
			uniquingKeysWith: { first, _ in first })
		appData[statesKey] = pullRequestStates
		let lastStates = lastStates(report, old: old)
		// A pull request without a saved state counts as changed. So does one with a new or changed review report, or with
		// a commit on its branch since the old overview, e.g. a local commit that is not pushed yet.
		let changedReports = Set(projectFacts.filter { $0["changedAfterOldOverview"] as? Bool == true }
			.compactMap { $0["reviewedPullRequest"] as? Int })
		let since = old.flatMap { Report.updated(in: $0, calendar: system.calendar) } ?? .distantFuture
		let unchangedPullRequests = Set(pullRequestStates.filter { id, state in
			guard lastStates[String(id)] == state, !changedReports.contains(id) else { return false }
			let branch = pullRequests.first { $0["id"] as? Int == id }.flatMap(sourceBranch)
			return (branch.flatMap { branchDates[$0] } ?? .distantPast) < since
		}.keys)
		if let old {
			appData[oldOverviewKey] = old
			// The same text that KEEP uses, so that Claude needs no read and the app sections do not count.
			data["oldOverview"] = withoutDeleteCommands(in: withoutAppSections(old))
		}
		let memoryIndex = claudeProjectFolder(of: system.folder.path).appendingPathComponent("memory/MEMORY.md")
		if let index = try? String(contentsOf: memoryIndex, encoding: .utf8) { data["memoryIndex"] = index }
		report.step("Plans")
		let sessions = await sessions(in: claudeProjectFolder(of: system.folder.path), now: system.now(), calendar: system.calendar,
			archived: system.archivedSessionIDs() ?? [])
		report.step("Sessions")
		data["sessions"] = sessions.open
		data["archivedSessions"] = sessions.archivedTitles
		let texts = branches.compactMap { $0["name"] as? String } + remoteBranches.compactMap { $0["name"] as? String }
			+ pullRequests.flatMap { [$0["title"] as? String, sourceBranch(of: $0)].compactMap { $0 } }
			+ (plans + projectFacts).flatMap { $0["tickets"] as? [String] ?? [] } + sessions.open.compactMap { $0["title"] as? String }
			+ projectFiles.map(\.lastPathComponent) + [old ?? ""]
		var search = await jiraSearch
		// The Bitbucket requests worked, so the network works now, e.g. after a wake.
		if case .failure(let error) = search.result, error is URLError { search = await Self.jiraSearch(report, old: old) }
		let jira = await jiraData(search, texts: texts, projectKeys: projectKeys(branches: branches, pullRequests: pullRequests))
		data["jira"] = jira
		report.step("Jira")
		let lastOutdated = lastOutdated(report)
		let jiraTickets = jira["tickets"] as? [String: [String: Any]] ?? [:]
		let states = await closedStates
		// One check for both lists, so that ``checkLimit`` counts all files.
		let checked = withOutdatedCheck(plans + projectFacts, old: old, last: lastOutdated, jiraTickets: jiraTickets,
			closedStates: states ?? [:])
		var run = checked.run
		if states == nil || jira["error"] != nil || jira[ticketsIncompleteKey] as? Bool == true, let lastOutdated {
			run = withLastState(run, files: checked.files, last: lastOutdated)
		}
		run.names = Set(checked.files.compactMap { ($0["url"] as? String).flatMap(URL.init(string:))?.lastPathComponent })
		appData[outdatedKey] = run
		appData[deleteTasksKey] = checked.deleteTasks
		appData[linksKey] = Links(pullRequests: Dictionary(pullRequests.compactMap { pullRequest in
			guard let id = pullRequest["id"] as? Int, let url = htmlURL(of: pullRequest) else { return nil }
			return (id, url)
		}, uniquingKeysWith: { first, _ in first }), repository: bitbucket.repository, jiraBrowseURL: jira["browseURL"] as? String,
			projectKeys: projectKeys(branches: branches, pullRequests: pullRequests).union(jiraTickets.keys.map(projectKey)),
			files: (plans + projectFacts).compactMap { $0["url"] as? String },
			// The parent of a project folder also counts, e.g. for `[reviews/a.md]`.
			folders: [system.folder.path, plansFolder.path] + projectFolders(system: system).flatMap { [$0.path, $0.deletingLastPathComponent().path] })
		let memoryFolder = claudeProjectFolder(of: system.folder.path).appendingPathComponent("memory")
		let namedStates = namedStates(branches: branches + remoteBranches, tips: tips, workspaces: workspaces, sessions: sessions.open,
			tickets: jira["tickets"] as? [String: [String: Any]], memory: memoryState(of: memoryFolder))
		appData[namedStatesKey] = namedStates
		var unchanged: [String] = []
		if let old {
			let merged = Set((appData[otherMergesSection] as? [Merge] ?? []).map(\.id))
			let named = lastNamedStates(report, old: old).map { last in
				NamedFacts(now: namedStates, last: last, archivedTitles: sessions.archivedTitles, sprint: Set(jira["sprint"] as? [String] ?? []),
					pullRequestBranches: Set(pullRequests.compactMap { sourceBranch(of: $0) }),
					pullRequestTitles: pullRequests.compactMap { $0["title"] as? String },
					changedPullRequests: changedPullRequests.union(closedPullRequests).union(merged)
						.union(ids(of: pullRequests).subtracting(unchangedPullRequests)), openPullRequests: ids(of: pullRequests),
					tickets: jira["tickets"] as? [String: [String: Any]])
			}
			unchanged = unchangedTasks(in: old, files: checked.files,
				changedPullRequests: changedPullRequests, tickets: jira["tickets"] as? [String: [String: Any]],
				blockedPullRequests: appData[blockedKey] as? Set<Int> ?? [], closedPullRequests: closedPullRequests,
				unchangedPullRequests: unchangedPullRequests, openPullRequests: ids(of: pullRequests), lastNames: lastOutdated?.names,
				localNames: localNames(workspaces: workspaces, memoryFolder: memoryFolder, old: old, projectFolder: system.folder), named: named)
			data["unchangedTasks"] = unchanged
		}
		let files = withTexts(checked.files, planCount: plans.count, old: old, unchangedTasks: unchanged)
		if FileManager.default.fileExists(atPath: plansFolder.path) { data["plans"] = Array(files.prefix(plans.count)) }
		data["projectFiles"] = Array(files.dropFirst(plans.count))
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
		let todayTasks = tasks(of: system)
		if !todayTasks.isEmpty {
			facts.append("Weekday tasks: \(todayTasks.joined(separator: ", ")). The app puts them at the top. Leave them out, and also the tickets that they cover.")
		}
		let names = appSections.map { "»\($0)«" }
		facts.append("The app writes the sections \(names.dropLast().joined(separator: ", ")) and \(names.last!). Leave them out, and also the tasks in them.")
		let memory = projectFolder.appendingPathComponent("memory")
		if exists(memory) { facts.append("Memory folder: \(memory.path)") }
		if exists(plansFolder) { facts.append("Plans folder: \(plansFolder.path)") }
		for (label, key) in [("Project plans folder", SettingsKey.morningOverviewPlansFolder), ("Reviews folder", SettingsKey.morningOverviewReviewsFolder)] {
			if let folder = folder(key, system: system), exists(folder) { facts.append("\(label): \(folder.path)") }
		}
		return facts
	}

	/// The folder of the setting `key`, or `nil` while it is empty. A relative path starts at the project folder.
	static func folder(_ key: String, system: Report.System) -> URL? {
		Report.settingsFolder(key, system: system)
	}

	/// The folders of the plans and of the review reports of the project, from the settings.
	static func projectFolders(system: Report.System) -> [URL] {
		[SettingsKey.morningOverviewPlansFolder, SettingsKey.morningOverviewReviewsFolder].compactMap { folder($0, system: system) }
	}

	/// The `.md` files directly in `folder`, without the files of its subfolders. None for a folder that does not exist.
	static func markdownFiles(in folder: URL) -> [URL] {
		((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".md") }.sorted()
			.map { folder.appendingPathComponent($0) }
	}

	/// The plans and the review reports of the project: the `.md` files in ``projectFolders(system:)``, each file once. The
	/// plans of Claude Code in ``plansFolder`` do not count, because they are in `plans`.
	static func projectFiles(system: Report.System) -> [URL] {
		var seen: Set<String> = Set(markdownFiles(in: plansFolder).map(\.standardizedFileURL.path))
		return projectFolders(system: system).flatMap(markdownFiles).filter { seen.insert($0.standardizedFileURL.path).inserted }
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
	/// - `openPullRequests`: the IDs of the open pull requests that the text names, by number or by source branch, and
	///   the open pull request of a review report (``reviewedPullRequest(of:in:)``).
	/// - `reviewedPullRequest`: the number of the pull request of a review report in `reviewsFolder`.
	/// - `openSteps` and `doneSteps`: the number of checkboxes without and with a tick. Only for a file outside
	///   `reviewsFolder`, because the checkboxes of a review report are no steps.
	static func plans(of files: [URL], old: String?, now: Date, calendar: Calendar, branches: [[String: Any]], knownBranches: Set<String>,
		pullRequests: [[String: Any]], branchDates: [String: Date] = [:], changedPullRequests: Set<Int> = [],
		closedPullRequests: Set<Int> = [], reviewsFolder: URL? = nil, changeDate: (URL) -> Date? = changeDate(of:)) -> [[String: Any]] {
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
			var numbers = Set(matches(of: #"(?<=#|PR |pull-requests/)\d+\b"#, in: text).compactMap { Int($0) })
			// A review report names its pull request at the start of its name.
			let reviewed = reviewedPullRequest(of: file, in: reviewsFolder)
			if let reviewed {
				numbers.insert(reviewed)
				plan["reviewedPullRequest"] = reviewed
			}
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
			if !isFile(file, in: reviewsFolder) {
				plan["openSteps"] = matches(of: #"(?m)^\s*- \[ \]"#, in: text).count
				plan["doneSteps"] = matches(of: #"(?m)^\s*- \[[xX]\]"#, in: text).count
			}
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
		var text = withKeptByID(in: withoutDeleteCommands(in: withoutAppSections(output)), old: input.appData[oldOverviewKey] as? String ?? "")
		let links = input.appData[linksKey] as? Links
		text = withLinks(links ?? Links(), in: text)
		// A file that is no plan or project file any more counts as gone too, e.g. after a change of a folder setting.
		let files = links.map { Set($0.files.compactMap { URL(string: $0)?.path }) }
		text = withoutDoneCleanupTasks(in: withoutDeleteTasksOfGoneFiles(in: text) { path in
			FileManager.default.fileExists(atPath: path) && files?.contains(path) != false
		})
		text = withKeptTasks(keptTasks(in: old, lastWritten: report.lastWritten), in: text)
		text = withNewReviewTasks(input.appData[newReviewsKey] as? [NewReview] ?? [],
			jiraBrowseURL: (input.data["jira"] as? [String: Any])?["browseURL"] as? String, in: text)
		text = withDeleteTasks(input.appData[deleteTasksKey] as? [DeleteTask] ?? [], in: text)
		text = withWeekdayTasks(tasks(of: system), done: isSameDay ? doneWeekdayTasks(in: old) : [], in: text)
		text = Report.hashLinksAsCode(in: subItemsIndented(in: text))
		text = withMarks(othersTurn: input.appData[othersTurnKey] as? Set<Int> ?? [], stale: input.appData[staleKey] as? Set<Int> ?? [],
			blocked: input.appData[blockedKey] as? Set<Int> ?? [], in: text)
		text = withDeleteCommands(in: numbered(withTasksSorted(in: text)))
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

	/// The main folder and each worktree, with uncommitted changes and commits that are on no remote. `head` has the newest
	/// commit, for ``NamedStates`` only.
	@MainActor
	private static func workspaces(_ report: Report) async -> [[String: Any]] {
		var result: [[String: Any]] = []
		for entry in worktrees(in: await report.git(["worktree", "list", "--porcelain"])) {
			let folder = URL(fileURLWithPath: entry.path)
			let changes = await report.git(["status", "--porcelain"], in: folder).split(separator: "\n").prefix(30).map(String.init)
			let commits = await report.git(["log", "--oneline", "-n", "20", "HEAD", "--not", "--remotes"], in: folder)
				.split(separator: "\n").map(String.init)
			result.append(["path": entry.path, "branch": entry.branch ?? "detached HEAD", "uncommittedChanges": changes,
				"commitsOnNoRemote": commits, "head": entry.head ?? ""])
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

	/// The worktrees in the output of `git worktree list --porcelain`, with the newest commit of each.
	static func worktrees(in output: String) -> [(path: String, branch: String?, head: String?)] {
		output.components(separatedBy: "\n\n").compactMap { block in
			let lines = block.split(separator: "\n")
			guard let path = lines.first(where: { $0.hasPrefix("worktree ") })?.dropFirst("worktree ".count) else { return nil }
			let branch = lines.first(where: { $0.hasPrefix("branch refs/heads/") })?.dropFirst("branch refs/heads/".count)
			let head = lines.first(where: { $0.hasPrefix("HEAD ") })?.dropFirst("HEAD ".count)
			return (String(path), branch.map(String.init), head.map(String.init))
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

	/// The key of the ``state(of:)`` of each open pull request in `appData`, for ``saveStates(_:_:)``.
	static let statesKey = "pullRequestStates"

	/// The version of the rules for the next actions of a pull request. A new version changes each ``state(of:)``, so
	/// that Claude writes the task of each pull request again in the next run.
	static let pullRequestRules = 3

	/// The facts of a pull request that change its next action, as one text: its newest commit, the time of its last
	/// change, its comments and tasks, its newest build, its merge conflict, and whether it is a draft, the turn of the
	/// user or in need of a new review. Bitbucket changes `updated_on` on a push, a comment, a task and a review.
	static func state(of pullRequest: [String: Any]) -> String {
		let number = { (key: String) in (pullRequest[key] as? Int).map(String.init) ?? "" }
		let flag = { (key: String) in pullRequest[key] as? Bool == true ? "1" : "0" }
		let build = (pullRequest["buildStatuses"] as? [[String: Any]])?.first.map { "\($0["name"] as? String ?? "")=\($0["state"] as? String ?? "")" }
		// Bitbucket keeps a review on the participant, so `updated_on` can miss it.
		let reviews = participants(of: pullRequest).map { participant in
			[userName(of: participant) ?? "", participant["role"] as? String ?? "", participant["approved"] as? Bool == true ? "1" : "0",
				participant["state"] as? String ?? ""].joined(separator: ":")
		}.sorted().joined(separator: ",")
		// An edited task or comment keeps the counts, so its text counts too.
		let texts = ((pullRequest["openTasks"] as? [[String: Any]] ?? []) + (pullRequest["newestComments"] as? [[String: Any]] ?? [])).map { item in
			[(item["creator"] as? [String: Any]).flatMap(userName(ofUser:)) ?? userName(of: item) ?? "", item["created_on"] as? String ?? "",
				(item["content"] as? [String: Any])?["raw"] as? String ?? ""].joined(separator: ":")
		}.joined(separator: "\n")
		return [
			"rules=\(pullRequestRules)",
			"head=" + (heads(of: [pullRequest]).values.first ?? ""), "updated=" + (pullRequest["updated_on"] as? String ?? ""),
			"comments=" + number("comment_count"), "tasks=" + number("task_count"),
			"openTasks=" + ((pullRequest["openTasks"] as? [Any]).map { String($0.count) } ?? ""), "build=" + (build ?? ""),
			"conflict=" + flag("hasMergeConflict"), "draft=" + flag("draft"), "myTurn=" + flag("isMyTurn"),
			"newReview=" + flag("needsNewReview"), "reviewed=" + (pullRequest["reviewedCommit"] as? String ?? ""),
			"title=" + (pullRequest["title"] as? String ?? ""), "reviews=" + reviews,
			"texts=" + SHA256.hash(data: Data(texts.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined(),
		].joined(separator: "|")
	}

	/// The display name of a user object, e.g. the creator of a task.
	private static func userName(ofUser user: [String: Any]) -> String? { user["display_name"] as? String }

	/// The file with the ``state(of:)`` of each open pull request at the last run that wrote an overview, and the
	/// `Updated:` time of that overview.
	@MainActor
	private static func statesFile(_ report: Report) -> URL { report.supportFolder.appendingPathComponent("pull-request-states.json") }

	/// The states of the open pull requests at the last run that wrote an overview, by the ID as text. They count only
	/// for the overview of that run, e.g. not after the user deleted it: `old` must have the same `Updated:` time.
	@MainActor
	static func lastStates(_ report: Report, old: String?) -> [String: String] {
		guard let data = try? Data(contentsOf: statesFile(report)),
			let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			let updated = object["updated"] as? String, updated == old.flatMap(updatedLine) else { return [:] }
		return object["states"] as? [String: String] ?? [:]
	}

	/// The text of the `Updated:` line of an overview.
	private static func updatedLine(of overview: String) -> String? { firstGroup(of: #"(?m)^Updated: (.+)$"#, in: overview) }

	/// Saves `states` for the next run, with the `Updated:` time of `written`. Only the open pull requests of this run are
	/// in the file, so it does not grow.
	@MainActor
	static func saveStates(_ states: [Int: String], written: String, _ report: Report) {
		let object: [String: Any] = ["updated": updatedLine(of: written) ?? "",
			"states": Dictionary(uniqueKeysWithValues: states.map { (String($0.key), $0.value) })]
		guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
		try? FileManager.default.createDirectory(at: report.supportFolder, withIntermediateDirectories: true)
		try? data.write(to: statesFile(report), options: .atomic)
	}

	// MARK: - Tasks without files

	/// The key of the ``NamedStates`` of this run in `appData`, for ``saveNamedStates(_:written:_:)``.
	static let namedStatesKey = "namedStates"

	/// The states of the branches, worktrees, sessions and tickets that a task without plans and reports can name. Each
	/// state is a short text that changes with each change of its object.
	struct NamedStates: Equatable {
		/// By the branch name, e.g. `feature/x` or `origin/feature/x`: the newest commit of the branch and of its upstream,
		/// the upstream, the track state, the base branches that hold it, and whether it is empty.
		var branches: [String: String] = [:]
		/// By the folder name of the worktree: a hash of its newest commit, its branch, its uncommitted changes and its
		/// commits that are on no remote.
		var worktrees: [String: String] = [:]
		/// By the ``normalizedTitle(_:)`` of the session: its last change.
		var sessions: [String: String] = [:]
		/// By the key of the ticket: its Jira status, or `nil` without Jira data.
		var tickets: [String: String]? = nil
		/// The ``memoryState(of:)`` of the memory folder of the project.
		var memory: String? = nil
	}

	/// A hash of the names and the change times of the files in the memory `folder`, or `nil` without the folder. A task
	/// can come from a follow-up in the memory, so a change of the memory can change each task.
	static func memoryState(of folder: URL) -> String? {
		guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
		return shortHash(names.sorted().map { "\($0) \(folder.appendingPathComponent($0).modificationDate?.timeIntervalSince1970 ?? 0)" }
			.joined(separator: "\n"))
	}

	/// The first 8 bytes of the SHA256 hash of `text`, as hex.
	private static func shortHash(_ text: String) -> String {
		SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
	}

	/// The ``NamedStates`` of the facts of a run. `tips` has the newest commit of each ref, by its short name.
	static func namedStates(branches: [[String: Any]], tips: [String: String], workspaces: [[String: Any]], sessions: [[String: Any]],
		tickets: [String: [String: Any]]?, memory: String? = nil) -> NamedStates {
		var states = NamedStates()
		for branch in branches {
			guard let name = branch["name"] as? String else { continue }
			let upstream = branch["upstream"] as? String
			let fields: [String?] = [tips[name], upstream.flatMap { tips[$0] }, upstream, branch["track"] as? String,
				(branch["mergedInto"] as? [String])?.joined(separator: ","), branch["empty"] as? Bool == true ? "empty" : nil]
			states.branches[name] = fields.map { $0 ?? "" }.joined(separator: "|")
		}
		// Two worktrees can have the same folder name, so the hash of a name covers all of them.
		let byName = Dictionary(grouping: workspaces.compactMap { workspace -> (name: String, text: String)? in
			guard let path = workspace["path"] as? String else { return nil }
			let fields = [path, workspace["head"] as? String ?? "", workspace["branch"] as? String ?? ""]
				+ (workspace["uncommittedChanges"] as? [String] ?? []) + ["--"] + (workspace["commitsOnNoRemote"] as? [String] ?? [])
			return ((path as NSString).lastPathComponent, fields.joined(separator: "\n"))
		}, by: \.name)
		states.worktrees = byName.mapValues { shortHash($0.map(\.text).sorted().joined(separator: "\n\n")) }
		for session in sessions {
			guard let title = session["title"] as? String, let lastChange = session["lastChange"] as? String else { continue }
			states.sessions[normalizedTitle(title)] = max(states.sessions[normalizedTitle(title)] ?? "", lastChange)
		}
		states.tickets = tickets.map { $0.compactMapValues { $0["status"] as? String } }
		states.memory = memory
		return states
	}

	/// The names of the `.md` files that can change without a commit of a pull request: the files with uncommitted changes
	/// in `workspaces`, the files of the memory `folder`, and each `.md` path in backticks of `old` that exists, relative
	/// to `projectFolder` or absolute, e.g. a file that git ignores.
	static func localNames(workspaces: [[String: Any]], memoryFolder: URL, old: String?, projectFolder: URL) -> Set<String> {
		// A line of `git status --porcelain` is `XY path` or `XY old -> new`.
		var names = Set(workspaces.flatMap { $0["uncommittedChanges"] as? [String] ?? [] }.flatMap { line in
			String(line.dropFirst(3)).components(separatedBy: " -> ").map {
				($0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) as NSString).lastPathComponent
			}
		})
		names.formUnion((try? FileManager.default.contentsOfDirectory(atPath: memoryFolder.path)) ?? [])
		for path in matches(of: #"(?<=`)[^`\s]+\.md(?=`)"#, in: old ?? "") {
			let file = path.hasPrefix("/") ? URL(fileURLWithPath: path) : projectFolder.appendingPathComponent(path)
			if FileManager.default.fileExists(atPath: file.path) { names.insert(file.lastPathComponent) }
		}
		return names.filter { $0.hasSuffix(".md") }
	}

	/// The title of a session in lower case, with one normal space for each run of spaces, e.g. of no-break spaces.
	static func normalizedTitle(_ title: String) -> String {
		title.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ").lowercased()
	}

	/// The facts for the KEEP of an old task without plans and reports, see ``isUnchanged(_:)``.
	struct NamedFacts {
		var now: NamedStates
		/// The states at the last run that wrote the old overview.
		var last: NamedStates
		var archivedTitles: [String] = []
		/// The keys of the tickets in the sprint.
		var sprint: Set<String> = []
		/// The source branches and the titles of the open pull requests.
		var pullRequestBranches: Set<String> = []
		var pullRequestTitles: [String] = []
		/// The pull requests that changed: a new state (``MorningOverview/state(of:)``), closed since the last run, or merged
		/// by others since the old overview.
		var changedPullRequests: Set<Int> = []
		var openPullRequests: Set<Int> = []
		/// The facts of the tickets in Jira, or `nil` without Jira data.
		var tickets: [String: [String: Any]]? = nil

		/// Whether the task `text` names at least one branch or worktree in backticks, an open pull request or a session in
		/// »«, and none of them changed:
		/// - A name with `…` at the end stands for each branch that starts with it.
		/// - A branch or worktree that only one of ``now`` and ``last`` has counts as changed. So does the source branch of
		///   an open pull request, because the pull request covers it now.
		/// - No pull request of the text is in ``changedPullRequests``.
		/// - No session of the text is archived.
		/// - No ticket of the text is in a title or a source branch of an open pull request. With ``tickets``, each ticket
		///   of the text that Jira knows is not done, not in the sprint, and has the same status as at the last run.
		/// - The memory did not change.
		/// Other text in backticks, e.g. a code file, does not count.
		func isUnchanged(_ text: String) -> Bool {
			guard now.memory == last.memory else { return false }
			var tracked = 0
			for token in MorningOverview.matches(of: #"(?<=`)[^`\s]+(?=`)"#, in: text) {
				let names = token.hasSuffix("…")
					? Set(now.branches.keys).union(last.branches.keys).filter { $0.hasPrefix(String(token.dropLast())) }.sorted() : [token]
				for name in names {
					for (nowStates, lastStates) in [(now.branches, last.branches), (now.worktrees, last.worktrees)] {
						guard nowStates[name] != nil || lastStates[name] != nil else { continue }
						guard nowStates[name] == lastStates[name], !pullRequestBranches.contains(name) else { return false }
						tracked += 1
					}
				}
			}
			let numbers = Set(MorningOverview.matches(of: #"(?<=#)\d+\b"#, in: text).compactMap { Int($0) })
			guard numbers.isDisjoint(with: changedPullRequests) else { return false }
			tracked += numbers.intersection(openPullRequests).count
			let archived = Set(archivedTitles.map(MorningOverview.normalizedTitle))
			for quote in MorningOverview.matches(of: #"(?<=»)[^«\n]+(?=«)"#, in: text).map(MorningOverview.normalizedTitle) {
				guard !archived.contains(quote) else { return false }
				guard now.sessions[quote] != nil || last.sessions[quote] != nil else { continue }
				guard now.sessions[quote] == last.sessions[quote] else { return false }
				tracked += 1
			}
			for key in Set(MorningOverview.matches(of: #"\b[A-Z][A-Z0-9]+-\d+\b"#, in: text)) {
				guard !pullRequestBranches.contains(where: { $0.contains(key) }), !pullRequestTitles.contains(where: { $0.contains(key) }) else { return false }
				guard let tickets, tickets[key] != nil else { continue }
				guard tickets[key]?["done"] as? Bool != true, !sprint.contains(key), let status = last.tickets?[key], status == now.tickets?[key]
				else { return false }
			}
			return tracked > 0
		}
	}

	/// The file with the ``NamedStates`` of the last run that wrote an overview, and the `Updated:` time of that overview.
	@MainActor
	private static func namedStatesFile(_ report: Report) -> URL { report.supportFolder.appendingPathComponent("named-states.json") }

	/// The ``NamedStates`` of the last run that wrote an overview. They count only for the overview of that run: `old` must
	/// have the same `Updated:` time.
	@MainActor
	static func lastNamedStates(_ report: Report, old: String?) -> NamedStates? {
		guard let data = try? Data(contentsOf: namedStatesFile(report)),
			let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			let updated = object["updated"] as? String, updated == old.flatMap(updatedLine) else { return nil }
		return NamedStates(branches: object["branches"] as? [String: String] ?? [:], worktrees: object["worktrees"] as? [String: String] ?? [:],
			sessions: object["sessions"] as? [String: String] ?? [:], tickets: object["tickets"] as? [String: String],
			memory: object["memory"] as? String)
	}

	/// Saves `states` for the next run, with the `Updated:` time of `written`. Only the objects of this run are in the file,
	/// so it does not grow.
	@MainActor
	static func saveNamedStates(_ states: NamedStates, written: String, _ report: Report) {
		var object: [String: Any] = ["updated": updatedLine(of: written) ?? "", "branches": states.branches, "worktrees": states.worktrees,
			"sessions": states.sessions]
		if let tickets = states.tickets { object["tickets"] = tickets }
		if let memory = states.memory { object["memory"] = memory }
		guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
		try? FileManager.default.createDirectory(at: report.supportFolder, withIntermediateDirectories: true)
		try? data.write(to: namedStatesFile(report), options: .atomic)
	}

	// MARK: - Outdated files

	/// The key of the URLs of the outdated files in `appData`, for ``saveOutdated(_:_:)``.
	static let outdatedKey = "outdated"
	/// The key of the ``DeleteTask``s in `appData`.
	static let deleteTasksKey = "deleteTasks"
	/// The file facts that only the outdated check needs. The run does not get them.
	static let outdatedCheckFields = ["oldSections", "branches", "unknownBranches", "openSteps", "doneSteps", "reviewedPullRequest"]

	/// The most files that Claude checks in one run, so that a run with many new outdated files ends in time. The other
	/// files come in the next runs.
	static let checkLimit = 5
	/// The most pull requests in one state request.
	static let stateBatch = 50

	/// A task of »Cleanup Work« that the app writes, with the URL of its file.
	struct DeleteTask: Equatable {
		var url: String
		var line: String
	}

	/// The number of the pull request of a review report: a file directly in `reviewsFolder` whose name starts with the
	/// number, e.g. `4341-fix.md`. `nil` without a folder.
	static func reviewedPullRequest(of file: URL, in reviewsFolder: URL?) -> Int? {
		guard isFile(file, in: reviewsFolder) else { return nil }
		return matches(of: #"^\d+(?=-)"#, in: file.deletingPathExtension().lastPathComponent).first.flatMap { Int($0) }
	}

	/// The file is directly in `folder`, not in a subfolder. `false` without a folder.
	static func isFile(_ file: URL, in folder: URL?) -> Bool {
		guard let folder else { return false }
		return file.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path
	}

	/// The states of the closed pull requests in `ids` by their ID: »MERGED«, »DECLINED« or »SUPERSEDED«. `nil` after a
	/// failed request, so that the run goes on without them.
	static func closedStates(_ bitbucket: Bitbucket, ids: [Int]) async -> [Int: String]? {
		var states: [Int: String] = [:]
		for start in stride(from: 0, to: ids.count, by: stateBatch) {
			let numbers = ids[start..<min(start + stateBatch, ids.count)].map { "id=\($0)" }.joined(separator: " OR ")
			// With `q`, Bitbucket ignores a `state` parameter, so the states go into `q`.
			let query = "(state=\"MERGED\" OR state=\"DECLINED\" OR state=\"SUPERSEDED\") AND (\(numbers))"
			guard let values = try? await bitbucket.values("/pullrequests", query: ["q": query, "pagelen": "\(stateBatch)"],
				fields: ["id", "state"], maxPages: 1) else { return nil }
			for value in values {
				if let id = value["id"] as? Int, let state = value["state"] as? String { states[id] = state }
			}
		}
		return states
	}

	/// Why the file of `facts` is outdated, and whether its pull request was declined. `nil` for a file that is not
	/// outdated, also for a file that an open pull request names. Else, the first of these facts counts:
	/// - The file is the review report of a pull request in `closedStates`, see `reviewedPullRequest` in
	///   ``plans(of:old:now:calendar:branches:knownBranches:pullRequests:branchDates:changedPullRequests:closedPullRequests:reviewsFolder:changeDate:)``.
	///   Only »DECLINED« counts as declined. The code of
	///   a superseded pull request can reach the base branch in the pull request that replaces it.
	/// - A ticket in `tickets` is done in `jiraTickets`.
	/// - A branch in `branches` has `mergedInto`, or `unknownBranches` names a branch.
	/// - `openSteps` is 0 and `doneSteps` is more than 0. A review report has no steps.
	static func outdatedReason(of facts: [String: Any], jiraTickets: [String: [String: Any]], closedStates: [Int: String])
		-> (text: String, declined: Bool)? {
		guard (facts["openPullRequests"] as? [Int] ?? []).isEmpty else { return nil }
		if let id = facts["reviewedPullRequest"] as? Int, let state = closedStates[id] {
			switch state {
			case "DECLINED": return ("#\(id) was declined", true)
			case "SUPERSEDED": return ("#\(id) was superseded", false)
			default: return ("#\(id) is merged", false)
			}
		}
		for key in facts["tickets"] as? [String] ?? [] where jiraTickets[key]?["done"] as? Bool == true {
			return ("\(key) is »\(jiraTickets[key]?["status"] as? String ?? "Done")«", false)
		}
		for branch in facts["branches"] as? [[String: Any]] ?? [] {
			if let name = branch["name"] as? String, let base = (branch["mergedInto"] as? [String])?.first {
				return ("`\(name)` is merged into `\(base)`", false)
			}
		}
		if let name = (facts["unknownBranches"] as? [String])?.first { return ("the branch `\(name)` is gone", false) }
		if facts["openSteps"] as? Int == 0, facts["doneSteps"] as? Int ?? 0 > 0 { return ("all its steps are done", false) }
		return nil
	}

	/// The outdated files at the last run that wrote an overview, by their URL.
	struct OutdatedState: Equatable {
		var outdated: Set<String> = []
		/// The files that Claude checked, but that no task of the written overview names, e.g. the plans of another
		/// project. They need no new check until they change.
		var ignored: Set<String> = []
		/// The names of all plans and project files, or `nil` in the file of an older version of the app.
		var names: Set<String>? = nil
	}

	/// The result of the outdated check of one run, for the ``OutdatedState`` after the run.
	struct OutdatedRun: Equatable {
		var outdated: Set<String> = []
		/// The ignored files of the last run that stay ignored.
		var ignored: Set<String> = []
		/// The files that Claude checks in this run.
		var checked: [(url: String, name: String)] = []
		/// The names of all plans and project files of this run.
		var names: Set<String>? = nil

		static func == (lhs: OutdatedRun, rhs: OutdatedRun) -> Bool {
			lhs.outdated == rhs.outdated && lhs.ignored == rhs.ignored && lhs.checked.map(\.url) == rhs.checked.map(\.url) && lhs.names == rhs.names
		}

		/// The state after the run that wrote `written`.
		func state(written: String) -> OutdatedState {
			OutdatedState(outdated: outdated, ignored: ignored.union(checked.filter { !MorningOverview.names(written, url: $0.url, name: $0.name) }.map(\.url)),
				names: names)
		}
	}

	/// The file facts for the run, after the outdated check of »Cleanup Work«. Each outdated file
	/// (``outdatedReason(of:jiraTickets:closedStates:)``) gets the reason in `outdated`. Then:
	/// - A file of a declined pull request gets `appTask: true` and a ``DeleteTask`` in each run. Its code never reached
	///   the base branch, so Claude does not read it.
	/// - An open task in »Cleanup Work« of `old` that names the file means that the file is checked.
	/// - An open task in another section of Claude names the file: the file is checked when it did not change and got no
	///   new commits, and when it was outdated at the last run (`last`, each file without it).
	/// - A file in `ignored` of `last` that did not change is checked too.
	/// - Each other file gets `checkFindings: true`, so that Claude checks its findings. In one run, only the
	///   ``checkLimit`` newest of these files get it. The others wait for the next run, and they are not in `outdated`.
	/// The fields in ``outdatedCheckFields`` go away.
	static func withOutdatedCheck(_ files: [[String: Any]], old: String?, last: OutdatedState?, jiraTickets: [String: [String: Any]],
		closedStates: [Int: String]) -> (files: [[String: Any]], run: OutdatedRun, deleteTasks: [DeleteTask]) {
		let cleanupTasks = openTasks(in: old) { $0 == cleanupSection }
		let otherTasks = openTasks(in: old) { $0 != cleanupSection }
		var result = files.map { $0.filter { !outdatedCheckFields.contains($0.key) } }
		var run = OutdatedRun()
		var deleteTasks: [DeleteTask] = []
		var waiting: [(index: Int, url: String, name: String, changedOn: String)] = []
		for (index, facts) in files.enumerated() {
			guard let url = facts["url"] as? String, let name = facts["name"] as? String,
				let reason = outdatedReason(of: facts, jiraTickets: jiraTickets, closedStates: closedStates) else { continue }
			if reason.declined {
				result[index]["appTask"] = true
				deleteTasks.append(DeleteTask(url: url, line: "- [ ] Delete [\(name)](\(url)), because \(reason.text)."))
				run.outdated.insert(url)
				continue
			}
			result[index]["outdated"] = reason.text
			let isNamed = { (task: String) in names(task, url: url, name: name) }
			let isChanged = facts["changedAfterOldOverview"] as? Bool == true || facts["newCommits"] as? Bool == true
			if !isChanged, last?.ignored.contains(url) == true {
				run.ignored.insert(url)
				run.outdated.insert(url)
			} else if cleanupTasks.contains(where: isNamed)
				|| (last?.outdated.contains(url) ?? true) && !isChanged && otherTasks.contains(where: isNamed) {
				run.outdated.insert(url)
			} else {
				waiting.append((index, url, name, facts["changedOn"] as? String ?? ""))
			}
		}
		let newestFirst = waiting.sorted { $0.changedOn == $1.changedOn ? $0.index < $1.index : $0.changedOn > $1.changedOn }
		for file in newestFirst.prefix(checkLimit) {
			result[file.index]["checkFindings"] = true
			run.outdated.insert(file.url)
			run.checked.append((file.url, file.name))
		}
		return (result, run, deleteTasks)
	}

	/// `run` after a run without all facts of Jira or Bitbucket. A file can then seem not outdated, so it keeps its state of
	/// `last`. This applies only to a file of `files` that got no reason now and did not change. A changed file needs its
	/// check in a later run.
	static func withLastState(_ run: OutdatedRun, files: [[String: Any]], last: OutdatedState) -> OutdatedRun {
		let urls = Set(files.filter { file in
			file["outdated"] == nil && file["appTask"] == nil && file["changedAfterOldOverview"] as? Bool != true
				&& file["newCommits"] as? Bool != true
		}.compactMap { $0["url"] as? String })
		var run = run
		run.outdated.formUnion(last.outdated.intersection(urls))
		run.ignored.formUnion(last.ignored.intersection(urls))
		return run
	}

	/// The text of each open task of `old` in the sections of Claude whose title passes `isIncluded`: its title line and
	/// its sub-items without a tick. A ticked task, and a task whose sub-items with a checkbox are all ticked, do not count.
	private static func openTasks(in old: String?, where isIncluded: (String) -> Bool) -> [String] {
		guard let old else { return [] }
		return withoutAppSections(old).components(separatedBy: "\n## ").dropFirst().filter { isIncluded(title(of: $0)) }.flatMap { part in
			let lines = part.components(separatedBy: "\n")
			return taskBlocks(in: part).compactMap { block -> String? in
				let boxes = lines[block].dropFirst().filter { $0.range(of: #"^\s*- \[[^\]]\] "#, options: .regularExpression) != nil }
				guard !isTicked(lines[block.lowerBound]), boxes.isEmpty || !boxes.allSatisfy(isTicked) else { return nil }
				return lines[block].filter { !isTicked($0) }.joined(separator: "\n")
			}
		}
	}

	/// The task text names the file: by a link to `url`, or by its name or a path to it in backticks.
	/// A ref of Claude that the app could not link counts too, e.g. `[name.md]` for 2 files with this name.
	static func names(_ text: String, url: String, name: String) -> Bool {
		text.contains("](\(url))") || ["`", "]"].contains { text.contains("`\(name)\($0)") || text.contains("[\(name)\($0)") || text.contains("/\(name)\($0)") }
	}

	/// The overview without each task of »Cleanup Work« that deletes a file that is gone, e.g. after the user deleted it
	/// without a tick. The task links the file with a `file://` URL. `exists` tells whether a path is still there.
	static func withoutDeleteTasksOfGoneFiles(in overview: String, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
		-> String {
		var parts = overview.components(separatedBy: "\n## ")
		guard let index = index(ofSection: cleanupSection, in: parts) else { return overview }
		parts[index] = parts[index].components(separatedBy: "\n").filter { line in
			guard line.hasPrefix("- "), line.contains("Delete ["),
				let path = firstGroup(of: #"\]\((file://[^)\s]+)\)"#, in: line).flatMap(URL.init(string:))?.path else { return true }
			return exists(path)
		}.joined(separator: "\n")
		return parts.joined(separator: "\n## ")
	}

	/// The overview with the line of each task of `tasks` in »Cleanup Work«, above its `###` subsections, unless a line of
	/// »Cleanup Work« already links the file of the task. Without »Cleanup Work«, the section comes at the end.
	static func withDeleteTasks(_ tasks: [DeleteTask], in overview: String) -> String {
		var parts = overview.components(separatedBy: "\n## ")
		let cleanup = index(ofSection: cleanupSection, in: parts).map { parts[$0] } ?? ""
		let new = tasks.filter { !cleanup.contains("](\($0.url))") }.map(\.line)
		guard !new.isEmpty else { return overview }
		guard let index = index(ofSection: cleanupSection, in: parts) else {
			return withKeptTasks(new.map { KeptTask(section: cleanupSection, lines: [$0]) }, in: overview)
		}
		var lines = parts[index].components(separatedBy: "\n")
		let subsection = lines.firstIndex { $0.hasPrefix("### ") }
		if let last = taskBlocks(in: parts[index]).last(where: { $0.upperBound <= subsection ?? lines.count }) {
			lines.insert(contentsOf: new, at: last.upperBound)
		} else if let subsection {
			lines.insert(contentsOf: new + [""], at: subsection)
		} else {
			lines.removeAll { $0 == "Nothing open." }
			while lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
			lines += [""] + new + [""]
		}
		parts[index] = lines.joined(separator: "\n")
		return parts.joined(separator: "\n## ")
	}

	/// The overview without the code blocks of »Cleanup Work«, each with the empty line above it. A block without an end
	/// stops before the next empty line or heading.
	static func withoutDeleteCommands(in overview: String) -> String {
		var parts = overview.components(separatedBy: "\n## ")
		guard let index = index(ofSection: cleanupSection, in: parts) else { return overview }
		var lines: [String] = []
		var isInBlock = false
		for line in parts[index].components(separatedBy: "\n") {
			if line.hasPrefix("```") {
				if !isInBlock, lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
				isInBlock.toggle()
				continue
			}
			if isInBlock, line.isEmpty || line.hasPrefix("#") { isInBlock = false }
			if !isInBlock { lines.append(line) }
		}
		parts[index] = lines.joined(separator: "\n")
		return parts.joined(separator: "\n## ")
	}

	/// The overview with a code block below the tasks of each branch subsection of »Cleanup Work«. The block has one shell
	/// command that deletes the branches of all open tasks of the subsection. Old blocks go away first.
	static func withDeleteCommands(in overview: String) -> String {
		var parts = withoutDeleteCommands(in: overview).components(separatedBy: "\n## ")
		guard let index = index(ofSection: cleanupSection, in: parts) else { return overview }
		var lines = parts[index].components(separatedBy: "\n")
		for heading in lines.indices.reversed() where lines[heading].hasPrefix("### ") {
			let end = lines[(heading + 1)...].firstIndex { $0.hasPrefix("### ") } ?? lines.count
			let title = lines[heading].dropFirst(4).lowercased().replacingOccurrences(of: " and ", with: " & ")
			let tasks = lines[heading..<end].filter { $0.hasPrefix("- [ ] ") }.compactMap(taskKey)
			guard let command = deleteCommand(subsection: title, tasks: tasks),
				let last = lines[heading..<end].lastIndex(where: { !$0.isEmpty }) else { continue }
			lines.insert(contentsOf: ["", "```sh", command, "```"], at: last + 1)
		}
		parts[index] = lines.joined(separator: "\n")
		return parts.joined(separator: "\n## ")
	}

	/// The shell command that deletes the branches of `tasks`, the task texts of the branch subsection `subsection` of
	/// »Cleanup Work«, or `nil` for another subsection or without a branch. `-D` also deletes a branch that git does not
	/// see as merged, e.g. after a squash merge.
	static func deleteCommand(subsection: String, tasks: [String]) -> String? {
		var local: [String] = []
		// The branch names on each remote, in the order of the tasks.
		var remote: [(name: String, branches: [String])] = []
		func addUpstream(_ upstream: String) {
			let pieces = upstream.split(separator: "/", maxSplits: 1).map(String.init)
			guard pieces.count == 2 else { return }
			if let index = remote.firstIndex(where: { $0.name == pieces[0] }) {
				remote[index].branches.append(pieces[1])
			} else {
				remote.append((pieces[0], [pieces[1]]))
			}
		}
		for task in tasks {
			guard let first = firstGroup(of: "^Delete `([^`]+)`", in: task) else { continue }
			switch subsection {
			case "local & remote":
				local.append(first)
				if let upstream = firstGroup(of: "^Delete `[^`]+` and `([^`]+)`", in: task) { addUpstream(upstream) }
			case "local": local.append(first)
			case "remote": addUpstream(first)
			default: return nil
			}
		}
		let commands = (local.isEmpty ? [] : ["git branch -D " + local.map(shellQuoted).joined(separator: " ")])
			+ remote.map { "git push \(shellQuoted($0.name)) --delete " + $0.branches.map(shellQuoted).joined(separator: " ") }
		return commands.isEmpty ? nil : commands.joined(separator: " && ")
	}

	/// The text as one word of a shell command, with quotes if it needs them.
	private static func shellQuoted(_ text: String) -> String {
		guard text.range(of: "^[A-Za-z0-9._/+-]+$", options: .regularExpression) == nil else { return text }
		return "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
	}

	/// The file with the ``OutdatedState`` of the last run that wrote an overview.
	@MainActor
	private static func outdatedFile(_ report: Report) -> URL { report.supportFolder.appendingPathComponent("outdated-files.json") }

	/// The ``OutdatedState`` of the last run that wrote an overview, or `nil` before the first such run.
	@MainActor
	static func lastOutdated(_ report: Report) -> OutdatedState? {
		guard let data = try? Data(contentsOf: outdatedFile(report)),
			let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] else { return nil }
		return OutdatedState(outdated: Set(object["outdated"] ?? []), ignored: Set(object["ignored"] ?? []), names: object["names"].map(Set.init))
	}

	/// Saves `state` for the next run.
	@MainActor
	static func saveOutdated(_ state: OutdatedState, _ report: Report) {
		var object = ["outdated": state.outdated.sorted(), "ignored": state.ignored.sorted()]
		if let names = state.names { object["names"] = names.sorted() }
		guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
		try? FileManager.default.createDirectory(at: report.supportFolder, withIntermediateDirectories: true)
		try? data.write(to: outdatedFile(report), options: .atomic)
	}

	// MARK: - File texts

	/// The most bytes of the text of one file in the JSON.
	static let fileTextLimit = 50_000
	/// The most bytes of the texts of all files in the JSON.
	static let fileTextsLimit = 150_000

	/// `files` with the `text` of each file that the rules make Claude read, so that Claude needs no read for it:
	/// - a file with `checkFindings`, first,
	/// - a file that changed or got new commits, and each file without an old overview,
	/// - a file that an open old task names, if `unchangedTasks` does not have the task, e.g. a task of a PR.
	/// The first `planCount` files are plans. A changed plan counts only with `recent`. No file with `appTask`, or with
	/// `outdated` and no `checkFindings`, counts. The newest files come first. A text longer than ``fileTextLimit`` stops at
	/// a line end and gets `textCut: true`. A text that does not fit into ``fileTextsLimit`` with the texts before it gets
	/// no text.
	static func withTexts(_ files: [[String: Any]], planCount: Int = 0, old: String?, unchangedTasks: [String],
		read: (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) }) -> [[String: Any]] {
		let unchanged = Set(unchangedTasks)
		let oldTasks = openTaskBlocks(in: old).filter { !unchanged.contains($0.id) }.map(\.text)
		var chosen: [(index: Int, rank: Int, changedOn: String)] = []
		for (index, file) in files.enumerated() {
			guard let url = file["url"] as? String, let name = file["name"] as? String, file["appTask"] as? Bool != true else { continue }
			let checks = file["checkFindings"] as? Bool == true
			guard checks || file["outdated"] == nil else { continue }
			// Section 5 reads only the recent plans, but an old task can name a plan of any age.
			let isChanged = old == nil || file["changedAfterOldOverview"] as? Bool == true || file["newCommits"] as? Bool == true
			let isRead = isChanged && (index >= planCount || file["recent"] as? Bool == true)
			guard checks || isRead || oldTasks.contains(where: { names($0, url: url, name: name) }) else { continue }
			chosen.append((index, checks ? 0 : 1, file["changedOn"] as? String ?? ""))
		}
		var result = files
		var total = 0
		for file in chosen.sorted(by: { ($0.rank, $1.changedOn, $0.index) < ($1.rank, $0.changedOn, $1.index) }) {
			guard let url = (files[file.index]["url"] as? String).flatMap(URL.init(string:)), let text = read(url) else { continue }
			let cut = text.utf8.count > fileTextLimit
			var kept = cut ? String(decoding: text.utf8.prefix(fileTextLimit), as: UTF8.self) : text
			if cut, let end = kept.lastIndex(of: "\n") { kept = String(kept[...end]) }
			// A text that does not fit stays out, but a shorter text after it can still fit.
			guard total + kept.utf8.count <= fileTextsLimit else { continue }
			result[file.index]["text"] = kept
			if cut { result[file.index]["textCut"] = true }
			total += kept.utf8.count
		}
		return result
	}

	/// The ID and the text of each open task of `old` in the sections of Claude. A ticked task, and a task whose sub-items
	/// with a checkbox are all ticked, do not count.
	private static func openTaskBlocks(in old: String?) -> [(id: String, text: String)] {
		guard let old else { return [] }
		return withoutAppSections(old).components(separatedBy: "\n## ").dropFirst().flatMap { part in
			let lines = part.components(separatedBy: "\n")
			return taskBlocks(in: part).compactMap { block -> (id: String, text: String)? in
				let boxes = lines[block].dropFirst().filter { $0.range(of: #"^\s*- \[[^\]]\] "#, options: .regularExpression) != nil }
				guard !isTicked(lines[block.lowerBound]), boxes.isEmpty || !boxes.allSatisfy(isTicked),
					let id = firstGroup(of: #"^- \[[^\]]\] `([A-Z]\d+)`"#, in: lines[block.lowerBound]) else { return nil }
				return (id, lines[block].filter { !isTicked($0) }.joined(separator: "\n"))
			}
		}
	}

	// MARK: - Links

	/// The key of the ``Links`` in `appData`.
	static let linksKey = "links"

	/// The facts that turn the short refs of Claude into links: `[#1234]`, `[PROJ-123]` and `[name.md]`.
	struct Links {
		/// The URL of each open pull request.
		var pullRequests: [Int: String] = [:]
		/// `workspace/repo` on Bitbucket, for the URL of a pull request that is not open.
		var repository: String?
		var jiraBrowseURL: String?
		/// The project keys of Jira. A ref with another key, e.g. `[UTF-8]`, is no ticket.
		var projectKeys: Set<String> = []
		/// The URLs of the plans and the project files.
		var files: [String] = []
		/// The paths of the folders of `files`, for a ref with the path from such a folder, e.g. `[reviews/a.md]`.
		var folders: [String] = []
	}

	/// The URL of a pull request on Bitbucket.
	private static func htmlURL(of pullRequest: [String: Any]) -> String? {
		((pullRequest["links"] as? [String: Any])?["html"] as? [String: Any])?["href"] as? String
	}

	/// A short ref of Claude, not followed by a link target: a pull request, a ticket or a file.
	private static let refPattern = #"\[(?:#(\d+)|([A-Z][A-Z0-9]+-\d+)|([^\[\]()`\n]+?\.md))\](?!\()"#

	/// The overview with each short ref of Claude as a link. Code spans and links stay as they are.
	/// - `[#1234]` becomes the link of the pull request, with the number as code.
	/// - `[PROJ-123]` with a key of `links.projectKeys` becomes the link of the ticket, or the plain ID without the Jira site.
	/// - `[name.md]` or `[folder/name.md]` becomes the link of its file: the file with this path from a folder of `links`,
	///   else the one file whose path ends with it. Another ref of a file stays as it is.
	static func withLinks(_ links: Links, in overview: String) -> String {
		var parts = overview.components(separatedBy: "\n## ")
		for index in parts.indices.dropFirst() {
			parts[index] = parts[index].components(separatedBy: "\n").map { linked($0, links) }.joined(separator: "\n")
		}
		return parts.joined(separator: "\n## ")
	}

	/// The line with its refs as links, outside code spans.
	private static func linked(_ line: String, _ links: Links) -> String {
		guard line.contains("[") else { return line }
		var segments = line.components(separatedBy: "`")
		for index in stride(from: 0, to: segments.count, by: 2) { segments[index] = linkedText(segments[index], links) }
		return segments.joined(separator: "`")
	}

	/// The text with its refs as links.
	private static func linkedText(_ text: String, _ links: Links) -> String {
		guard let regex = try? NSRegularExpression(pattern: refPattern) else { return text }
		let result = NSMutableString(string: text)
		// From the end, so that each range of a match before the change stays right.
		for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
			let group = { (number: Int) in Range(match.range(at: number), in: text).map { String(text[$0]) } }
			var replacement: String?
			if let number = group(1), let id = Int(number) {
				let url = links.pullRequests[id] ?? links.repository.map { "https://bitbucket.org/\($0)/pull-requests/\(id)" }
				// The same form as the old overview, so that the tasks of the user find their task again.
				replacement = url.map { "[`#\(id)`](\($0))" }
			} else if let ticket = group(2), links.projectKeys.contains(projectKey(of: ticket)) {
				replacement = links.jiraBrowseURL.map { "[\(ticket)](\($0)\(ticket))" } ?? ticket
			} else if let file = group(3) {
				replacement = fileURL(of: file, in: links).map { "[\(file)](\($0))" }
			}
			if let replacement { result.replaceCharacters(in: match.range, with: replacement) }
		}
		return result as String
	}

	/// The URL of the file of the ref `file`: the file with this path from a folder of `links`, else the one file whose
	/// path ends with it.
	private static func fileURL(of file: String, in links: Links) -> String? {
		let paths = links.files.map { (url: $0, path: URL(string: $0)?.path ?? "") }
		if let exact = paths.first(where: { path in links.folders.contains { path.path == $0 + "/" + file } }) { return exact.url }
		let found = paths.filter { $0.path.hasSuffix("/" + file) }
		return found.count == 1 ? found[0].url : nil
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
	/// of the pull request. A report is a file directly in `reviewsFolder` whose name starts with the number of the pull
	/// request, e.g. `4341-fix.md` (``reviewedPullRequest(of:in:)``). Its reviewed commit is the first hash after »reviewed commit« or »reviewed at«
	/// in its text, else the hash at the end of its name, e.g. `4341-fix-6e460fc.md`. A report without a commit does not
	/// count. A pull request that `me` approved needs no new review.
	static func newReviews(in files: [URL], reviewsFolder: URL?, pullRequests: [[String: Any]], me: String) -> [NewReview] {
		var reports: [Int: [(date: Date, commit: String)]] = [:]
		for file in files {
			let name = file.deletingPathExtension().lastPathComponent
			guard let id = reviewedPullRequest(of: file, in: reviewsFolder), let date = file.modificationDate else { continue }
			let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
			guard let commit = reviewedCommit(in: text) ?? matches(of: #"(?<=-)(?=[0-9a-f]*\d)[0-9a-f]{7,40}$"#, in: name).first else { continue }
			reports[id, default: []].append((date, commit))
		}
		return pullRequests.compactMap { pullRequest in
			guard let id = pullRequest["id"] as? Int, let reports = reports[id], let head = heads(of: [pullRequest])[id],
				!isApproved(pullRequest, by: me),
				!reports.contains(where: { head.hasPrefix($0.commit) || $0.commit.hasPrefix(head) }),
				let newest = reports.max(by: { $0.date < $1.date }) else { return nil }
			let section = !Bitbucket.isAuthor(of: pullRequest, me: me) ? "Their Open PRs" : pullRequest["draft"] as? Bool == true ? "Draft PRs" : "My Open PRs"
			return NewReview(id: id, reviewedCommit: newest.commit,
				url: ((pullRequest["links"] as? [String: Any])?["html"] as? [String: Any])?["href"] as? String ?? "",
				title: pullRequest["title"] as? String ?? "", section: section, hasMergeConflict: pullRequest["hasMergeConflict"] as? Bool == true,
				destination: ((pullRequest["destination"] as? [String: Any])?["branch"] as? [String: Any])?["name"] as? String ?? "")
		}
	}

	/// The most pages of commits that the app reads of a pull request, with 100 commits each.
	static let commitPages = 3

	/// `reviews` without the pull requests of the user where each commit after the reviewed commit is from another person:
	/// the user does not review the commits of others on the user's own pull request. A pull request of another author
	/// stays, and so does one whose commits Bitbucket does not give.
	static func withoutCommitsOfOthers(_ reviews: [NewReview], _ bitbucket: Bitbucket, me: String) async -> [NewReview] {
		var result: [NewReview] = []
		for review in reviews {
			if review.section != "Their Open PRs",
				let commits = try? await bitbucket.values("/pullrequests/\(review.id)/commits", query: ["pagelen": "100"],
					fields: ["hash", "author.raw", "author.user.display_name"], maxPages: commitPages),
				!commits.isEmpty, !hasCommit(of: me, after: review.reviewedCommit, in: commits) { continue }
			result.append(review)
		}
		return result
	}

	/// A commit of `me` is in `commits` before the commit `reviewed`. The commits come with the newest first, as Bitbucket
	/// gives them. Without `reviewed` in `commits`, e.g. after a rebase, each commit counts. The author of a commit is
	/// `me` by the name in the commit or by the display name of the Bitbucket user.
	static func hasCommit(of me: String, after reviewed: String, in commits: [[String: Any]]) -> Bool {
		commits.prefix { ($0["hash"] as? String)?.hasPrefix(reviewed) != true }.contains { commit in
			let author = commit["author"] as? [String: Any]
			let name = (author?["raw"] as? String).map { $0.prefix { $0 != "<" }.trimmingCharacters(in: .whitespaces) }
			return name == me || (author?["user"] as? [String: Any])?["display_name"] as? String == me
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
	/// gets a new task in its section. This next action of a pull request that is not in `reviews` goes away with its
	/// sub-items, e.g. a copy from the old overview.
	static func withNewReviewTasks(_ reviews: [NewReview], jiraBrowseURL: String?, in overview: String) -> String {
		let ids = Set(reviews.map(\.id))
		// The indent of a removed next action, while its sub-items follow.
		var removedIndent: Int?
		let overview = overview.components(separatedBy: "\n").filter { line in
			if let removed = removedIndent, indent(of: line) > removed, !line.trimmingCharacters(in: .whitespaces).isEmpty { return false }
			removedIndent = nil
			guard let key = taskKey(of: line), let id = firstGroup(of: #"^Run `/nn-review #(\d+)` again, because the PR has new commits"#, in: key),
				let number = Int(id), !ids.contains(number) else { return true }
			removedIndent = indent(of: line)
			return false
		}.joined(separator: "\n")
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

	/// The sections where Claude can write `KEEP <ID>` for a task with unchanged files.
	static let keepSections = ["Remaining Tickets in this Sprint", "Open Branches", "Optional Work", cleanupSection]
	/// The sections of the pull requests. Claude can write `KEEP <ID>` for a task whose pull request did not change.
	static let pullRequestSections = turnSections + ["Draft PRs"]
	/// The sections where a task without files can be unchanged, by the branches, worktrees and sessions that it names.
	/// »Cleanup Work« has its own KEEP rules in the prompt.
	static let namedSections = ["Open Branches", "Optional Work"]

	/// The IDs of the old tasks in ``keepSections`` whose plans and reports did not change and got no new commits:
	/// - The task names at least one file of `files`, by a `file://` link or by a path in backticks that ends in `.md`.
	/// - Each named file has `changedAfterOldOverview` and `newCommits` false, and no `checkFindings` or `appTask`. A file
	///   that `files` does not have counts as changed, and so does a file of `files` whose name the task text has and that
	///   changed.
	/// - No pull request of the title line is in `changedPullRequests` or in `closedPullRequests`.
	/// - A task of ``namedSections`` without files needs `named`: it names branches, worktrees, pull requests or sessions,
	///   and none of them changed (``NamedFacts/isUnchanged(_:)``).
	/// The IDs of the old tasks in ``pullRequestSections`` whose pull request did not change, too:
	/// - The first pull request of the title line is in `unchangedPullRequests`. So is each other pull request of
	///   `openPullRequests` that the task names, and the task names none of `closedPullRequests`.
	/// - Each file that the task names did not change. A PR task needs no file. A `.md` path in backticks does not count
	///   when its name is no file of `files`, was none at the last written run (`lastNames`), and is not in `localNames`,
	///   e.g. a name from a comment of the PR. Without `lastNames`, such a path counts as changed.
	/// - With `tickets`, no ticket of the title line is done, and the 🚫 of the title line is still right: a ticket of the
	///   title line is blocked, or a pull request of the title line is in `blockedPullRequests`. A done ticket does not
	///   count when each named file has `outdated` and no `checkFindings`, because the outdated check already knows it.
	/// A ticked task does not count.
	static func unchangedTasks(in old: String, files: [[String: Any]], changedPullRequests: Set<Int>, tickets: [String: [String: Any]]? = nil,
		blockedPullRequests: Set<Int> = [], closedPullRequests: Set<Int> = [], unchangedPullRequests: Set<Int> = [],
		openPullRequests: Set<Int> = [], lastNames: Set<String>? = nil, localNames: Set<String> = [], named: NamedFacts? = nil) -> [String] {
		// A file that the outdated check gives to Claude or to the app counts as changed.
		let isUnchanged = { (file: [String: Any]) in
			file["changedAfterOldOverview"] as? Bool == false && file["newCommits"] as? Bool == false
				&& file["checkFindings"] as? Bool != true && file["appTask"] as? Bool != true
		}
		var byPath: [String: Bool] = [:]
		var byName: [String: Bool] = [:]
		var settledPaths: Set<String> = []
		var settledNames: Set<String> = []
		for file in files {
			guard let url = (file["url"] as? String).flatMap(URL.init(string:)) else { continue }
			byPath[url.path] = (byPath[url.path] ?? true) && isUnchanged(file)
			byName[url.lastPathComponent] = (byName[url.lastPathComponent] ?? true) && isUnchanged(file)
			if file["outdated"] is String, file["checkFindings"] as? Bool != true {
				settledPaths.insert(url.path)
				settledNames.insert(url.lastPathComponent)
			}
		}
		let changedNames = byName.filter { !$0.value }.keys
		return old.components(separatedBy: "\n## ").dropFirst().filter { (keepSections + pullRequestSections).contains(title(of: $0)) }.flatMap { part in
			let lines = part.components(separatedBy: "\n")
			let isPullRequestSection = pullRequestSections.contains(title(of: part))
			let isNamedSection = namedSections.contains(title(of: part))
			return taskBlocks(in: part).compactMap { block -> String? in
				let title = lines[block.lowerBound]
				guard !isTicked(title), let id = firstGroup(of: #"^- \[[^\]]\] `([A-Z]\d+)`"#, in: title) else { return nil }
				let text = lines[block].joined(separator: "\n")
				let links = matches(of: #"(?<=\]\()file://[^)\s]+(?=\))"#, in: text).compactMap { URL(string: $0)?.path }
				let codePaths = matches(of: #"(?<=`)[^`\s]+\.md(?=`)"#, in: text).map { ($0 as NSString).lastPathComponent }.filter { name in
					!isPullRequestSection || byName[name] != nil || localNames.contains(name) || lastNames.map { $0.contains(name) } ?? true
				}
				let pullRequests = matches(of: #"(?<=#)\d+(?=`?\]\()"#, in: title).compactMap { Int($0) }
				guard links.allSatisfy({ byPath[$0] == true }), codePaths.allSatisfy({ byName[$0] == true }), !changedNames.contains(where: text.contains),
					!pullRequests.contains(where: closedPullRequests.contains) else { return nil }
				if isPullRequestSection {
					// A number of no pull request, e.g. in »finding #2«, does not count.
					let named = Set(matches(of: #"(?<=#)\d+\b"#, in: text).compactMap { Int($0) })
					// The user did all next actions, which Bitbucket cannot show. The PR is still open, so its task needs new ones.
					let boxes = lines[block].dropFirst().filter { $0.range(of: #"^\s*- \[[^\]]\] "#, options: .regularExpression) != nil }
					guard let first = pullRequests.first, unchangedPullRequests.contains(first),
						named.intersection(openPullRequests).isSubset(of: unchangedPullRequests), named.isDisjoint(with: closedPullRequests),
						boxes.isEmpty || !boxes.allSatisfy(isTicked) else { return nil }
				} else if links.isEmpty && codePaths.isEmpty {
					guard isNamedSection, let named, named.isUnchanged(text) else { return nil }
				} else {
					guard pullRequests.allSatisfy({ !changedPullRequests.contains($0) }) else { return nil }
				}
				if let tickets {
					let keys = matches(of: #"(?<=\[)[A-Z][A-Z0-9]+-\d+(?=\]\()"#, in: title)
					// A task without files, e.g. of a PR, has no outdated check that knows the ticket.
					let isSettled = !(links.isEmpty && codePaths.isEmpty) && links.allSatisfy(settledPaths.contains)
						&& codePaths.allSatisfy(settledNames.contains)
					guard isSettled || !keys.contains(where: { tickets[$0]?["done"] as? Bool == true }) else { return nil }
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
	/// The key in the Jira data that marks the tickets as incomplete: some tickets of the texts have no facts.
	static let ticketsIncompleteKey = "ticketsIncomplete"

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
			let others = try? await jira.tickets(Array(keys.prefix(ticketLimit)))
			data["browseURL"] = jira.browseURL
			data["sprint"] = sprint.compactMap { $0["key"] as? String }
			data["forgotten"] = forgotten.compactMap { $0["key"] as? String }
			data["tickets"] = Dictionary((found + (others ?? [])).compactMap(Jira.facts), uniquingKeysWith: { first, _ in first })
			// The request failed, or the limit left out tickets.
			if others == nil || keys.count > ticketLimit { data[ticketsIncompleteKey] = true }
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

	/// The most comments of a pull request that the app reads, for the threads of the tasks. 100 come on each page.
	static let commentPages = 2
	/// The most tasks of a pull request that the app reads, in all states. 100 come on each page.
	static let taskPages = 3
	/// The number of the newest comments that the app keeps of a pull request.
	static let newestCommentCount = 10

	/// The open tasks, newest comments, newest build states and merge conflict of a pull request. The four requests run at
	/// the same time. `commentsWithoutTasks` holds the newest comments outside the threads of the tasks, for
	/// ``withoutTasks(_:)``.
	private static func details(_ bitbucket: Bitbucket, id: Int) async throws -> Details {
		// All states, because the comment of a resolved task is no next action either.
		async let tasks = bitbucket.values("/pullrequests/\(id)/tasks", query: ["pagelen": "100"],
			fields: ["content.raw", "creator.display_name", "comment.id", "state"], maxPages: taskPages)
		async let comments = bitbucket.values("/pullrequests/\(id)/comments", query: ["sort": "-created_on", "pagelen": "100"],
			fields: ["id", "parent.id", "content.raw", "user.display_name", "user.type", "created_on", "inline.path", "deleted"],
			maxPages: commentPages)
		async let statuses = bitbucket.values("/pullrequests/\(id)/statuses", query: ["sort": "-updated_on", "pagelen": "5"],
			fields: ["state", "name", "updated_on"], maxPages: 1)
		async let mergeConflict = hasMergeConflict(bitbucket, id: id)
		let (allTasks, allComments) = try await (tasks, comments)
		let threads = taskThreads(of: allTasks, in: allComments)
		let visible = allComments.filter { $0["deleted"] as? Bool != true }
		let shortened = { (items: [[String: Any]]) in
			items.prefix(newestCommentCount).map { Bitbucket.shortened($0).filter { $0.key != "id" && $0.key != "parent" } }
		}
		return try await Details(values: [
			"openTasks": allTasks.filter { $0["state"] as? String == "UNRESOLVED" }
				.map { Bitbucket.shortened($0).filter { $0.key != "comment" && $0.key != "state" } },
			"newestComments": shortened(visible),
			"commentsWithoutTasks": shortened(visible.filter { commentID($0).map(threads.contains) != true }),
			"buildStatuses": statuses,
			"hasMergeConflict": mergeConflict,
		])
	}

	/// The ID of a comment, or of the `parent` or `comment` object of an item.
	private static func commentID(_ item: [String: Any]?) -> Int? { item?["id"] as? Int }

	/// The IDs of the comments of `tasks` in any state, and of all replies to them in `comments`, at any depth. A deleted
	/// comment links its replies too. A reply whose parent is not in `comments`, e.g. older than the comments that the app
	/// reads, is found only by its own parent chain.
	static func taskThreads(of tasks: [[String: Any]], in comments: [[String: Any]]) -> Set<Int> {
		var ids = Set(tasks.compactMap { commentID($0["comment"] as? [String: Any]) })
		let parents = Dictionary(comments.compactMap { comment in
			commentID(comment).flatMap { id in commentID(comment["parent"] as? [String: Any]).map { (id, $0) } }
		}, uniquingKeysWith: { first, _ in first })
		// The newest comments come first, so a reply comes before its parent. The search runs until it finds no more reply.
		while true {
			let replies = parents.filter { ids.contains($0.value) && !ids.contains($0.key) }.map(\.key)
			guard !replies.isEmpty else { return ids }
			ids.formUnion(replies)
		}
	}

	/// The pull request as Claude gets it: without its tasks, and without the comments of a task and the replies to
	/// them (``taskThreads(of:in:)``). The user sees them in the pull request, so no next action repeats them.
	/// `hasOpenTasks` tells whether a task is open. A pull request without details has no `hasOpenTasks`.
	static func withoutTasks(_ pullRequest: [String: Any]) -> [String: Any] {
		var pullRequest = pullRequest
		pullRequest["task_count"] = nil
		guard let tasks = pullRequest["openTasks"] as? [[String: Any]] else { return pullRequest }
		pullRequest["openTasks"] = nil
		pullRequest["hasOpenTasks"] = !tasks.isEmpty
		pullRequest["newestComments"] = pullRequest.removeValue(forKey: "commentsWithoutTasks") ?? []
		return pullRequest
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

	/// The user approved the pull request.
	static func isApproved(_ pullRequest: [String: Any], by me: String) -> Bool {
		participants(of: pullRequest).contains { userName(of: $0) == me && $0["approved"] as? Bool == true }
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
