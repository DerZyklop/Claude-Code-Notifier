import Foundation
import Testing
import UserNotifications
@testable import ClaudeCodeNotifier

private let titleLine = #"{"type":"ai-title","aiTitle":"New title"}"#
private let timeLine = #"{"type":"user","timestamp":"2026-10-21T08:30:15.250Z"}"#
/// The time of ``timeLine``.
private let transcriptStart = Date(timeIntervalSince1970: 1_792_571_415.25)

/// The parts of a notification that the tests compare.
private struct Sent: Equatable {
	let identifier: String
	let title: String
	let subtitle: String
	let body: String

	init(_ identifier: String, _ title: String, _ kind: NotificationKind, _ body: String) {
		self.identifier = identifier
		self.title = title
		subtitle = kind.subtitle
		self.body = body
	}

	init(_ request: UNNotificationRequest) {
		identifier = request.identifier
		title = request.content.title
		subtitle = request.content.subtitle
		body = request.content.body
	}
}

/// Keeps the notifications that the store adds and removes.
private final class NotificationLog {
	var added: [UNNotificationRequest] = []
	var removed: [String] = []

	var sent: [Sent] { added.map { Sent($0) } }
	var isEmpty: Bool { added.isEmpty && removed.isEmpty }
}

/// The JSON of a hook event. The working directory is `/work/project` unless the fields set another one.
private func hookJSON(_ name: String, _ fields: [String: String] = [:], id: String = "s1") -> Data {
	var object = ["cwd": "/work/project"].merging(fields) { $1 }
	object["hook_event_name"] = name
	object["session_id"] = id
	return try! JSONSerialization.data(withJSONObject: object)
}

private func hookEvent(_ name: String, _ fields: [String: String] = [:], id: String = "s1") throws -> HookEvent {
	try JSONDecoder().decode(HookEvent.self, from: hookJSON(name, fields, id: id))
}

/// Polls the condition every 10 ms, for at most 5 s. Returns whether the condition became true.
@MainActor
private func waitUntil(_ condition: () -> Bool) async throws -> Bool {
	let deadline = Date().addingTimeInterval(5)
	while !condition() {
		if Date() >= deadline { return false }
		try await Task.sleep(nanoseconds: 10_000_000)
	}
	return true
}

/// Waits until the clock is past the date, so that the next session is newer.
private func waitForClock(after date: Date) {
	while Date() <= date {}
}

/// A store with a fake system, its own defaults and a new folder for one test.
@MainActor
private struct Fixture {
	let store: SessionStore
	let setup: HookSetup
	let defaults: UserDefaults
	let folder: URL
	let log: NotificationLog

	init() throws {
		let defaults = MemoryDefaults()
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		let setup = HookSetup(settingsURL: folder.appendingPathComponent("settings.json"), readNotificationsAllowed: { $0(nil) })
		let log = NotificationLog()
		store = SessionStore(system: SessionStore.System(
			runningSessions: { [] },
			archivedSessionIDs: { nil },
			shellCommandCounts: { _ in [:] },
			addNotification: { log.added.append($0) },
			removeNotifications: { log.removed += $0 },
			defaults: defaults
		), setup: setup, checksSessions: false)
		self.defaults = defaults
		self.folder = folder
		self.setup = setup
		self.log = log
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
	}

	func cleanUp() {
		try? FileManager.default.removeItem(at: folder)
	}

	func handle(_ name: String, _ fields: [String: String] = [:], id: String = "s1") {
		store.handle(hookJSON(name, fields, id: id))
	}

	/// Adds a session in the state, with no notification. The pid comes from an earlier state of the session.
	func add(_ state: SessionState, id: String = "s1", pid: Int32? = nil) throws {
		let previous = pid.map { Session(id: id, cwd: nil, started: Date(), state: state, updated: Date(), pid: $0) }
		store.set(state, for: try hookEvent("SessionStart", id: id), previous: previous)
	}

	/// Writes the lines to a new transcript in the folder and returns its path.
	func transcript(_ lines: [String]) throws -> String {
		let url = folder.appendingPathComponent("\(UUID().uuidString).jsonl")
		try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
		return url.path
	}
}

