import Foundation

// The usage limits of all Claude accounts on this Mac. Each account has its own Claude Code configuration folder, see
// ``AccountUsageStore/configDirectories(home:defaultDirectory:)``. To remove the feature, delete this file,
// `AccountUsageCard.swift`, `AccountsView.swift`, their tests, `addUsageCard(to:)` with its call in `StatusMenu`, and
// the tab `SetupTab.accounts`.

/// The limits of one claude.ai subscription, from the `rate_limit_event` of a `claude -p` run.
struct AccountUsage: Equatable {
	struct Window: Equatable {
		/// 0 to 100.
		var percent: Double
		/// `nil` when the window has no reset time, or when its reset time passed.
		var resetsAt: Date?
	}

	var fiveHour: Window?
	var sevenDay: Window?

	/// The limits of the last `rate_limit_event` in the `stream-json` output, or `nil` without one. A window after
	/// its reset time counts as unused, like in the Claude Code extension.
	static func parse(streamJSON output: String, now: Date = Date()) -> AccountUsage? {
		struct Line: Decodable {
			struct Info: Decodable { var unifiedWindows: [String: RawWindow]? }
			struct RawWindow: Decodable {
				var utilization: Double
				var resetsAt: Double?
			}
			var type: String
			var rate_limit_info: Info?
		}
		let windows = output.split(separator: "\n").reversed().lazy
			.compactMap { try? JSONDecoder().decode(Line.self, from: Data($0.utf8)) }
			.first { $0.type == "rate_limit_event" }?.rate_limit_info?.unifiedWindows
		guard let windows else { return nil }
		func window(_ key: String) -> Window? {
			windows[key].map { raw in
				let reset = raw.resetsAt.map { Date(timeIntervalSince1970: $0) }
				if let reset, reset <= now { return Window(percent: 0) }
				return Window(percent: raw.utilization * 100, resetsAt: reset)
			}
		}
		return AccountUsage(fiveHour: window("five_hour"), sevenDay: window("seven_day"))
	}
}

/// One row of ``AccountUsageCard``.
struct AccountUsageEntry: Identifiable, Equatable {
	let directory: URL
	var email: String?
	var usage: AccountUsage?
	var updated: Date?
	/// The reason of the last failed update. The card keeps the older ``usage``.
	var failure: String?
	/// The folder has no login yet, see ``AccountLogin``.
	var needsLogin = false
	var isLoading = false

	var id: String { directory.path }
	var name: String { email ?? (directory.path as NSString).abbreviatingWithTildeInPath }
}

/// The usage of each account. The menu updates it when it opens and the data is older than ``maxAge``. Each update
/// sends a prompt of one token per account, so it uses a little of the 5-hour limit, and it starts that limit on an
/// idle account.
@MainActor
final class AccountUsageStore: ObservableObject {
	static let shared = AccountUsageStore()
	static let maxAge: TimeInterval = 10 * 60

	struct Fetch: Equatable {
		var email: String?
		var usage: AccountUsage?
		var failure: String?
		var needsLogin = false
	}

	@Published private(set) var entries: [AccountUsageEntry] = []
	private let directories: () -> [URL]
	private let fetch: (URL) async -> Fetch

	init(directories: @escaping () -> [URL] = { AccountUsageStore.configDirectories() },
		fetch: @escaping (URL) async -> Fetch = AccountUsageProbe.run) {
		self.directories = directories
		self.fetch = fetch
	}

	var isLoading: Bool { entries.contains(where: \.isLoading) }

	/// Reads the folders again, then updates the accounts without data or with data older than ``maxAge``.
	func refreshIfStale(now: Date = Date()) {
		syncDirectories()
		refresh(entries.filter { entry in entry.updated.map { now.timeIntervalSince($0) > Self.maxAge } ?? true }.map(\.id))
	}

	func refreshAll() {
		syncDirectories()
		refresh(entries.map(\.id))
	}

	private func syncDirectories() {
		let old = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
		let new = directories().map { old[$0.path] ?? AccountUsageEntry(directory: $0) }
		if new != entries { entries = new }
	}

