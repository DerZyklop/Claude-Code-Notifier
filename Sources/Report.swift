import AppKit
import Foundation
import os
import UserNotifications

/// A Markdown file in the project folder that a headless Claude Code run makes, e.g. the morning overview or DiDi. The
/// app collects the data, runs Claude, checks the output and writes the file. The app never stages the file. A
/// ``Kind`` holds what differs between the reports.
@MainActor
final class Report: ObservableObject {
	static let morningOverview = Report(kind: .morningOverview, system: .live)
	static let didi = Report(kind: .didi, system: .live)
	/// All reports, in the order of the menu.
	static let all = [morningOverview, didi]
	/// An automatic run that failed waits this long before the next try, so that each unlock does not start one.
	static let retryDelay: TimeInterval = 30 * 60
	/// The tokens that the run of Claude does not get. Only the app uses them.
	static let secretVariables = [Bitbucket.tokenVariable, Slack.tokenVariable]

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

	/// A failure with a reason for the user.
	struct Failure: Error, CustomStringConvertible {
		let description: String

		init(_ description: String) {
			self.description = description
		}
	}

	/// The days and the hour of the automatic run.
	struct Schedule {
		/// The weekdays of `Calendar`: 1 is Sunday.
		var weekdays: Set<Int>
		var hour: Int
		var menuTitle: String