@MainActor @Suite struct SessionStoreHandleTests {
	@Test(arguments: ["no json", #"{"hook_event_name":"Stop"}"#, #"{"session_id":"s1"}"#, #"{"hook_event_name":"Stop","session_id":1}"#])
	func invalidEventChangesNothing(json: String) throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		fixture.store.handle(Data(json.utf8))
		#expect(fixture.store.sessions.isEmpty)
		#expect(fixture.log.isEmpty)
		#expect(fixture.setup.lastClaudeEvent == nil)
	}

	@Test func selfTestEventCreatesNoSession() throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		fixture.handle(HookSetup.selfTestEventName, id: "token")
		#expect(fixture.store.sessions.isEmpty)
		#expect(fixture.log.isEmpty)
		#expect(fixture.setup.lastClaudeEvent == nil)
		#expect(fixture.setup.commandTest == .notRun)
	}

	@Test func selfTestEventPassesTheCommandTest() async throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		let event = fixture.folder.appendingPathComponent("event.json")
		let pidFile = fixture.folder.appendingPathComponent("pid")
		// The command keeps the test event and the PID of its shell in files. The comment makes it a hook of this app.
		let command = "echo $$ > '\(pidFile.path)'; cat > '\(event.path).part' && mv '\(event.path).part' '\(event.path)' # :\(eventPort)/event"
		let settings = ["hooks": ["Stop": [["hooks": [["type": "command", "command": command]]]]]]
		try JSONSerialization.data(withJSONObject: settings).write(to: fixture.folder.appendingPathComponent("settings.json"))
		fixture.setup.listenerError = .some(nil)
		fixture.setup.refresh()
		#expect(fixture.setup.commandTest == .running)
		// Only the token of the running test passes it.
		fixture.handle(HookSetup.selfTestEventName, id: "other token")
		#expect(fixture.setup.commandTest == .running)