	private func refresh(_ ids: [String]) {
		for index in entries.indices where ids.contains(entries[index].id) && !entries[index].isLoading {
			entries[index].isLoading = true
			let directory = entries[index].directory
			Task {
				let result = await fetch(directory)
				guard let index = entries.firstIndex(where: { $0.directory == directory }) else { return }
				entries[index].isLoading = false
				entries[index].email = result.email ?? entries[index].email
				entries[index].failure = result.failure
				entries[index].needsLogin = result.needsLogin
				if let usage = result.usage {
					entries[index].usage = usage
					entries[index].updated = Date()
				}
			}
		}
	}

	/// The folder of a new account, `~/.claude-<name>`, or `nil` for a name that is not lowercase letters, digits and
	/// `-`, or that an account has already.
	nonisolated static func newDirectory(named name: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
		guard !name.isEmpty, name.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }) else { return nil }
		let directory = home.appendingPathComponent(".claude-\(name)", isDirectory: true)
		return FileManager.default.fileExists(atPath: directory.path) ? nil : directory
	}

	/// The default folder first, then each folder `~/.claude-*` that Claude Code uses: it holds a `.claude.json`.
	nonisolated static func configDirectories(home: URL = FileManager.default.homeDirectoryForCurrentUser,
		defaultDirectory: URL = claudeConfigDirectory) -> [URL] {
		let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
		let others = names.filter { $0.hasPrefix(".claude-") }.sorted()
			.map { home.appendingPathComponent($0, isDirectory: true) }
			.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(".claude.json").path) }
			.filter { $0.standardizedFileURL.path != defaultDirectory.standardizedFileURL.path }
		return [defaultDirectory] + others
	}
}

/// Reads the usage of one account with the `claude` command of the user, so that the app never reads a token.
@MainActor
enum AccountUsageProbe {
	static func run(directory: URL) async -> AccountUsageStore.Fetch {
		let status = await claude(["auth", "status"], directory: directory, timeout: 20)
		let auth = try? JSONDecoder().decode(AuthStatus.self, from: Data(status.output.utf8))
		guard let auth else { return .init(failure: failureText(status) ?? "»claude auth status« gave no answer.") }
		guard auth.loggedIn else {
			return .init(failure: "Not logged in.", needsLogin: true)
		}
		guard auth.authMethod == nil || auth.authMethod == "claude.ai" else {
			return .init(email: auth.email, failure: "Uses an API key, which has no subscription limits.")
		}
		// `--setting-sources ""` skips the hooks, so that the run does not show as a session.
		let probe = await claude(["-p", ".", "--model", "haiku", "--tools", "", "--disallowedTools", "mcp__*", "--strict-mcp-config",
			"--setting-sources", "", "--no-session-persistence", "--output-format", "stream-json", "--verbose"], directory: directory, timeout: 60)
		guard let usage = AccountUsage.parse(streamJSON: probe.output) else {
			return .init(email: auth.email, failure: failureText(probe) ?? "Claude Code sent no usage limits.")
		}
		return .init(email: auth.email, usage: usage)
	}

	private struct AuthStatus: Decodable {
		var loggedIn: Bool
		var authMethod: String?
		var email: String?
	}

	private static func failureText(_ result: Report.CommandResult) -> String? {
		if result.timedOut { return "»claude« did not answer in time." }
		let error = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
		return error.isEmpty ? nil : String(error.prefix(200))
	}

	private static func claude(_ arguments: [String], directory: URL, timeout: TimeInterval) async -> Report.CommandResult {
		await Report.execute(command(arguments, directory: directory, timeout: timeout))
	}

	/// Runs `claude` through the login shell for its `PATH`, in an empty folder. The default folder runs without
	/// `CLAUDE_CONFIG_DIR`, because its login belongs to the unset variable.
	static func command(_ arguments: [String], directory: URL, timeout: TimeInterval) -> Report.Command {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeCodePulse-usage", isDirectory: true)
		try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let isDefault = directory.standardizedFileURL.path == FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent(".claude").standardizedFileURL.path
		let account = isDefault ? ["-u", "CLAUDE_CONFIG_DIR"] : ["CLAUDE_CONFIG_DIR=\(directory.path)"]
		let secrets = Report.secretVariables.flatMap { ["-u", $0] }
		let shell = getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) } ?? "/bin/zsh"
		return Report.Command(executable: shell, arguments: ["-lc", #"exec "$0" "$@""#, "/usr/bin/env"] + secrets + account
			+ ["claude"] + arguments, directory: folder, timeout: timeout)
	}
}
