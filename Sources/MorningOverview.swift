import AppKit
import Foundation
import os
import UserNotifications

/// Writes `morning-overview.md`: a short list of the open work of the user. A headless Claude Code run that can only
/// read makes the text. The app fetches the pull requests with GET requests, collects the state of the git workspaces,
/// and writes the output of the run to the file. The app never stages the file.
@MainActor
final class MorningOverview: ObservableObject {
	static let shared = MorningOverview(system: .live)
	static let fileName = "morning-overview.md"
	/// From this hour on, ``runIfDue()`` starts the run of the day.
	static let dueHour = 6
	/// An automatic run that failed waits this long before the next try, so that each unlock does not start one.
	static let retryDelay: TimeInterval = 30 * 60
	static let timeout: TimeInterval = 15 * 60
	/// The notification of a ready file. A click on it opens the file.
	nonisolated static let readyNotificationID = "morning-overview"
	static let failedNotificationID = "morning-overview-failed"
	/// The read tools of the Atlassian MCP. The run gets no other MCP tool, so it cannot change a ticket.
	static let jiraReadTools = ["atlassianUserInfo", "getAccessibleAtlassianResources", "searchJiraIssuesUsingJql", "getJiraIssue"]
		.map { "mcp__com_atlassian_atlassian-mcp-server__\($0)" }
	/// The plans of Claude Code, for all projects.
	nonisolated static let plansFolder = claudeConfigDirectory.appendingPathComponent("plans")
	/// The most pull requests that get their tasks and comments fetched.
	static let detailLimit = 20

	struct Command {
		var executable: String
		var arguments: [String]
		var directory: URL
		var input = Data()
		var timeout: TimeInterval = 30
	}

	struct CommandResult {
		var status: Int32
		var output: String
		var error: String
		var timedOut = false
	}

	struct System {
		/// The project folder that gets the file.
		var folder: URL
		/// The tasks of every morning. They come first in the file.
		var dailyTasks: [String]
		var now: () -> Date
		var calendar: Calendar
		var defaults: UserDefaults
		/// The prompt from the app bundle.
		var prompt: () -> String?
		var run: (Command) async -> CommandResult
		/// A GET request. Returns the body and the HTTP status.
		var get: (URLRequest) async throws -> (Data, Int)
		var post: @MainActor (_ identifier: String, _ title: String, _ body: String) -> Void
		var removeNotifications: @MainActor ([String]) -> Void
		/// Opens a file in iA Writer, else in VS Code.
		var open: @MainActor (URL) -> Void