		try #require(try await waitUntil { FileManager.default.fileExists(atPath: event.path) })
		let pid = try #require(Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
		#expect(try await waitUntil { kill(pid, 0) != 0 })
		fixture.store.handle(try Data(contentsOf: event))
		#expect(fixture.setup.commandTest == .passed)
		#expect(fixture.store.sessions.isEmpty)
		#expect(fixture.log.isEmpty)
		#expect(fixture.setup.lastClaudeEvent == nil)
	}

	@Test(arguments: ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "StopFailure", "SessionEnd", "SubagentStop"])
	func everyClaudeEventIsRecorded(name: String) throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		let before = Date()
		fixture.handle(name)
		let last = try #require(fixture.setup.lastClaudeEvent)
		#expect(last >= before && last <= Date())
		#expect(fixture.defaults.dictionaryRepresentation().isEmpty)
	}

	@Test func sessionStartIsYourTurn() throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		fixture.handle("SessionStart")
		let session = try #require(fixture.store.sessions["s1"])
		#expect(session.state == .yourTurn)
		#expect(session.cwd == "/work/project")
		#expect(fixture.log.isEmpty)
	}

	@Test(arguments: ["UserPromptSubmit", "PostToolUse"])
	func promptOrToolUseIsWorking(name: String) throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		try fixture.add(.asksYou)
		fixture.handle(name)
		#expect(fixture.store.sessions["s1"]?.state == .working)
		#expect(fixture.log.removed == ["s1"])
		#expect(fixture.log.added.isEmpty)
	}

	@Test(arguments: [("AskUserQuestion", "Claude has a question for you."), ("ExitPlanMode", "Claude wants you to approve the plan.")])
	func questionOrPlanAsksYou(tool: String, body: String) throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		try fixture.add(.working)
		fixture.handle("PreToolUse", ["tool_name": tool])
		#expect(fixture.store.sessions["s1"]?.state == .asksYou)
		#expect(fixture.log.sent == [Sent("s1", "project", .asksYou, body)])
		#expect(fixture.log.removed.isEmpty)
	}

	@Test(arguments: ["Bash", nil] as [String?])
	func otherToolChangesNothing(tool: String?) throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		try fixture.add(.working)
		let before = fixture.store.sessions["s1"]
		let fields = tool.map { ["tool_name": $0] } ?? [:]
		fixture.handle("PreToolUse", fields)
		fixture.handle("PreToolUse", fields, id: "s2")
		#expect(fixture.store.sessions["s1"] == before)
		#expect(fixture.store.sessions["s2"] == nil)
		#expect(fixture.log.isEmpty)
	}

	@Test(arguments: [nil, .working, .ended] as [SessionState?])
	func idleReminderIsYourTurn(previous: SessionState?) throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		if let previous { try fixture.add(previous) }
		fixture.handle("Notification", ["notification_type": "idle_prompt", "message": "Claude is waiting for your input"])
		#expect(fixture.store.sessions["s1"]?.state == .yourTurn)
		#expect(fixture.log.sent == [Sent("s1", "project", .yourTurn, "Claude is waiting for your input")])
	}

	@Test(arguments: [SessionState.yourTurn, .asksYou])
	func idleReminderAfterTurnOrQuestionChangesNothing(previous: SessionState) throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		try fixture.add(previous)
		let before = fixture.store.sessions["s1"]
		fixture.handle("Notification", ["notification_type": "idle_prompt", "message": "Claude is waiting for your input"])
		#expect(fixture.store.sessions["s1"] == before)
		#expect(fixture.log.isEmpty)
	}

	@Test func idleReminderWithoutMessage() throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		fixture.handle("Notification", ["notification_type": "idle_prompt"])
		#expect(fixture.store.sessions["s1"]?.state == .yourTurn)
		#expect(fixture.log.sent == [Sent("s1", "project", .yourTurn, "Claude is waiting for your input.")])
	}

	@Test func messageAloneMakesAnIdleReminder() throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		fixture.handle("Notification", ["message": "Claude is WAITING for your input"])
		#expect(fixture.store.sessions["s1"]?.state == .yourTurn)
		#expect(fixture.log.sent == [Sent("s1", "project", .yourTurn, "Claude is WAITING for your input")])
	}

	@Test(arguments: [nil, .working, .yourTurn, .ended] as [SessionState?])
	func notificationAsksYou(previous: SessionState?) throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		if let previous { try fixture.add(previous) }
		fixture.handle("Notification", ["notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash"])
		#expect(fixture.store.sessions["s1"]?.state == .asksYou)
		#expect(fixture.log.sent == [Sent("s1", "project", .asksYou, "Claude needs your permission to use Bash")])
	}

	@Test func notificationWithoutMessage() throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		fixture.handle("Notification", ["notification_type": "permission_prompt"])
		#expect(fixture.store.sessions["s1"]?.state == .asksYou)
		#expect(fixture.log.sent == [Sent("s1", "project", .asksYou, "Claude needs your input.")])
	}

	@Test func notificationAfterQuestionChangesNothing() throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		try fixture.add(.asksYou)
		let before = fixture.store.sessions["s1"]
		fixture.handle("Notification", ["notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash"])
		#expect(fixture.store.sessions["s1"] == before)
		#expect(fixture.log.isEmpty)
	}

	@Test(arguments: [nil, true] as [Bool?])
	func stopIsYourTurn(notifyOnDone: Bool?) throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		if let notifyOnDone { fixture.defaults.set(notifyOnDone, forKey: SettingsKey.notifyOnDone) }
		try fixture.add(.working)
		fixture.handle("Stop")
		#expect(fixture.store.sessions["s1"]?.state == .yourTurn)
		#expect(fixture.log.sent == [Sent("s1", "project", .yourTurn, "Claude has finished.")])
		#expect(fixture.log.removed.isEmpty)
	}

	@Test func stopWithNotifyOnDoneOffSendsNothing() throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		fixture.defaults.set(false, forKey: SettingsKey.notifyOnDone)
		try fixture.add(.working)
		fixture.handle("Stop", ["last_assistant_message": "Done."])
		#expect(fixture.store.sessions["s1"]?.state == .yourTurn)
		#expect(fixture.log.isEmpty)
	}

	@Test(arguments: [
		("First line\n\n  Second line  \n", "First line Second line"),
		(" \n\t\n", "Claude has finished."),
		(String(repeating: "a", count: 180), String(repeating: "a", count: 180)),
		(String(repeating: "a", count: 181), String(repeating: "a", count: 180) + "…"),
	])
	func stopShowsTheLastMessage(message: String, body: String) throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		fixture.handle("Stop", ["last_assistant_message": message])
		#expect(fixture.log.sent == [Sent("s1", "project", .yourTurn, body)])
	}

	@Test(arguments: [
		("rate_limit", "Claude stopped because of an error: rate_limit."),
		(nil, "Claude stopped because of an error: unknown."),
	] as [(String?, String)])
	func stopFailureIsYourTurn(error: String?, body: String) throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		try fixture.add(.working)
		fixture.handle("StopFailure", error.map { ["error": $0] } ?? [:])
		#expect(fixture.store.sessions["s1"]?.state == .yourTurn)
		#expect(fixture.log.sent == [Sent("s1", "project", .yourTurn, body)])
	}

	@Test(arguments: [
		("PreToolUse", ["tool_name": "AskUserQuestion"], SessionState.asksYou),
		("Notification", ["notification_type": "permission_prompt"], .asksYou),
		("Notification", ["notification_type": "idle_prompt"], .yourTurn),
		("Stop", [:], .yourTurn),
		("StopFailure", ["error": "rate_limit"], .yourTurn),
	])
	func mutedStoreChangesTheStateButSendsNothing(name: String, fields: [String: String], state: SessionState) throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		fixture.defaults.set(true, forKey: SettingsKey.muted)
		fixture.handle(name, fields)
		#expect(fixture.store.sessions["s1"]?.state == state)
		#expect(fixture.log.added.isEmpty)
	}

	@Test func notificationShowsTheTitleOfTheTranscript() throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		let path = try fixture.transcript([timeLine, titleLine])
		fixture.handle("UserPromptSubmit", ["transcript_path": path])
		// The Stop event has no transcript path, so the session keeps the one of the prompt.
		fixture.handle("Stop")
		let session = try #require(fixture.store.sessions["s1"])
		#expect(session.transcriptPath == path)
		#expect(session.started == transcriptStart)
		#expect(fixture.log.sent == [Sent("s1", "New title", .yourTurn, "Claude has finished.")])
	}

	@Test func clearRemovesTheSession() throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		try fixture.add(.working)
		fixture.handle("SessionEnd", ["reason": "clear"])
		#expect(fixture.store.sessions["s1"] == nil)
		#expect(fixture.log.removed == ["s1"])
		#expect(fixture.log.added.isEmpty)
	}

	@Test(arguments: ["logout", "prompt_input_exit", nil] as [String?])
	func sessionEndEndsTheSession(reason: String?) throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		try fixture.add(.working)
		fixture.handle("SessionEnd", reason.map { ["reason": $0] } ?? [:])
		#expect(fixture.store.sessions["s1"]?.state == .ended)
		#expect(fixture.log.removed == ["s1"])
		#expect(fixture.log.added.isEmpty)
	}

	@Test func unknownEventChangesNothing() throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		try fixture.add(.working)
		let before = fixture.store.sessions["s1"]
		fixture.handle("SubagentStop")
		fixture.handle("SubagentStop", id: "s2")
		#expect(fixture.store.sessions["s1"] == before)
		#expect(fixture.store.sessions["s2"] == nil)
		#expect(fixture.log.isEmpty)
	}
}

