import Foundation
import Testing
import UserNotifications
@testable import ClaudeCodeNotifier

private let interruptLine = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
private let toolUseInterruptLine = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#
private let promptLine = #"{"type":"user","message":{"role":"user","content":"Go on"}}"#
private let assistantLine = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done."}]}}"#

private func systemLine(_ content: String = "") -> String {
	#"{"type":"system","content":"\#(content)"}"#
}

/// Writes the text to a transcript in a new temporary folder, checks the transcript, and deletes the folder.
@MainActor private func endsWithInterrupt(_ text: String) throws -> Bool {
	let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeCodeNotifierTests-\(UUID().uuidString)")
	try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: folder) }
	let url = folder.appendingPathComponent("transcript.jsonl")
	try Data(text.utf8).write(to: url)
	return SessionStore.endsWithInterrupt(transcript: url.path)
}

@MainActor private func endsWithInterrupt(lines: [String]) throws -> Bool {
	try endsWithInterrupt(lines.joined(separator: "\n") + "\n")
}

private func session(state: SessionState = .yourTurn, shellCommands: Int = 0, cwd: String? = "/Users/me/notifier", title: String? = nil) -> Session {
	let date = Date(timeIntervalSince1970: 1_000_000)
	return Session(id: "s", cwd: cwd, started: date, state: state, updated: date, title: title, shellCommands: shellCommands)
}

private func hookEvent(_ json: String) throws -> HookEvent {
	try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
}

private func notification(type: String? = nil, message: String? = nil) -> HookEvent {
	HookEvent(hook_event_name: "Notification", session_id: "s", cwd: nil, message: message, notification_type: type, tool_name: nil, last_assistant_message: nil, reason: nil, transcript_path: nil, error: nil)
}

@Suite struct SettingsKeyTests {
	@Test func keysKeepTheSavedSettings() {
		#expect(SettingsKey.notifyOnDone == "notifyOnDone")
		#expect(SettingsKey.muted == "muted")
		#expect(SettingsKey.playsSound == "playsSound")
	}

	@Test func onlyMuteIsOffByDefault() {
		#expect(SettingsKey.defaultValues == [SettingsKey.notifyOnDone: true, SettingsKey.muted: false, SettingsKey.playsSound: true])
	}
}

@Suite struct SessionStateTests {
	@Test(arguments: [
		(SessionState.asksYou, "asks you"),
		(.yourTurn, "your turn"),
		(.working, "working"),
		(.ended, "ended"),
	])
	func title(state: SessionState, expected: String) {
		#expect(state.title == expected)
	}

	@Test(arguments: [
		(SessionState.asksYou, "questionmark.bubble.fill"),
		(.yourTurn, "checkmark.circle.fill"),
		(.working, "hourglass"),
		(.ended, "stop.circle.fill"),
	])
	func symbol(state: SessionState, expected: String) {
		#expect(state.symbol == expected)
	}

	@Test func rawValueIsTheMenuOrder() {
		#expect([SessionState.asksYou, .yourTurn, .working, .ended].map(\.rawValue) == [0, 1, 2, 3])
	}
}

@Suite struct NotificationKindTests {
	@Test func allCasesInOrder() {
		#expect(NotificationKind.allCases == [.asksYou, .yourTurn])
	}

	@Test(arguments: [
		(NotificationKind.asksYou, "Claude asks you", "Purr.aiff"),
		(.yourTurn, "Your turn", "Bottle.aiff"),
	])
	func subtitleAndSound(kind: NotificationKind, subtitle: String, sound: String) {
		#expect(kind.subtitle == subtitle)
		#expect(kind.sound == UNNotificationSoundName(sound))
	}

	@Test(arguments: [
		(NotificationKind.asksYou, "Claude needs your permission to use Bash."),
		(.yourTurn, "Claude has finished. This is how its last message shows up here."),
	])
	func testBody(kind: NotificationKind, expected: String) {
		#expect(kind.testBody == expected)
	}
}

@Suite struct SessionTests {
	@Test(arguments: [
		(SessionState.yourTurn, 0, false),
		(.yourTurn, 1, true),
		(.yourTurn, 3, true),
		(.working, 1, false),
		(.asksYou, 1, false),
		(.ended, 1, false),
	])
	func hasBackgroundTask(state: SessionState, shellCommands: Int, expected: Bool) {
		#expect(session(state: state, shellCommands: shellCommands).hasBackgroundTask == expected)
	}

	@Test(arguments: [
		(SessionState.yourTurn, 0, SessionState.yourTurn),
		(.yourTurn, 2, .working),
		(.working, 0, .working),
		(.asksYou, 1, .asksYou),
		(.ended, 1, .ended),
	])
	func shownState(state: SessionState, shellCommands: Int, expected: SessionState) {
		#expect(session(state: state, shellCommands: shellCommands).shownState == expected)
	}