		static let live = System(
			folder: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("S/plano"),
			dailyTasks: ["Zeiterfassung"],
			now: Date.init,
			calendar: .current,
			defaults: .standard,
			prompt: {
				Bundle.main.url(forResource: "morning-overview-prompt", withExtension: "md")
					.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
			},
			run: MorningOverview.execute,
			get: { request in
				let (data, response) = try await URLSession.shared.data(for: request)
				return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
			},
			post: { identifier, title, body in
				SessionStore.shared.post(subtitle: "Morning overview", title: title, body: body, identifier: identifier)
			},
			removeNotifications: { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: $0) },
			open: { openDocument($0, preferring: ["pro.writer.mac", "com.microsoft.VSCode"]) }
		)
	}

	let system: System
	@Published private(set) var isRunning = false
	/// The reason why the last run failed, `nil` after a run that worked.
	@Published private(set) var failure: String?
	/// A new file waits to be opened. The menu marks it.
	@Published private(set) var isUnread = false
	private var lastAutomaticRun: Date?

	init(system: System) {
		self.system = system
	}

	var fileURL: URL { system.folder.appendingPathComponent(Self.fileName) }

	/// Starts the run of the day: on a weekday from ``dueHour`` on, when the file does not show today's date yet.
	func runIfDue() {
		let now = system.now()
		guard SettingsKey.isOn(SettingsKey.updatesMorningOverview, in: system.defaults), isDue(at: now) else { return }
		if let lastAutomaticRun, now.timeIntervalSince(lastAutomaticRun) < Self.retryDelay { return }
		lastAutomaticRun = now
		Task { await update() }
	}

	func isDue(at now: Date) -> Bool {
		let calendar = system.calendar
		let weekday = calendar.component(.weekday, from: now)
		guard !isRunning, weekday != 1, weekday != 7, calendar.component(.hour, from: now) >= Self.dueHour else { return false }
		let text = try? String(contentsOf: fileURL, encoding: .utf8)
		return text.flatMap(Self.updatedDay) != calendar.dateComponents([.year, .month, .day], from: now)
	}

	/// The day of the `Updated: YYYY-MM-DD HH:MM` line, or `nil` without one.
	nonisolated static func updatedDay(in text: String) -> DateComponents? {
		for line in text.split(separator: "\n").prefix(10) where line.hasPrefix("Updated: ") {
			let parts = line.dropFirst("Updated: ".count).prefix(10).split(separator: "-").compactMap { Int($0) }
			guard parts.count == 3 else { return nil }
			return DateComponents(year: parts[0], month: parts[1], day: parts[2])
		}
		return nil
	}

	/// Makes a new overview and writes it to the file.
	func update() async {
		guard !isRunning else { return }
		isRunning = true
		defer { isRunning = false }
		guard let prompt = system.prompt() else { return fail("The prompt is missing in the app.") }

		let me = await git(["config", "user.name"]).trimmingCharacters(in: .whitespacesAndNewlines)
		var data: [String: Any] = ["me": me, "workspaces": await workspaces()]
		do {
			data["pullRequests"] = try await pullRequests(me: me)
		} catch let error as URLError {
			// Without a network, the run of the day waits for the next try.
			return fail("No connection to Bitbucket: \(error.localizedDescription)")
		} catch {
			data["pullRequestError"] = "\(error)"
		}
		let input = (try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])) ?? Data()

		let result = await system.run(claudeCommand(prompt: prompt + facts(), input: input))
		if result.timedOut { return fail("Claude did not finish within \(Int(Self.timeout / 60)) minutes.") }
		guard let text = Self.overview(in: result.output).map({ Self.withDailyTasks(system.dailyTasks, in: $0) }) else {
			let reason = (result.error + result.output).split(separator: "\n").last.map(String.init) ?? "no output"
			return fail(result.status == 127 ? "The command »claude« was not found." : "Claude gave no overview: \(reason)")
		}
		do {
			try text.write(to: fileURL, atomically: true, encoding: .utf8)
		} catch {
			return fail("The file could not be written: \(error.localizedDescription)")
		}
		failure = nil
		isUnread = true
		system.removeNotifications([Self.failedNotificationID])
		if !system.defaults.bool(forKey: SettingsKey.muted) {
			let count = text.components(separatedBy: "\n- [ ]").count - 1
			system.post(Self.readyNotificationID, "Ready", "\(count) open tasks. Click to open the file.")
		}
	}

	/// The overview in the output of the run, or `nil` if the output is no overview. Text before the title and a Markdown
	/// fence around the overview do not count.
	nonisolated static func overview(in output: String) -> String? {
		guard let start = output.range(of: "(?m)^# Morning overview", options: .regularExpression) else { return nil }
		var lines = output[start.lowerBound...].components(separatedBy: "\n")
		while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty || last.hasPrefix("```") { lines.removeLast() }
		let text = lines.joined(separator: "\n")
		return updatedDay(in: text) == nil ? nil : text + "\n"
	}

	/// The overview with the daily tasks above its first section.
	nonisolated static func withDailyTasks(_ tasks: [String], in overview: String) -> String {
		guard !tasks.isEmpty, let section = overview.range(of: "\n## ") else { return overview }
		let lines = tasks.map { "- [ ] \($0)\n" }.joined()
		return overview.replacingCharacters(in: section, with: "\n" + lines + "\n## ")
	}

	/// Every failure gets a notification, also while the notifications are off. The macOS log keeps the reason.
	private func fail(_ reason: String) {
		failure = reason
		Self.log.error("Morning overview failed: \(reason, privacy: .public)")
		system.post(Self.failedNotificationID, "Update failed", reason)
	}

	private static let log = Logger(subsystem: "local.claude-code-notifier.app", category: "MorningOverview")

	/// Opens the file and removes the mark of a new file.
	func openFile() {
		isUnread = false
		system.open(fileURL)
	}

	// MARK: - The run

	/// A run with only the tools that read. `--restricted` ignores the settings files, so their allow rules do not
	/// apply. `dontAsk` refuses every call that is not on the allow list, without a prompt. The read rules cover only the
	/// project, its transcripts and the plans. Commands that Claude Code knows as read-only, e.g. `git status`, still run.
	func claudeCommand(prompt: String, input: Data) -> Command {
		let projectFolder = claudeProjectFolder(of: system.folder.path)
		// A leading `//` makes the path of a rule absolute. Each rule is its own argument, so a space in a path is safe.
		let readRules = [system.folder, projectFolder, Self.plansFolder].map { "Read(/\($0.path)/**)" }
		var arguments = ["-p", prompt, "--restricted", "--permission-mode", "dontAsk", "--tools", "Read,Grep,Glob,Bash",
			"--allowedTools"] + readRules + Self.jiraReadTools
		arguments += ["--add-dir", projectFolder.path, "--add-dir", Self.plansFolder.path, "--output-format", "text",
			"--no-session-persistence", "--strict-mcp-config"]
		let mcpConfig = try? Data(contentsOf: system.folder.appendingPathComponent(".mcp.json"))
		if let servers = mcpConfig.flatMap(Self.remoteServers) { arguments += ["--mcp-config", servers] }
		return loginShell(["claude"] + arguments, input: input, timeout: Self.timeout)
	}

	/// The servers of an MCP config that run remotely, as a config of their own. A local server would start a program,
	/// for example a new `npx` download, for each run. `nil` without a remote server.
	nonisolated static func remoteServers(in config: Data) -> String? {
		guard let root = try? JSONSerialization.jsonObject(with: config) as? [String: Any],
			let servers = root["mcpServers"] as? [String: [String: Any]] else { return nil }
		let remote = servers.filter { ["http", "sse"].contains($0.value["type"] as? String) }
		guard !remote.isEmpty, let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": remote], options: .sortedKeys) else {
			return nil
		}
		return String(decoding: data, as: UTF8.self)
	}

	/// The facts of this machine, below the prompt.
	private func facts() -> String {
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd HH:mm"
		let projectFolder = claudeProjectFolder(of: system.folder.path)
		var lines = ["", "## Facts", "", "- Now: \(formatter.string(from: system.now()))", "- Project folder: \(system.folder.path)"]
		if FileManager.default.fileExists(atPath: fileURL.path) { lines.append("- Old overview: \(fileURL.path)") }
		if !system.dailyTasks.isEmpty {
			lines.append("- Daily tasks: \(system.dailyTasks.joined(separator: ", ")). The app puts them at the top. Leave them out, and also the tickets that they cover.")
		}
		let memory = projectFolder.appendingPathComponent("memory")
		if FileManager.default.fileExists(atPath: memory.path) { lines.append("- Memory folder: \(memory.path)") }
		if FileManager.default.fileExists(atPath: Self.plansFolder.path) { lines.append("- Plans folder: \(Self.plansFolder.path)") }
		if FileManager.default.fileExists(atPath: projectFolder.path) { lines.append("- Transcripts folder: \(projectFolder.path)") }
		return lines.joined(separator: "\n") + "\n"
	}

	/// Runs a program through the login shell of the user, which sets `PATH` and the variables of the user's profile.
	private func loginShell(_ program: [String], input: Data = Data(), timeout: TimeInterval = 30) -> Command {
		let shell = getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) } ?? "/bin/zsh"
		// `exec` lets the program take the place of the shell, so a timeout ends the program itself.
		return Command(executable: shell, arguments: ["-lc", "exec \"$0\" \"$@\""] + program, directory: system.folder,
			input: input, timeout: timeout)
	}

	private func git(_ arguments: [String], in folder: URL? = nil) async -> String {
		let folder = folder ?? system.folder
		return await system.run(Command(executable: "/usr/bin/git", arguments: ["-C", folder.path] + arguments, directory: folder)).output
	}

	// MARK: - Git workspaces

	/// The main folder and each worktree, with uncommitted changes and commits that are on no remote.
	private func workspaces() async -> [[String: Any]] {
		var result: [[String: Any]] = []
		for entry in Self.worktrees(in: await git(["worktree", "list", "--porcelain"])) {
			let folder = URL(fileURLWithPath: entry.path)
			let changes = await git(["status", "--porcelain"], in: folder).split(separator: "\n").prefix(30).map(String.init)
			let commits = await git(["log", "--oneline", "-n", "20", "HEAD", "--not", "--remotes"], in: folder)
				.split(separator: "\n").map(String.init)
			result.append(["path": entry.path, "branch": entry.branch ?? "detached HEAD", "uncommittedChanges": changes,
				"commitsOnNoRemote": commits])
		}
		return result
	}

	/// The worktrees in the output of `git worktree list --porcelain`.
	nonisolated static func worktrees(in output: String) -> [(path: String, branch: String?)] {
		output.components(separatedBy: "\n\n").compactMap { block in
			let lines = block.split(separator: "\n")
			guard let path = lines.first(where: { $0.hasPrefix("worktree ") })?.dropFirst("worktree ".count) else { return nil }
			let branch = lines.first(where: { $0.hasPrefix("branch refs/heads/") })?.dropFirst("branch refs/heads/".count)
			return (String(path), branch.map(String.init))
		}
	}

	// MARK: - Pull requests

	enum FetchError: Error, CustomStringConvertible {
		case noBitbucketRemote, noCredentials, status(Int)

		var description: String {
			switch self {
			case .noBitbucketRemote: "The remote »origin« is not on Bitbucket."
			case .noCredentials: "BITBUCKET_API_EMAIL or BITBUCKET_API_TOKEN is not set in the login shell."
			case .status(let code): "Bitbucket answered with HTTP \(code)."
			}
		}
	}

	/// The open pull requests. The ones of the user, as author or reviewer, also get their open tasks, newest comments and
	/// newest build states.
	private func pullRequests(me: String) async throws -> [[String: Any]] {
		guard let repository = Self.bitbucketRepository(remote: await git(["remote", "get-url", "origin"])) else {
			throw FetchError.noBitbucketRemote
		}
		let script = "[ -n \"$BITBUCKET_API_EMAIL\" ] && [ -n \"$BITBUCKET_API_TOKEN\" ] && printf %s \"$BITBUCKET_API_EMAIL:$BITBUCKET_API_TOKEN\""
		let credentials = await system.run(loginShell(["/bin/sh", "-c", script])).output
		guard !credentials.isEmpty else { throw FetchError.noCredentials }
		let authorization = "Basic " + Data(credentials.utf8).base64EncodedString()
		let base = "https://api.bitbucket.org/2.0/repositories/\(repository)/pullrequests"

		func values(_ path: String, _ query: [String: String]) async throws -> [[String: Any]] {
			var components = URLComponents(string: base + path)!
			components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
			var request = URLRequest(url: components.url!)
			request.setValue(authorization, forHTTPHeaderField: "Authorization")
			let (data, status) = try await getWithRetry(request)
			guard status == 200 else { throw FetchError.status(status) }
			let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
			return json?["values"] as? [[String: Any]] ?? []
		}

		let fields = ["id", "title", "draft", "author.display_name", "participants.role", "participants.approved", "participants.state",
			"participants.user.display_name", "links.html.href", "comment_count", "task_count", "updated_on", "source.branch.name"]
		var pullRequests = try await values("", ["state": "OPEN", "pagelen": "50", "fields": fields.map { "values." + $0 }.joined(separator: ",")])
		for index in pullRequests.indices.filter({ Self.concerns(pullRequests[$0], me: me) }).prefix(Self.detailLimit) {
			guard let id = pullRequests[index]["id"] as? Int else { continue }
			// A failed detail request costs only the details of this pull request.
			do {
				let tasks = try await values("/\(id)/tasks", ["q": "state=\"UNRESOLVED\"", "pagelen": "50",
					"fields": "values.content.raw,values.creator.display_name"])
				let comments = try await values("/\(id)/comments", ["sort": "-created_on", "pagelen": "10",
					"fields": "values.content.raw,values.user.display_name,values.created_on,values.inline.path,values.deleted"])
				let statuses = try await values("/\(id)/statuses", ["sort": "-updated_on", "pagelen": "5",
					"fields": "values.state,values.name,values.updated_on"])
				pullRequests[index]["openTasks"] = tasks.map { Self.shortened($0) }
				pullRequests[index]["newestComments"] = comments.filter { $0["deleted"] as? Bool != true }.map { Self.shortened($0) }
				pullRequests[index]["buildStatuses"] = statuses
				pullRequests[index]["waitsForMyReview"] = Self.waitsForReview(pullRequests[index], me: me)
			} catch {
				pullRequests[index]["detailError"] = "\(error)"
			}
		}
		return pullRequests
	}

	/// A second try covers a short network error, e.g. a stale connection after the Mac woke up.
	private func getWithRetry(_ request: URLRequest) async throws -> (Data, Int) {
		do {
			return try await system.get(request)
		} catch is URLError {
			return try await system.get(request)
		}
	}

	/// The user wrote the pull request or reviews it.
	nonisolated static func concerns(_ pullRequest: [String: Any], me: String) -> Bool {
		if (pullRequest["author"] as? [String: Any])?["display_name"] as? String == me { return true }
		let participants = pullRequest["participants"] as? [[String: Any]] ?? []
		return participants.contains { ($0["user"] as? [String: Any])?["display_name"] as? String == me && $0["role"] as? String == "REVIEWER" }
	}

	/// The author waits for the user: the user reviews the pull request and did not approve it yet, and it is no draft
	/// and has no open task. An open task is for the author, so with one, it is the author's turn.
	nonisolated static func waitsForReview(_ pullRequest: [String: Any], me: String) -> Bool {
		let participants = pullRequest["participants"] as? [[String: Any]] ?? []
		guard let mine = participants.first(where: { ($0["user"] as? [String: Any])?["display_name"] as? String == me && $0["role"] as? String == "REVIEWER" })
		else { return false }
		return mine["approved"] as? Bool != true && pullRequest["draft"] as? Bool != true && (pullRequest["openTasks"] as? [Any])?.isEmpty == true
	}

	/// A task or comment with its text cut to 300 characters.
	nonisolated static func shortened(_ item: [String: Any]) -> [String: Any] {
		var item = item
		if var content = item["content"] as? [String: Any], let raw = content["raw"] as? String, raw.count > 300 {
			content["raw"] = raw.prefix(300) + "…"
			item["content"] = content
		}
		return item
	}

	/// `workspace/repo` from an SSH or HTTPS remote URL on Bitbucket, or `nil` for another host.
	nonisolated static func bitbucketRepository(remote: String) -> String? {
		let remote = remote.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let range = remote.range(of: "bitbucket.org[:/]", options: .regularExpression) else { return nil }
		var path = String(remote[range.upperBound...])
		if path.hasSuffix(".git") { path.removeLast(4) }
		return path.split(separator: "/").count == 2 ? path : nil
	}

	// MARK: - Processes

	/// The variables that a child process gets from the app. The login shell sets the others. An app that a Claude Code
	/// session starts, e.g. with `npm run restart`, has the variables of that session, and a nested `claude` takes them
	/// over.
	nonisolated static func childEnvironment(of environment: [String: String]) -> [String: String] {
		environment.filter { ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "PATH"].contains($0.key) }
	}

	/// Runs a program, with a pipe for each stream. The program ends after `timeout`.
	nonisolated static func execute(_ command: Command) async -> CommandResult {
		await withCheckedContinuation { continuation in
			DispatchQueue.global().async {
				let process = Process()
				process.executableURL = URL(fileURLWithPath: command.executable)
				process.arguments = command.arguments
				process.currentDirectoryURL = command.directory
				process.environment = childEnvironment(of: ProcessInfo.processInfo.environment)
				let input = Pipe(), output = Pipe(), error = Pipe()
				process.standardInput = input
				process.standardOutput = output
				process.standardError = error
				do {
					try process.run()
				} catch {
					return continuation.resume(returning: CommandResult(status: 127, output: "", error: error.localizedDescription))
				}
				let timedOut = TimeoutFlag()
				let timer = DispatchWorkItem {
					timedOut.isSet = true
					process.terminate()
				}
				DispatchQueue.global().asyncAfter(deadline: .now() + command.timeout, execute: timer)
				// A program that does not read its input must not stop the app with SIGPIPE.
				_ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
				DispatchQueue.global().async {
					try? input.fileHandleForWriting.write(contentsOf: command.input)
					try? input.fileHandleForWriting.close()
				}
				// Both pipes are read at the same time, so that a full pipe cannot block the program.
				var errorData = Data()
				let errorRead = DispatchGroup()
				errorRead.enter()
				DispatchQueue.global().async {
					errorData = error.fileHandleForReading.readDataToEndOfFile()
					errorRead.leave()
				}
				let outputData = output.fileHandleForReading.readDataToEndOfFile()
				errorRead.wait()
				process.waitUntilExit()
				timer.cancel()
				continuation.resume(returning: CommandResult(status: process.terminationStatus, output: String(decoding: outputData, as: UTF8.self),
					error: String(decoding: errorData, as: UTF8.self), timedOut: timedOut.isSet))
			}
		}
	}
}

private final class TimeoutFlag: @unchecked Sendable {
	private let lock = NSLock()
	private var value = false
	var isSet: Bool {
		get { lock.withLock { value } }
		set { lock.withLock { value = newValue } }
	}
}