@MainActor @Suite struct SessionStoreSetTests {
	@Test func newSessionTakesTheEventAndTheTranscript() throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		let path = try fixture.transcript([timeLine, titleLine])
		let event = try hookEvent("UserPromptSubmit", ["transcript_path": path])
		let before = Date()
		let session = fixture.store.set(.working, for: event, previous: nil)
		#expect(session.id == "s1")
		#expect(session.cwd == "/work/project")
		#expect(session.state == .working)
		#expect(session.transcriptPath == path)
		#expect(session.title == "New title")
		#expect(session.started == transcriptStart)
		#expect(session.updated >= before && session.updated <= Date())
		#expect(session.pid == nil)
		#expect(fixture.store.sessions["s1"] == session)
	}

	@Test func keepsCwdStartPidAndTranscriptOfThePreviousSession() throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		let path = try fixture.transcript([timeLine, titleLine])
		let started = Date(timeIntervalSince1970: 1_000_000)
		let previous = Session(id: "s1", cwd: "/old/project", started: started, state: .working, updated: started, transcriptPath: path, pid: 42)
		let session = fixture.store.set(.yourTurn, for: try hookEvent("Stop", ["cwd": "/new/project"]), previous: previous)
		#expect(session.cwd == "/old/project")
		#expect(session.started == started)
		#expect(session.pid == 42)
		#expect(session.transcriptPath == path)
		#expect(session.state == .yourTurn)
		#expect(session.updated > started)
	}

	@Test func previousWithoutCwdTakesTheCwdOfTheEvent() throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		let previous = Session(id: "s1", cwd: nil, started: Date(), state: .working, updated: Date())
		let session = fixture.store.set(.yourTurn, for: try hookEvent("Stop"), previous: previous)
		#expect(session.cwd == "/work/project")
	}

	@Test func transcriptOfTheEventWins() throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		let path = try fixture.transcript([titleLine])
		let previous = Session(id: "s1", cwd: nil, started: Date(), state: .working, updated: Date(), transcriptPath: "/nonexistent/transcript.jsonl")
		let session = fixture.store.set(.yourTurn, for: try hookEvent("Stop", ["transcript_path": path]), previous: previous)
		#expect(session.transcriptPath == path)
		#expect(session.title == "New title")
	}

	@Test(arguments: ["SessionStart", "UserPromptSubmit", "PreToolUse", "Notification", "Stop"])
	func eventReadsTheTitleAgain(name: String) throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		let path = try fixture.transcript([titleLine])
		let previous = Session(id: "s1", cwd: nil, started: Date(), state: .working, updated: Date(), transcriptPath: path, title: "Old title")
		let session = fixture.store.set(.yourTurn, for: try hookEvent(name), previous: previous)
		#expect(session.title == "New title")
	}

	@Test func aReportPromptMarksTheSession() throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		let session = fixture.store.set(.working, for: try hookEvent("UserPromptSubmit", ["prompt": "# Morning overview\n\nYou write"]), previous: nil)
		#expect(session.isReport)
		let next = fixture.store.set(.working, for: try hookEvent("PostToolUse"), previous: session)
		#expect(next.isReport)
	}

	@Test func aReportRunStaysMarkedThroughItsEvents() throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		fixture.handle("SessionStart")
		fixture.handle("UserPromptSubmit", ["prompt": "# Morning overview\n\nYou write\n## Facts\n{\"x\":1}\n"])
		fixture.handle("PostToolUse", ["tool_name": "Read"])
		#expect(fixture.store.sessions["s1"]?.isReport == true)
		#expect(fixture.store.sessions["s1"]?.shownState == .working)
	}

	@Test func anOtherPromptDoesNotMarkTheSession() throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		let session = fixture.store.set(.working, for: try hookEvent("UserPromptSubmit", ["prompt": "Fix the morning overview"]), previous: nil)
		#expect(!session.isReport)
	}

	@Test func toolUseKeepsTheTitle() throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		let path = try fixture.transcript([titleLine])
		let previous = Session(id: "s1", cwd: nil, started: Date(), state: .working, updated: Date(), transcriptPath: path, title: "Old title")
		let session = fixture.store.set(.working, for: try hookEvent("PostToolUse"), previous: previous)
		#expect(session.title == "Old title")
	}

	@Test func toolUseReadsTheTitleWhenThereIsNone() throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		let path = try fixture.transcript([titleLine])
		let previous = Session(id: "s1", cwd: nil, started: Date(), state: .working, updated: Date(), transcriptPath: path)
		let session = fixture.store.set(.working, for: try hookEvent("PostToolUse"), previous: previous)
		#expect(session.title == "New title")
	}

	@Test func transcriptWithoutTitleKeepsTheTitle() throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		for path in [try fixture.transcript([]), fixture.folder.appendingPathComponent("missing.jsonl").path] {
			let previous = Session(id: "s1", cwd: nil, started: Date(), state: .working, updated: Date(), transcriptPath: path, title: "Old title")
			let session = fixture.store.set(.yourTurn, for: try hookEvent("Stop"), previous: previous)
			#expect(session.title == "Old title")
		}
	}

	@Test func withoutTimeInTheTranscriptTheStartIsNow() throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		let paths: [String?] = [nil, try fixture.transcript([titleLine]), fixture.folder.appendingPathComponent("missing.jsonl").path]
		for path in paths {
			let event = try hookEvent("UserPromptSubmit", path.map { ["transcript_path": $0] } ?? [:])
			let before = Date()
			let session = fixture.store.set(.working, for: event, previous: nil)
			#expect(session.started >= before && session.started <= Date())
		}
	}
}