		/// Today at ``hour``, if today is a day of the schedule and that time has come. Else `nil`.
		func dueMoment(at now: Date, calendar: Calendar) -> Date? {
			guard weekdays.contains(calendar.component(.weekday, from: now)),
				let moment = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now), moment <= now else { return nil }
			return moment
		}
	}

	/// What the run of Claude can do.
	enum Access {
		/// Reads the project folder, its transcripts and `folders`, runs read-only commands and uses `mcpTools`. Prints
		/// Markdown.
		case readsProject(folders: [URL], mcpTools: [String])
		/// Has no tool and no MCP server, and runs in an empty folder. It reads only the input and prints JSON in the
		/// shape of `schema`.
		case readsInputOnly(schema: String)
	}

	/// The data of one run: the JSON on stdin and the facts below the prompt.
	struct Input {
		var data: [String: Any]
		var facts: [String] = []

		var json: Data { (try? JSONSerialization.data(withJSONObject: data, options: .sortedKeys)) ?? Data() }
	}

	/// What differs between the reports.
	struct Kind {
		/// The header of the menu group and the subtitle of the notifications.
		var title: String
		var fileName: String
		/// The name of the prompt file in the app bundle, without `.md`.
		var promptResource: String
		/// The setting that turns the automatic run on.
		var settingsKey: String
		var schedule: Schedule
		/// The notification of a ready file. The one of a failure adds `-failed`.
		var notificationID: String
		var access: Access
		var timeout: TimeInterval
		var collect: @MainActor (Report) async throws -> Input
		/// Checks the output of the run and gives the text of the file. `old` is the file right before the write, `nil`
		/// without one.
		var render: @MainActor (_ report: Report, _ result: CommandResult, _ input: Input, _ old: String?) throws -> String
		var readyBody: (_ text: String, _ input: Input) -> String
		/// The file name of the backup of the old file, or `nil` for no backup.
		var backupName: ((_ old: String) -> String)?
	}

	struct System {
		/// The project folder that gets the files.
		var folder: URL
		/// The folder of the app's own files: the backups, and the empty folder of a run that reads only its input.
		var supportFolder: URL
		/// The tasks of every morning. They come first in the morning overview.
		var dailyTasks: [String]
		/// The tasks of one weekday, by its number in `Calendar`, e.g. 2 for Monday. They come after the daily tasks.
		var weekdayTasks: [Int: [String]]
		var now: () -> Date
		var calendar: Calendar
		var defaults: UserDefaults
		/// The prompt with this name from the app bundle.
		var prompt: (String) -> String?
		var run: (Command) async -> CommandResult
		/// A GET request. Returns the body and the HTTP status.
		var get: (URLRequest) async throws -> (Data, Int)
		var post: @MainActor (_ subtitle: String, _ identifier: String, _ title: String, _ body: String) -> Void
		var removeNotifications: @MainActor ([String]) -> Void
		/// Opens a file in iA Writer, else in VS Code.
		var open: @MainActor (URL) -> Void

		static let live = System(
			folder: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("S/plano"),
			supportFolder: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
				.appendingPathComponent("local.claude-code-notifier.app"),
			dailyTasks: ["⏲️ Zeiterfassung"],
			weekdayTasks: [2: ["🧠 Reflect ticket"]],
			now: Date.init,
			calendar: .current,
			defaults: .standard,
			prompt: { name in
				Bundle.main.url(forResource: name, withExtension: "md").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
			},
			run: Report.execute,
			get: { request in
				let (data, response) = try await URLSession.shared.data(for: request)
				return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
			},
			post: { subtitle, identifier, title, body in
				SessionStore.shared.post(subtitle: subtitle, title: title, body: body, identifier: identifier)
			},
			removeNotifications: { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: $0) },
			open: { openDocument($0, preferring: ["pro.writer.mac", "com.microsoft.VSCode"]) }
		)
	}

	let kind: Kind
	let system: System
	@Published private(set) var isRunning = false
	/// The start of the current run, for its time in the menu.
	private(set) var runStarted: Date?
	/// The current run, for ``stop()``.
	private var runTask: Task<Void, Never>?
	/// You stopped the current run. It ends without a new file and without a failure.
	private(set) var isStopped = false
	/// The reason why the last run failed, `nil` after a run that worked.
	@Published private(set) var failure: String?
	/// A new file waits to be opened. The menu marks it. The defaults keep it, so the mark stays after a restart.
	@Published private(set) var isUnread: Bool {
		didSet { system.defaults.set(isUnread, forKey: Self.unreadKey(of: kind)) }
	}
	private var lastAutomaticRun: Date?
	/// ``runAllIfDue()`` is going, so a second trigger does not start a report at the same time.
	private static var isCheckingAll = false

	init(kind: Kind, system: System) {
		self.kind = kind
		self.system = system
		isUnread = system.defaults.bool(forKey: Self.unreadKey(of: kind))
	}

	/// The key of ``isUnread`` in the defaults.
	static func unreadKey(of kind: Kind) -> String { kind.notificationID + "-unread" }
	/// The key of the due moment whose run you stopped. The automatic run skips that moment, also after a restart.
	static func stoppedKey(of kind: Kind) -> String { kind.notificationID + "-stopped" }

	var fileURL: URL { system.folder.appendingPathComponent(kind.fileName) }
	var failedNotificationID: String { kind.notificationID + "-failed" }

	/// The report whose ready notification has this identifier.
	static func forNotification(_ identifier: String) -> Report? {
		all.first { $0.kind.notificationID == identifier }
	}

	/// Runs the due reports one after the other, so that two automatic runs of Claude never start together.
	/// - Parameter reports: ``all`` without a value.
	static func runAllIfDue(_ reports: [Report]? = nil) async {
		guard !isCheckingAll else { return }
		isCheckingAll = true
		defer { isCheckingAll = false }
		for report in reports ?? all { await report.runIfDue() }
	}

	/// Starts the automatic run, if the setting is on, the run is due, and you did not stop a run since the due moment.
	func runIfDue() async {
		let now = system.now()
		guard SettingsKey.isOn(kind.settingsKey, in: system.defaults), isDue(at: now) else { return }
		let stopped = system.defaults.object(forKey: Self.stoppedKey(of: kind)) as? Date
		if stopped != nil, stopped == kind.schedule.dueMoment(at: now, calendar: system.calendar) { return }
		if let lastAutomaticRun, now.timeIntervalSince(lastAutomaticRun) < Self.retryDelay { return }
		lastAutomaticRun = now
		await update()
	}

	/// Due on a day of the schedule from its hour on, when the `Updated:` time of the file is before that moment.
	func isDue(at now: Date) -> Bool {
		guard !isRunning, let dueMoment = kind.schedule.dueMoment(at: now, calendar: system.calendar) else { return false }
		let text = try? String(contentsOf: fileURL, encoding: .utf8)
		return (text.flatMap { Self.updated(in: $0, calendar: system.calendar) } ?? .distantPast) < dueMoment
	}

	/// The format of the times in the files and in the facts.
	nonisolated static func timestampFormatter(_ calendar: Calendar) -> DateFormatter {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.calendar = calendar
		formatter.timeZone = calendar.timeZone
		formatter.dateFormat = "yyyy-MM-dd HH:mm"
		return formatter
	}

	/// The time of the `Updated: YYYY-MM-DD HH:MM` line near the top, or `nil` without one.
	nonisolated static func updated(in text: String, calendar: Calendar) -> Date? {
		guard let line = text.split(separator: "\n").prefix(10).first(where: { $0.hasPrefix("Updated: ") }) else { return nil }
		return timestampFormatter(calendar).date(from: String(line.dropFirst("Updated: ".count).prefix(16)))
	}

	/// Writes the text of a link that starts with `#` as code, e.g. ``[`#4213`](…)`` or ``[`#dev`](…)``. Some Markdown
	/// editors read `[#4213]` as a tag and show no link. An escaped `[\#4213]` gets the same form. A text with a backslash
	/// in it stays, so that escaped brackets in plain text do not become a link.
	nonisolated static func hashLinksAsCode(in text: String) -> String {
		text.replacingOccurrences(of: #"\[\\?#([^\[\]`\\]+)\]\("#, with: "[`#$1`](", options: .regularExpression)
	}

	/// Makes a new file. ``stop()`` cancels the run.
	func update() async {
		guard !isRunning else { return }
		runStarted = system.now()
		isRunning = true
		isStopped = false
		defer {
			isRunning = false
			runTask = nil
		}
		let task = Task { await run() }
		runTask = task
		await task.value
	}

	/// The steps of ``update()``. A cancel ends the commands and the requests of the run. After each wait, a cancelled run
	/// ends without a file.
	private func run() async {
		guard let prompt = system.prompt(kind.promptResource) else { return fail("The prompt is missing in the app.") }

		let input: Input
		do {
			input = try await kind.collect(self)
		} catch {
			return fail("\(error)")
		}
		if Task.isCancelled { return }
		let command: Command
		do {
			command = try claudeCommand(prompt: prompt + facts(input.facts), input: input.json)
		} catch {
			return fail("The folder of the run could not be made: \(error.localizedDescription)")
		}
		let result = await system.run(command)
		if Task.isCancelled { return }
		if result.timedOut { return fail("Claude did not finish within \(Int(kind.timeout / 60)) minutes.") }
		if result.status == 127 { return fail("The command »claude« was not found.") }

		// The old file is read only now, so that a change during the run stays. A file that exists but cannot be read stops
		// the write, so that its text is not lost.
		let old: String?
		do {
			old = try String(contentsOf: fileURL, encoding: .utf8)
		} catch CocoaError.fileReadNoSuchFile {
			old = nil
		} catch {
			return fail("The old file could not be read: \(error.localizedDescription)")
		}
		let text: String
		do {
			text = try kind.render(self, result, input, old)
		} catch {
			return fail("\(error)")
		}
		do {
			if let old, let name = kind.backupName?(old) { try backUp(old, as: name) }
			excludeFromGit()
			try text.write(to: fileURL, atomically: true, encoding: .utf8)
		} catch {
			return fail("The file could not be written: \(error.localizedDescription)")
		}
		failure = nil
		isUnread = true
		system.removeNotifications([failedNotificationID])
		if !system.defaults.bool(forKey: SettingsKey.muted) {
			system.post(kind.title, kind.notificationID, "Ready", kind.readyBody(text, input))
		}
	}

	/// Ends the current run. The running command gets a `SIGTERM`. The automatic run then waits for the next due moment.
	func stop() {
		guard isRunning else { return }
		isStopped = true
		system.defaults.set(kind.schedule.dueMoment(at: system.now(), calendar: system.calendar), forKey: Self.stoppedKey(of: kind))
		runTask?.cancel()
	}

	/// Every failure gets a notification, also while the notifications are off. The macOS log keeps the reason. A stopped
	/// run has no failure, also when the stop makes a step fail.
	private func fail(_ reason: String) {
		guard !Task.isCancelled else { return }
		failure = reason
		Self.log.error("\(self.kind.title, privacy: .public) failed: \(reason, privacy: .public)")
		system.post(kind.title, failedNotificationID, "Update failed", reason)
	}

	private static let log = Logger(subsystem: "local.claude-code-notifier.app", category: "Report")

	/// Opens the file and removes the mark of a new file.
	func openFile() {
		isUnread = false
		system.open(fileURL)
	}

	/// Keeps the old file in the support folder, one file for each name.
	private func backUp(_ old: String, as name: String) throws {
		let folder = system.supportFolder.appendingPathComponent((kind.fileName as NSString).deletingPathExtension)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		try old.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
	}

	/// Adds the file to `.git/info/exclude` of the project, so that `git add -A` never stages it.
	private func excludeFromGit() {
		let info = system.folder.appendingPathComponent(".git/info")
		// A worktree has a `.git` file, not a folder. Its excludes are in the main repository.
		guard FileManager.default.fileExists(atPath: info.deletingLastPathComponent().appendingPathComponent("HEAD").path) else { return }
		let exclude = info.appendingPathComponent("exclude")
		let text = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
		let pattern = "/" + kind.fileName
		guard !text.split(separator: "\n").contains(where: { $0 == pattern }) else { return }
		try? FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
		try? (text + (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + pattern + "\n").write(to: exclude, atomically: true, encoding: .utf8)
	}

	// MARK: - The run

	/// The run of Claude. `--restricted` ignores the settings files, so their allow rules do not apply. `dontAsk`
	/// refuses every call that is not on the allow list, without a prompt. The run never gets the tokens of the app.
	func claudeCommand(prompt: String, input: Data) throws -> Command {
		var arguments = ["-p", prompt, "--restricted", "--permission-mode", "dontAsk"]
		let directory: URL
		switch kind.access {
		case .readsProject(let folders, let mcpTools):
			// The read rules cover only the project, its transcripts and `folders`. Commands that Claude Code knows as
			// read-only, e.g. `git status`, still run.
			let projectFolder = claudeProjectFolder(of: system.folder.path)
			// A leading `//` makes the path of a rule absolute. Each rule is its own argument, so a space in a path is safe.
			let readRules = ([system.folder, projectFolder] + folders).map { "Read(/\($0.path)/**)" }
			arguments += ["--tools", "Read,Grep,Glob,Bash", "--allowedTools"] + readRules + mcpTools
			arguments += ([projectFolder] + folders).flatMap { ["--add-dir", $0.path] }
			arguments += ["--output-format", "text", "--no-session-persistence", "--strict-mcp-config"]
			let mcpConfig = try? Data(contentsOf: system.folder.appendingPathComponent(".mcp.json"))
			if let servers = mcpConfig.flatMap(Self.remoteServers) { arguments += ["--mcp-config", servers] }
			directory = system.folder
		case .readsInputOnly(let schema):
			// `--tools ""` removes only the built-in tools. The MCP flags remove the servers too. The empty folder has no
			// CLAUDE.md and no .mcp.json.
			arguments += ["--tools", "", "--disallowedTools", "mcp__*", "--strict-mcp-config", "--setting-sources", "",
				"--no-session-persistence", "--output-format", "json", "--json-schema", schema]
			directory = system.supportFolder.appendingPathComponent("run")
			try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		}
		return loginShell(["claude"] + arguments, input: input, timeout: kind.timeout, in: directory, without: Self.secretVariables)
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
	private func facts(_ extra: [String]) -> String {
		let now = Self.timestampFormatter(system.calendar).string(from: system.now())
		return (["", "## Facts", "", "- Now: \(now)"] + extra.map { "- " + $0 }).joined(separator: "\n") + "\n"
	}

	/// Runs a program through the login shell of the user, which sets `PATH` and the variables of the user's profile.
	/// - Parameter variables: The variables of the profile that the program does not get.
	private func loginShell(_ program: [String], input: Data = Data(), timeout: TimeInterval = 30, in directory: URL? = nil,
		without variables: [String] = []) -> Command {
		let shell = getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) } ?? "/bin/zsh"
		// `exec` lets the program take the place of the shell, so a timeout ends the program itself.
		let script = "exec " + (variables.isEmpty ? "" : "env " + variables.map { "-u \($0) " }.joined()) + "\"$0\" \"$@\""
		return Command(executable: shell, arguments: ["-lc", script] + program, directory: directory ?? system.folder,
			input: input, timeout: timeout)
	}

	/// The values of variables of the login shell. A missing or empty variable is not in the result.
	func loginEnvironment(_ names: [String]) async -> [String: String] {
		let script = "printf '%s\\0' " + names.map { "\"$\($0)\"" }.joined(separator: " ")
		let values = await system.run(loginShell(["/bin/sh", "-c", script])).output.components(separatedBy: "\0")
		return Dictionary(uniqueKeysWithValues: zip(names, values).filter { !$0.1.isEmpty })
	}

	func git(_ arguments: [String], in folder: URL? = nil) async -> String {
		let folder = folder ?? system.folder
		return await system.run(Command(executable: "/usr/bin/git", arguments: ["-C", folder.path] + arguments, directory: folder)).output
	}

	/// The git user name, which is also the display name on Bitbucket.
	func me() async -> String {
		await git(["config", "user.name"]).trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// The Bitbucket repository of the remote `origin`, with the credentials of the login shell.
	func bitbucket() async throws -> Bitbucket {
		try Bitbucket(remote: await git(["remote", "get-url", "origin"]),
			environment: await loginEnvironment([Bitbucket.emailVariable, Bitbucket.tokenVariable]), get: system.get)
	}

	/// Slack, with the token of the login shell.
	func slack() async throws -> Slack {
		guard let token = await loginEnvironment([Slack.tokenVariable])[Slack.tokenVariable] else { throw Slack.Failure.noToken }
		return Slack(token: token, get: system.get)
	}

	// MARK: - Processes

	/// The variables that a child process gets from the app. The login shell sets the others. An app that a Claude Code
	/// session starts, e.g. with `npm run restart`, has the variables of that session, and a nested `claude` takes them
	/// over.
	nonisolated static func childEnvironment(of environment: [String: String]) -> [String: String] {
		environment.filter { ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "PATH"].contains($0.key) }
	}

	/// Runs a program, with a pipe for each stream. The program ends after `timeout`, or when its task is cancelled.
	nonisolated static func execute(_ command: Command) async -> CommandResult {
		let running = RunningProcess()
		return await withTaskCancellationHandler {
			await execute(command, as: running)
		} onCancel: {
			running.cancel()
		}
	}

	private nonisolated static func execute(_ command: Command, as running: RunningProcess) async -> CommandResult {
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
					try running.start(process)
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

/// The process of a command, so that a cancel of its task can end it.
private final class RunningProcess: @unchecked Sendable {
	private let lock = NSLock()
	private var process: Process?
	private var isCancelled = false

	/// Starts the process, unless the task is cancelled already.
	func start(_ process: Process) throws {
		try lock.withLock {
			if isCancelled { throw CancellationError() }
			try process.run()
			self.process = process
		}
	}

	func cancel() {
		lock.withLock {
			isCancelled = true
			process?.terminate()
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
