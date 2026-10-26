import Foundation
import Testing
@testable import ClaudeCodeNotifier

/// A Tuesday, 7:00 in UTC: 2026-10-27.
let tuesdayMorning = Date(timeIntervalSince1970: 1_793_084_400)

let utcCalendar: Calendar = {
	var calendar = Calendar(identifier: .gregorian)
	calendar.timeZone = TimeZone(identifier: "UTC")!
	return calendar
}()

/// What the fake system saw, for one test.
@MainActor
final class ReportLog {
	var commands: [Report.Command] = []
	var requests: [URLRequest] = []
	var posts: [(subtitle: String, identifier: String, title: String, body: String)] = []
	var removed: [String] = []
	var opened: [URL] = []
}

/// A value that the fake requests change from other threads.
final class Locked<Value>: @unchecked Sendable {
	private let lock = NSLock()
	private var value: Value

	init(_ value: Value) {
		self.value = value
	}

	func update<Result>(_ body: (inout Value) -> Result) -> Result {
		lock.withLock { body(&value) }
	}
}

/// A report with a fake system in a new temporary folder.
@MainActor
struct ReportFixture {
	/// The folder of the test, with the project folder and the support folder in it.
	let root: URL
	let log = ReportLog()
	let defaults = MemoryDefaults()
	let report: Report

	nonisolated static let credentials = ["BITBUCKET_API_EMAIL": "me@example.com", "BITBUCKET_API_TOKEN": "token", "SLACK_USER_TOKEN": "xoxp-1"]

	/// - Parameters:
	///   - claudeOutput: What the run prints.
	///   - environment: The variables of the login shell.
	///   - body: The body of each answer to a GET request.
	///   - status: The HTTP status of each answer.
	///   - failure: An error for a request, e.g. for a missing network.
	///   - beforeAnswer: Runs while Claude runs, e.g. to change the file.
	init(kind: Report.Kind, now: Date = tuesdayMorning, claudeOutput: String, environment: [String: String] = credentials,
		body: @escaping @Sendable (URLRequest) -> Data, status: Int = 200,
		failure: @escaping @Sendable (URLRequest) -> Error? = { _ in nil }, beforeAnswer: @escaping @Sendable () -> Void = {}) throws {
		root = FileManager.default.temporaryDirectory.appendingPathComponent("ReportTests-\(UUID().uuidString)")
		let folder = root.appendingPathComponent("project")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let log = log
		report = Report(kind: kind, system: Report.System(
			folder: folder, supportFolder: root.appendingPathComponent("support"), dailyTasks: ["Zeiterfassung"], now: { now },
			calendar: utcCalendar, defaults: defaults,
			prompt: { $0 == kind.promptResource ? "PROMPT" : nil },
			run: { command in
				await MainActor.run { log.commands.append(command) }
				if command.arguments.count > 2 && command.arguments[2] == "claude" { beforeAnswer() }
				return ReportFixture.answer(command, claudeOutput: claudeOutput, environment: environment)
			},
			get: { request in
				await MainActor.run { log.requests.append(request) }
				if let error = failure(request) { throw error }
				return (body(request), status)
			},
			post: { log.posts.append(($0, $1, $2, $3)) },
			removeNotifications: { log.removed += $0 },
			open: { log.opened.append($0) }
		))
	}

	func cleanUp() {
		try? FileManager.default.removeItem(at: root)
	}

	var folder: URL { report.system.folder }
	var fileURL: URL { report.fileURL }

	/// The run of Claude Code, which gets the JSON on stdin.
	var claudeRun: Report.Command? {
		log.commands.first { $0.arguments.count > 2 && $0.arguments[2] == "claude" }
	}

	var input: [String: Any] {
		get throws {
			let data = try #require(claudeRun?.input)
			return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
		}
	}

	/// The value after a flag in the arguments of the run.
	func value(of flag: String) -> String? {
		guard let arguments = claudeRun?.arguments, let index = arguments.firstIndex(of: flag) else { return nil }
		return arguments[index + 1]
	}

	nonisolated static func answer(_ command: Report.Command, claudeOutput: String, environment: [String: String]) -> Report.CommandResult {
		let arguments = command.arguments
		if command.executable == "/usr/bin/git" {
			let output = switch Array(arguments.dropFirst(2)) {
			case ["config", "user.name"]: "Nils\n"
			case ["remote", "get-url", "origin"]: "git@bitbucket.org:ws/repo.git\n"
			case ["worktree", "list", "--porcelain"]: worktreeList
			case ["status", "--porcelain"]: " M Sources/a.swift\n"
			default: "abc1234 Local commit\n"
			}
			return .init(status: 0, output: output, error: "")
		}
		switch arguments[2] {
		case "claude": return .init(status: 0, output: claudeOutput, error: "")
		case "/bin/sh":
			// `printf '%s\0' "$A" "$B"`: each value with a NUL behind it.
			let script = arguments[4]
			let names = script.matches(of: #/"\$([A-Z_]+)"/#).map { String($0.1) }
			return .init(status: 0, output: names.map { (environment[$0] ?? "") + "\0" }.joined(), error: "")
		default: return .init(status: 127, output: "", error: "unknown")
		}
	}
}

let worktreeList = """
	worktree /work/repo
	HEAD abc
	branch refs/heads/main

	worktree /work/repo/.claude/worktrees/scratch
	HEAD def
	detached

	"""

/// The body of a Bitbucket answer with these values, and a link to the next page if there is one.
func bitbucketPage(_ values: [[String: Any]], next: String? = nil) -> Data {
	var page: [String: Any] = ["values": values]
	if let next { page["next"] = next }
	return try! JSONSerialization.data(withJSONObject: page)
}