@MainActor @Suite struct SessionStoreNotificationTests {
	@Test(arguments: [
		("Fix the bug", "/work/project", "Fix the bug"),
		(nil, "/work/project", "project"),
		(nil, nil, "Claude Code"),
	] as [(String?, String?, String)])
	func notifyUsesTheSessionIDAndName(title: String?, cwd: String?, name: String) throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		let session = Session(id: "s1", cwd: cwd, started: Date(), state: .asksYou, updated: Date(), title: title)
		fixture.store.notify(.asksYou, session: session, body: "Body")
		#expect(fixture.log.sent == [Sent("s1", name, .asksYou, "Body")])
	}

	@Test(arguments: NotificationKind.allCases)
	func mutedNotifySendsNothing(kind: NotificationKind) throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		fixture.defaults.set(true, forKey: SettingsKey.muted)
		fixture.store.notify(kind, session: Session(id: "s1", cwd: nil, started: Date(), state: .yourTurn, updated: Date()), body: "Body")
		#expect(fixture.log.added.isEmpty)
	}

	@Test(arguments: NotificationKind.allCases)
	func postFillsTheRequest(kind: NotificationKind) throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		fixture.store.post(kind, title: "Title", body: "Body", identifier: "id")
		#expect(fixture.log.sent == [Sent("id", "Title", kind, "Body")])
		let request = try #require(fixture.log.added.first)
		#expect(request.content.sound == nil)
		#expect(request.content.threadIdentifier.isEmpty)
		#expect(request.trigger == nil)
	}

	@Test(arguments: [(NotificationKind.asksYou, "test-asksYou"), (.yourTurn, "test-yourTurn")])
	func testNotificationNamesItsKind(kind: NotificationKind, identifier: String) throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		fixture.store.sendTestNotification(kind)
		#expect(fixture.log.sent == [Sent(identifier, "Test notification", kind, kind.testBody)])
	}

	@Test(arguments: NotificationKind.allCases)
	func testNotificationIgnoresMute(kind: NotificationKind) throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		fixture.defaults.set(true, forKey: SettingsKey.muted)
		fixture.store.sendTestNotification(kind)
		#expect(fixture.log.added.count == 1)
	}

	@Test func removeNotificationRemovesTheOneOfTheSession() throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		fixture.store.removeNotification(of: "s1")
		#expect(fixture.log.removed == ["s1"])
		#expect(fixture.log.added.isEmpty)
	}
}