	@Test(arguments: [
		(SessionState.yourTurn, 0, "your turn"),
		(.yourTurn, 1, "working in the background"),
		(.working, 1, "working"),
		(.asksYou, 2, "asks you"),
		(.ended, 0, "ended"),
	])
	func stateTitle(state: SessionState, shellCommands: Int, expected: String) {
		#expect(session(state: state, shellCommands: shellCommands).stateTitle == expected)
	}

	@Test(arguments: [
		("/Users/me/notifier", "notifier"),
		("/Users/me/notifier/", "notifier"),
		("/Users/me/My Project", "My Project"),
	])
	func projectIsTheLastFolderOfTheCwd(cwd: String, expected: String) {
		#expect(session(cwd: cwd).project == expected)
	}

	@Test func projectWithoutCwd() {
		#expect(session(cwd: nil).project == "Claude Code")
	}

	@Test func titleIsTheName() {
		#expect(session(title: "Fix the menu").name == "Fix the menu")
	}

	@Test func withoutTitleTheProjectIsTheName() {
		#expect(session(cwd: "/Users/me/notifier").name == "notifier")
		#expect(session(cwd: nil).name == "Claude Code")
	}
}

@Suite struct HookEventTests {
	@Test func decodesAllFields() throws {
		let event = try hookEvent(#"""
			{"hook_event_name":"StopFailure","session_id":"abc","cwd":"/Users/me/notifier","message":"Hello",
			"notification_type":"permission_prompt","tool_name":"Bash","last_assistant_message":"Done.",
			"reason":"clear","transcript_path":"/path/to/abc.jsonl","error":"rate_limit"}
			"""#)
		#expect(event.hook_event_name == "StopFailure")
		#expect(event.session_id == "abc")
		#expect(event.cwd == "/Users/me/notifier")
		#expect(event.message == "Hello")
		#expect(event.notification_type == "permission_prompt")
		#expect(event.tool_name == "Bash")
		#expect(event.last_assistant_message == "Done.")
		#expect(event.reason == "clear")
		#expect(event.transcript_path == "/path/to/abc.jsonl")
		#expect(event.error == "rate_limit")
	}

	@Test func missingOptionalFieldsAreNil() throws {
		let event = try hookEvent(#"{"hook_event_name":"SessionStart","session_id":"abc"}"#)
		#expect(event.hook_event_name == "SessionStart")
		#expect(event.session_id == "abc")
		#expect(event.cwd == nil)
		#expect(event.message == nil)
		#expect(event.notification_type == nil)
		#expect(event.tool_name == nil)
		#expect(event.last_assistant_message == nil)
		#expect(event.reason == nil)
		#expect(event.transcript_path == nil)
		#expect(event.error == nil)
	}

	@Test func nullFieldIsNil() throws {
		let event = try hookEvent(#"{"hook_event_name":"Stop","session_id":"abc","cwd":null,"last_assistant_message":null}"#)
		#expect(event.cwd == nil)
		#expect(event.last_assistant_message == nil)
	}

	@Test func unknownFieldsAreIgnored() throws {
		let event = try hookEvent(#"{"hook_event_name":"Stop","session_id":"abc","permission_mode":"default","stop_hook_active":false}"#)
		#expect(event.hook_event_name == "Stop")
	}

	@Test(arguments: ["hook_event_name", "session_id"])
	func eventWithoutRequiredFieldIsNotDecoded(field: String) throws {
		var fields = ["hook_event_name": "Stop", "session_id": "abc"]
		fields[field] = nil
		let data = try JSONSerialization.data(withJSONObject: fields)
		#expect(throws: DecodingError.self) { try JSONDecoder().decode(HookEvent.self, from: data) }
	}

	@Test func idlePromptTypeIsAnIdleReminder() {
		#expect(notification(type: "idle_prompt", message: "Claude needs your input").isIdleReminder)
		#expect(notification(type: "idle_prompt").isIdleReminder)
	}

	@Test(arguments: ["Claude is waiting for your input", "CLAUDE IS WAITING FOR YOUR INPUT", "Still Waiting For Your Input?"])
	func waitingMessageIsAnIdleReminder(message: String) {
		#expect(notification(message: message).isIdleReminder)
	}

	@Test func permissionPromptIsNoIdleReminder() {
		#expect(!notification(type: "permission_prompt", message: "Claude needs your permission to use Bash").isIdleReminder)
	}

	@Test func notificationWithoutTypeAndMessageIsNoIdleReminder() {
		#expect(!notification().isIdleReminder)
	}
}

@MainActor @Suite struct PreviewTests {
	@Test func nilHasNoPreview() {
		#expect(SessionStore.preview(of: nil) == nil)
	}

	@Test(arguments: ["", "   ", "\n\n", " \t\n  \r\n"])
	func blankMessageHasNoPreview(message: String) {
		#expect(SessionStore.preview(of: message) == nil)
	}

	@Test func joinsTheTrimmedLines() {
		#expect(SessionStore.preview(of: "  First line  \n\n\tSecond line\t\n") == "First line Second line")
	}

	@Test func windowsLineBreaksSplitLines() {
		#expect(SessionStore.preview(of: "One\r\nTwo") == "One Two")
	}

	@Test func spacesInsideALineStay() {
		#expect(SessionStore.preview(of: "  a   b  ") == "a   b")
	}

	@Test func messageOf180CharactersStaysWhole() {
		let message = String(repeating: "a", count: 180)
		#expect(SessionStore.preview(of: message) == message)
	}

	@Test func longMessageIsCutAfter180Characters() {
		#expect(SessionStore.preview(of: String(repeating: "a", count: 181)) == String(repeating: "a", count: 180) + "…")
	}

	@Test func cutComesAfterTheJoin() {
		let message = String(repeating: "a", count: 100) + "\n" + String(repeating: "b", count: 100)
		#expect(SessionStore.preview(of: message) == String(repeating: "a", count: 100) + " " + String(repeating: "b", count: 79) + "…")
	}

	@Test func cutCountsCharactersNotBytes() {
		#expect(SessionStore.preview(of: String(repeating: "👍", count: 181)) == String(repeating: "👍", count: 180) + "…")
	}
}

@MainActor @Suite struct EndsWithInterruptTests {
	@Test func missingFileIsNoInterrupt() {
		#expect(!SessionStore.endsWithInterrupt(transcript: "/nonexistent/transcript.jsonl"))
	}

	@Test func emptyFileIsNoInterrupt() throws {
		#expect(try !endsWithInterrupt(""))
	}

	@Test(arguments: [interruptLine, toolUseInterruptLine])
	func markerAsLastUserLine(marker: String) throws {
		#expect(try endsWithInterrupt(lines: [promptLine, assistantLine, marker]))
	}

	@Test func markerWithoutFinalLineBreak() throws {
		#expect(try endsWithInterrupt(promptLine + "\n" + interruptLine))
	}

	@Test func assistantLineAfterTheMarker() throws {
		#expect(try !endsWithInterrupt(lines: [interruptLine, assistantLine]))
	}

	@Test func promptAfterTheMarker() throws {
		#expect(try !endsWithInterrupt(lines: [interruptLine, promptLine]))
	}

	@Test func lastUserLineWithoutMarker() throws {
		#expect(try !endsWithInterrupt(lines: [assistantLine, promptLine]))
	}

	/// Only a user line can be the marker.
	@Test(arguments: [
		#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#,
		systemLine("[Request interrupted by user]"),
	])
	func markerTextInAnotherLine(line: String) throws {
		#expect(try !endsWithInterrupt(lines: [promptLine, line]))
	}

	@Test func metadataLinesAfterTheMarkerAreSkipped() throws {
		let lines = [promptLine, interruptLine, systemLine("Turn took 2 s"), #"{"type":"file-history-snapshot"}"#, #"{"uuid":"1"}"#]
		#expect(try endsWithInterrupt(lines: lines))
	}

	@Test func emptyLinesAreSkipped() throws {
		#expect(try endsWithInterrupt(interruptLine + "\n\n\n"))
	}

	@Test func onlyMetadataIsNoInterrupt() throws {
		#expect(try !endsWithInterrupt(lines: [systemLine(), #"{"type":"summary","summary":"Fix"}"#]))
	}

	@Test func nonJSONLastLineIsNoInterrupt() throws {
		#expect(try !endsWithInterrupt(lines: [interruptLine, "not json"]))
	}

	@Test func markerAfterALongStartIsFound() throws {
		let longPrompt = #"{"type":"user","message":{"role":"user","content":"\#(String(repeating: "a", count: 100_000))"}}"#
		#expect(try endsWithInterrupt(lines: [longPrompt, assistantLine, interruptLine, systemLine()]))
	}

	/// The check reads only the last 64 KiB. One more byte cuts off the start of the marker line.
	@Test(arguments: [(65_536, true), (65_537, false)])
	func markerAtTheStartOfTheReadPart(size: Int, expected: Bool) throws {
		let head = interruptLine + "\n"
		let fill = size - head.utf8.count - systemLine().utf8.count - 1
		let text = head + systemLine(String(repeating: "x", count: fill)) + "\n"
		try #require(text.utf8.count == size)
		#expect(try endsWithInterrupt(text) == expected)
	}
}
