import Foundation

extension Report.Kind {
	/// `morning-overview.md`: a short list of the open work of the user. The run reads the project, and the app adds the
	/// open pull requests and the state of the git workspaces.
	static let morningOverview = Report.Kind(
		title: "Morning Overview",
		fileName: "morning-overview.md",
		promptResource: "morning-overview-prompt",
		settingsKey: SettingsKey.updatesMorningOverview,
		schedule: Report.Schedule(weekdays: [2, 3, 4, 5, 6], hour: 6, menuTitle: "Every Weekday at 6:00"),
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
		var data: [String: Any] = ["me": me, "workspaces": await workspaces(report)]
		do {
			data["pullRequests"] = try await pullRequests(report.bitbucket(), me: me)
		} catch let error as URLError {
			// Without a network, the run of the day waits for the next try.
			throw Report.Failure("No connection to Bitbucket: \(error.localizedDescription)")
		} catch {
			data["pullRequestError"] = "\(error)"
		}
		return Report.Input(data: data, facts: facts(report))
	}

	@MainActor
	private static func facts(_ report: Report) -> [String] {
		let system = report.system
		let projectFolder = claudeProjectFolder(of: system.folder.path)
		let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
		var facts = ["Project folder: \(system.folder.path)"]
		if exists(report.fileURL) { facts.append("Old overview: \(report.fileURL.path)") }
		if !system.dailyTasks.isEmpty {
			facts.append("Daily tasks: \(system.dailyTasks.joined(separator: ", ")). The app puts them at the top. Leave them out, and also the tickets that they cover.")
		}
		let memory = projectFolder.appendingPathComponent("memory")
		if exists(memory) { facts.append("Memory folder: \(memory.path)") }
		if exists(plansFolder) { facts.append("Plans folder: \(plansFolder.path)") }
		if exists(projectFolder) { facts.append("Transcripts folder: \(projectFolder.path)") }
		return facts
	}

	/// The overview in the output, with the daily tasks.
	@MainActor
	static func render(_ report: Report, _ result: Report.CommandResult, _ input: Report.Input, _ old: String?) throws -> String {
		guard let text = overview(in: result.output) else {
			let reason = (result.error + result.output).split(separator: "\n").last.map(String.init) ?? "no output"
			throw Report.Failure("Claude gave no overview: \(reason)")
		}
		return withDailyTasks(report.system.dailyTasks, in: text)
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

	/// The overview with the daily tasks above its first section.
	static func withDailyTasks(_ tasks: [String], in overview: String) -> String {
		guard !tasks.isEmpty, let section = overview.range(of: "\n## ") else { return overview }
		let lines = tasks.map { "- [ ] \($0)\n" }.joined()
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

	/// The open pull requests. The ones of the user, as author or reviewer, also get their open tasks, newest comments and
	/// newest build states.
	private static func pullRequests(_ bitbucket: Bitbucket, me: String) async throws -> [[String: Any]] {
		let fields = ["id", "title", "draft", "author.display_name", "participants.role", "participants.approved", "participants.state",
			"participants.user.display_name", "links.html.href", "comment_count", "task_count", "updated_on", "source.branch.name"]
		var pullRequests = try await bitbucket.values("/pullrequests", query: ["state": "OPEN", "pagelen": "50"], fields: fields)
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
				pullRequests[index]["waitsForMyReview"] = waitsForReview(pullRequests[index], me: me)
			} catch {
				pullRequests[index]["detailError"] = "\(error)"
			}
		}
		return pullRequests
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
}