@MainActor @Suite struct SessionStoreListTests {
	@Test func removeEndedKeepsTheOtherSessions() throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		for (id, state) in [("asks", SessionState.asksYou), ("turn", .yourTurn), ("working", .working), ("ended", .ended), ("ended too", .ended)] {
			try fixture.add(state, id: id)
		}
		fixture.store.removeEnded()
		#expect(Set(fixture.store.sessions.keys) == ["asks", "turn", "working"])
	}

	@Test func sortedByShownStateThenNewestFirst() throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		// Each session is newer than the one before.
		let sessions = [("working old", SessionState.working), ("background", .yourTurn), ("ended", .ended), ("turn", .yourTurn), ("asks", .asksYou), ("working new", .working)]
		for (id, state) in sessions {
			try fixture.add(state, id: id, pid: id == "background" ? 7 : nil)
			waitForClock(after: try #require(fixture.store.sessions[id]).updated)
		}
		// A shell command in the background shows the turn as working.
		fixture.store.apply(shellCommands: [7: 1])
		#expect(fixture.store.sortedSessions.map(\.id) == ["asks", "working new", "background", "working old", "turn", "ended"])
	}

	@Test func hideRemovesTheSessionFromTheList() throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		try fixture.add(.yourTurn, id: "s1")
		try fixture.add(.working, id: "s2")
		fixture.store.hide("s1")
		#expect(fixture.store.sortedSessions.map(\.id) == ["s2"])
		#expect(fixture.store.sessions["s1"] != nil)
	}

	@Test func hiddenSessionComesBackWhenTheStateChanges() throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		try fixture.add(.yourTurn, id: "s1")
		fixture.store.hide("s1")
		fixture.store.handle(hookJSON("Stop"))
		#expect(fixture.store.sortedSessions.isEmpty)
		fixture.store.handle(hookJSON("UserPromptSubmit"))
		#expect(fixture.store.sortedSessions.map(\.id) == ["s1"])
		// The next turn does not hide it again.
		fixture.store.handle(hookJSON("Stop"))
		#expect(fixture.store.sortedSessions.map(\.id) == ["s1"])
		#expect(fixture.store.hiddenStates.isEmpty)
	}

	@Test func hiddenSessionComesBackWithABackgroundTask() throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		try fixture.add(.yourTurn, id: "s1", pid: 7)
		fixture.store.hide("s1")
		fixture.store.apply(shellCommands: [7: 1])
		#expect(fixture.store.sortedSessions.map(\.id) == ["s1"])
	}

	@Test func hideOfAnUnknownSessionDoesNothing() throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		fixture.store.hide("nope")
		#expect(fixture.store.hiddenStates.isEmpty)
	}
}

/// The JSON that the VS Code extension sends for a Claude tab, or for no tab.
private func tabFocusJSON(_ title: String?, folders: [String] = ["/work"]) -> Data {
	let tab: Any = title.map { ["title": $0, "folders": folders] } ?? NSNull()
	return try! JSONSerialization.data(withJSONObject: ["hook_event_name": "TabFocus", "tab": tab])
}

@MainActor @Suite struct SessionStoreFocusTests {
	@Test func focusClosesTheNotificationOfTheSession() throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		try fixture.add(.yourTurn, id: "s1")
		fixture.store.handle(tabFocusJSON("Claude Code"))
		#expect(fixture.log.removed == ["s1"])
		#expect(fixture.store.focusedTab == FocusedTab(title: "Claude Code", folders: ["/work"]))
	}

	@Test(arguments: [("Other title", ["/work"]), ("Claude Code", ["/other"]), ("Claude Code", ["/work/proj"])])
	func focusKeepsTheNotificationsOfOtherSessions(title: String, folders: [String]) throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		try fixture.add(.yourTurn, id: "s1")
		fixture.store.handle(tabFocusJSON(title, folders: folders))
		#expect(fixture.log.removed.isEmpty)
	}

	@Test func focusedSessionGetsNoNotification() throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		fixture.store.handle(tabFocusJSON("Claude Code"))
		fixture.handle("Stop")
		#expect(fixture.log.added.isEmpty)

		fixture.store.handle(tabFocusJSON(nil))
		#expect(fixture.store.focusedTab == nil)
		fixture.handle("Stop")
		#expect(fixture.log.added.count == 1)
	}

	@Test func tabFocusIsNoClaudeEvent() throws {
		let fixture = try Fixture()
		defer { fixture.cleanUp() }
		fixture.store.handle(tabFocusJSON("Claude Code"))
		#expect(fixture.store.sessions.isEmpty)
		#expect(fixture.setup.lastClaudeEvent == nil)
	}

	@Test(arguments: [
		(nil, "Claude Code"),
		("", "Claude Code"),
		("Fix the login page", "Fix the login page"),
		("1234567890123456789012345", "1234567890123456789012345"),
		("12345678901234567890123456", "123456789012345678901234…"),
		("🛎️ Claude Notification App", "🛎️ Claude Notification …"),
	] as [(String?, String)])
	func labelShortensLikeTheExtension(title: String?, label: String) {
		#expect(FocusedTab.label(of: title) == label)
	}
}
