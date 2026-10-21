import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ClaudeCodeNotifier

/// A command that counts as a command for this app, but that the tests never run.
private let appCommand = "curl --data-binary @- http://127.0.0.1:\(eventPort)/event"

/// Creates a new empty folder. The caller deletes it.
private func makeFolder() throws -> URL {
	let url = FileManager.default.temporaryDirectory.appendingPathComponent("HookSetupTests-\(UUID().uuidString)")
	try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
	return url
}

/// Settings with one matcher group for each event, which runs the commands.
private func settings(hooks: [String: [String]]) -> [String: Any] {
	["hooks": hooks.mapValues { commands in [["hooks": commands.map { ["type": "command", "command": $0] }]] }]
}

/// The same commands for each required event.
private func everyEvent(_ commands: [String]) -> [String: [String]] {
	Dictionary(uniqueKeysWithValues: requiredHookEvents.map { ($0, commands) })
}

/// The `hooks` object of a snippet. A snippet that is not a whole file gets braces around it.
private func hooksObject(_ snippet: String, asFile: Bool) throws -> [String: Any] {
	let text = asFile ? snippet : "{" + snippet + "}"
	let root = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
	return try #require(root["hooks"] as? [String: Any])
}

/// The events of a snippet, in the order of the text.
private func eventOrder(_ snippet: String) -> [String] {
	snippet.split(separator: "\n").compactMap { line in
		let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
		return parts.count > 2 && parts[2].hasPrefix(": [") ? String(parts[1]) : nil
	}
}

/// Writes the text to a settings file in a new folder, checks the file, and deletes the folder.
@MainActor private func check(_ text: String) throws -> SettingsCheck {
	let folder = try makeFolder()
	defer { try? FileManager.default.removeItem(at: folder) }
	let url = folder.appendingPathComponent("settings.json")
	try text.write(to: url, atomically: true, encoding: .utf8)
	return HookSetup.checkSettings(at: url)
}

@MainActor private func check(settings object: [String: Any]) throws -> SettingsCheck {
	try check(String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
}

/// Checks the condition every 20 ms until it is true or the timeout ends.
@MainActor private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
	let end = Date().addingTimeInterval(timeout)
	while !condition() {
		guard Date() < end else { return false }
		try? await Task.sleep(nanoseconds: 20_000_000)
	}
	return true
}

/// Waits until a command wrote a whole test event to the file, and returns the event.
private func testEvent(at url: URL) async -> [String: String]? {
	let end = Date().addingTimeInterval(3)
	while Date() < end {
		if let data = try? Data(contentsOf: url), let event = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
			return event
		}
		try? await Task.sleep(nanoseconds: 20_000_000)
	}
	return nil
}

/// A loopback port that nothing listens on.
private func freePort() throws -> UInt16 {
	let descriptor = socket(AF_INET, SOCK_STREAM, 0)
	try #require(descriptor >= 0)
	defer { close(descriptor) }
	var address = sockaddr_in()
	address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
	address.sin_family = sa_family_t(AF_INET)
	address.sin_addr.s_addr = inet_addr("127.0.0.1")
	var length = socklen_t(MemoryLayout<sockaddr_in>.size)
	let bound = withUnsafeMutablePointer(to: &address) { pointer in
		pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) == 0 && getsockname(descriptor, $0, &length) == 0 }
	}
	try #require(bound)
	return UInt16(bigEndian: address.sin_port)
}

/// Runs the command with `/bin/sh` and the input on stdin, and returns its exit status, or -1 after 5 s.
private func runShell(_ command: String, input: Data) async throws -> Int32 {
	let process = Process()
	process.executableURL = URL(fileURLWithPath: "/bin/sh")
	process.arguments = ["-c", command]
	let stdin = Pipe()
	process.standardInput = stdin
	process.standardOutput = FileHandle.nullDevice
	process.standardError = FileHandle.nullDevice
	try process.run()
	defer {
		if process.isRunning { process.terminate() }
		process.waitUntilExit()
	}
	stdin.fileHandleForWriting.write(input)
	try stdin.fileHandleForWriting.close()
	let end = Date().addingTimeInterval(5)
	while process.isRunning, Date() < end { try await Task.sleep(nanoseconds: 20_000_000) }
	return process.isRunning ? -1 : process.terminationStatus
}

/// A settings folder, defaults and a fake notification permission for one test. The test calls ``remove()`` at the end.
@MainActor private final class Sandbox {
	let folder: URL
	let defaults: UserDefaults
	/// What the fake permission reader reports.
	var notificationsAllowed: Bool? = true

	init() throws {
		defaults = MemoryDefaults()
		folder = try makeFolder()
	}

	var settingsURL: URL { folder.appendingPathComponent("settings.json") }
	var payloadURL: URL { folder.appendingPathComponent("payload.json") }

	/// A hook command that writes the test event to ``payloadURL``. The comment makes it a command for this app.
	var command: String { "cat > '\(payloadURL.path)' # :\(eventPort)/event" }

	func makeSetup() -> HookSetup {
		HookSetup(settingsURL: settingsURL, defaults: defaults) { [weak self] completion in
			completion(self?.notificationsAllowed ?? nil)
		}
	}

	func writeSettings(_ object: [String: Any]) throws {
		try JSONSerialization.data(withJSONObject: object).write(to: settingsURL)
	}

	/// Writes settings in which each required event runs the commands.
	func writeHooks(_ commands: [String]) throws {
		try writeSettings(settings(hooks: everyEvent(commands)))
	}

	/// Waits for the test event that ``command`` wrote, and returns its token.
	func token() async throws -> String {
		let event = try #require(await testEvent(at: payloadURL))
		return try #require(event["session_id"])
	}

	func remove() {
		try? FileManager.default.removeItem(at: folder)
	}
}

@Suite struct HookCommandTests {
	@Test func portIsFixed() {
		#expect(eventPort == 47823)
	}

	@Test func commandSendsToThePortOfTheApp() {
		#expect(hookCommand.contains("http://127.0.0.1:\(eventPort)/event"))
	}

	@Test func commandSendsTheHeaderThatTheServerNeeds() {
		#expect(hookCommand.contains("-H 'X-Claude-Hook: 1'"))
	}

	@Test func commandSendsStdinAsTheBody() {
		#expect(hookCommand.contains("--data-binary @-"))
	}

	@Test func commandWaitsAtMostOneSecond() {
		#expect(hookCommand.contains("-m 1"))
	}

	@Test func commandNeedsNoEscapingInJSON() {
		#expect(!hookCommand.contains("\""))
		#expect(!hookCommand.contains("\\"))
	}

	@Test func commandSucceedsWhenNothingListens() async throws {
		let port = try freePort()
		let command = hookCommand.replacingOccurrences(of: ":\(eventPort)/", with: ":\(port)/")
		try #require(command != hookCommand)
		#expect(try await runShell(command, input: Data(#"{"hook_event_name":"Stop"}"#.utf8)) == 0)
	}
}

@Suite struct RequiredHooksTests {
	@Test func eventsInOrder() {
		#expect(requiredHookEvents == ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "StopFailure", "SessionEnd"])
	}

	@Test func eventsAreTheEventsOfTheHooks() {
		#expect(requiredHookEvents == requiredHooks.map(\.event))
		#expect(Set(requiredHookEvents).count == requiredHookEvents.count)
	}

	@Test func onlyPreToolUseHasAMatcher() {
		let withMatcher = requiredHooks.filter { $0.matcher != nil }
		#expect(withMatcher.map(\.event) == ["PreToolUse"])
		#expect(withMatcher.first?.matcher == "AskUserQuestion|ExitPlanMode")
	}

	@Test func settingsFileIsInTheConfigFolder() {
		#expect(claudeSettingsURL.lastPathComponent == "settings.json")
		#expect(claudeSettingsURL.deletingLastPathComponent().path == claudeConfigDirectory.path)
	}
}

@Suite struct HookSettingsJSONTests {
	@Test(arguments: [false, true])
	func allEventsParseAsJSON(asFile: Bool) throws {
		let hooks = try hooksObject(hookSettingsJSON(for: requiredHookEvents, asFile: asFile), asFile: asFile)
		#expect(Set(hooks.keys) == Set(requiredHookEvents))
		for (event, matcher) in requiredHooks {
			let groups = try #require(hooks[event] as? [[String: Any]])
			try #require(groups.count == 1)
			#expect(groups[0].keys.sorted() == (matcher == nil ? ["hooks"] : ["hooks", "matcher"]))
			#expect(groups[0]["matcher"] as? String == matcher)
			#expect(groups[0]["hooks"] as? [[String: String]] == [["type": "command", "command": hookCommand]])
		}
	}

	@Test(arguments: [false, true])
	func entriesFollowTheOrderOfRequiredHooks(asFile: Bool) {
		#expect(eventOrder(hookSettingsJSON(for: requiredHookEvents.reversed(), asFile: asFile)) == requiredHookEvents)
		#expect(eventOrder(hookSettingsJSON(for: ["SessionEnd", "Stop", "SessionStart"], asFile: asFile)) == ["SessionStart", "Stop", "SessionEnd"])
	}

	@Test(arguments: [false, true])
	func unknownEventsAreIgnored(asFile: Bool) throws {
		let hooks = try hooksObject(hookSettingsJSON(for: ["Unknown", "Stop", "stop"], asFile: asFile), asFile: asFile)
		#expect(Array(hooks.keys) == ["Stop"])
	}

	@Test(arguments: [false, true])
	func emptyListGivesNoHooks(asFile: Bool) throws {
		#expect(try hooksObject(hookSettingsJSON(for: [], asFile: asFile), asFile: asFile).isEmpty)
	}

	@Test func repeatedEventGivesOneEntry() {
		#expect(eventOrder(hookSettingsJSON(for: ["Stop", "Stop"], asFile: false)) == ["Stop"])
	}

	@Test func blockIsTheHooksKey() {
		let block = hookSettingsJSON(for: ["Stop"], asFile: false)
		#expect(block.hasPrefix("\"hooks\": {\n"))
		#expect(block.hasSuffix("\n}"))
	}

	@Test func fileIndentsTheBlock() {
		let block = hookSettingsJSON(for: requiredHookEvents, asFile: false)
		let lines = ["{"] + block.split(separator: "\n").map { "    " + $0 } + ["}"]
		#expect(hookSettingsJSON(for: requiredHookEvents, asFile: true) == lines.joined(separator: "\n"))
	}
}

@Suite struct CheckResultEqualityTests {
	@Test func settingsChecksCompareTheirValues() {
		#expect(SettingsCheck.fileMissing == .fileMissing)
		#expect(SettingsCheck.hooksDisabled == .hooksDisabled)
		#expect(SettingsCheck.hooksDisabled != .fileMissing)
		#expect(SettingsCheck.unreadable("a") == .unreadable("a"))
		#expect(SettingsCheck.unreadable("a") != .unreadable("b"))
		#expect(SettingsCheck.found(missingEvents: ["Stop"], commands: ["a"]) == .found(missingEvents: ["Stop"], commands: ["a"]))
		#expect(SettingsCheck.found(missingEvents: ["Stop"], commands: []) != .found(missingEvents: [], commands: []))
		#expect(SettingsCheck.found(missingEvents: [], commands: ["a", "b"]) != .found(missingEvents: [], commands: ["b", "a"]))
	}

	@Test func commandTestsCompareTheirValues() {
		#expect(CommandTest.notRun == .notRun)
		#expect(CommandTest.notRun != .running)
		#expect(CommandTest.passed != .running)
		#expect(CommandTest.failed("a") == .failed("a"))
		#expect(CommandTest.failed("a") != .failed("b"))
		#expect(CommandTest.failed("") != .notRun)
	}
}

@MainActor @Suite struct CheckSettingsTests {
	@Test func missingFile() throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(at: folder) }
		#expect(HookSetup.checkSettings(at: folder.appendingPathComponent("settings.json")) == .fileMissing)
	}

	@Test(arguments: ["", "{", "not json", #"{"hooks": }"#])
	func invalidJSONIsUnreadable(text: String) throws {
		let result = try check(text)
		guard case .unreadable(let reason) = result else {
			Issue.record("Expected unreadable, got \(result)")
			return
		}
		#expect(!reason.isEmpty)
	}

	@Test func folderIsUnreadable() throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(at: folder) }
		let result = HookSetup.checkSettings(at: folder)
		guard case .unreadable(let reason) = result else {
			Issue.record("Expected unreadable, got \(result)")
			return
		}
		#expect(!reason.isEmpty)
	}

	@Test func jsonArrayIsUnreadable() throws {
		#expect(try check("[]") == .unreadable("The file holds no JSON object."))
	}

	@Test func disabledHooksWinOverTheHooks() throws {
		var object = settings(hooks: everyEvent([appCommand]))
		object["disableAllHooks"] = true
		#expect(try check(settings: object) == .hooksDisabled)
	}

	@Test func hooksThatAreNotDisabledAreChecked() throws {
		var object = settings(hooks: everyEvent([appCommand]))
		object["disableAllHooks"] = false
		#expect(try check(settings: object) == .found(missingEvents: [], commands: [appCommand]))
	}

	@Test func fileWithoutHooksMissesEachEvent() throws {
		#expect(try check("{}") == .found(missingEvents: requiredHookEvents, commands: []))
		#expect(try check(settings: ["model": "opus"]) == .found(missingEvents: requiredHookEvents, commands: []))
	}

	@Test func allHooksFound() throws {
		#expect(try check(settings: settings(hooks: everyEvent([appCommand]))) == .found(missingEvents: [], commands: [appCommand]))
	}

	@Test func missingEventsInTheOrderOfRequiredHooks() throws {
		let object = settings(hooks: ["Stop": [appCommand], "SessionStart": [appCommand], "PreToolUse": [appCommand]])
		let missing = ["UserPromptSubmit", "PostToolUse", "Notification", "StopFailure", "SessionEnd"]
		#expect(try check(settings: object) == .found(missingEvents: missing, commands: [appCommand]))
	}

	@Test func commandsForOtherPortsAreIgnored() throws {
		var hooks = everyEvent(["curl http://127.0.0.1:47824/event", "curl http://127.0.0.1:147823/event"])
		hooks["Stop", default: []].append(appCommand)
		let missing = requiredHookEvents.filter { $0 != "Stop" }
		#expect(try check(settings: settings(hooks: hooks)) == .found(missingEvents: missing, commands: [appCommand]))
	}

	@Test func commandsAreDistinctInTheOrderOfTheEvents() throws {
		let first = "first :\(eventPort)/event"
		let second = "second :\(eventPort)/event"
		var hooks = everyEvent([first])
		hooks["SessionStart"] = [second]
		hooks["UserPromptSubmit"] = [first, second]
		#expect(try check(settings: settings(hooks: hooks)) == .found(missingEvents: [], commands: [second, first]))
	}

	@Test func eachMatcherGroupCounts() throws {
		var object = settings(hooks: everyEvent([appCommand]))
		var hooks = try #require(object["hooks"] as? [String: Any])
		hooks["PreToolUse"] = [
			["matcher": "Bash", "hooks": [["type": "command", "command": "echo"]]],
			["matcher": "AskUserQuestion|ExitPlanMode", "hooks": [["type": "command", "command": appCommand]]],
		] as [[String: Any]]
		object["hooks"] = hooks
		#expect(try check(settings: object) == .found(missingEvents: [], commands: [appCommand]))
	}

	@Test func entriesOfAnotherTypeAreIgnored() throws {
		let hooks: [String: Any] = [
			"SessionStart": "not a list",
			"UserPromptSubmit": [["hooks": "not a list"]],
			"PreToolUse": [["hooks": [["type": "command"]]]],
			"PostToolUse": [["hooks": [["type": "command", "command": 47823] as [String: Any]]]],
		]
		let object: [String: Any] = ["hooks": hooks]
		#expect(try check(settings: object) == .found(missingEvents: requiredHookEvents, commands: []))
	}

	@Test func hooksOfAnotherTypeAreIgnored() throws {
		#expect(try check(settings: ["hooks": ["Stop"]]) == .found(missingEvents: requiredHookEvents, commands: []))
	}

	@Test func generatedFilePassesTheCheck() throws {
		#expect(try check(hookSettingsJSON(for: requiredHookEvents, asFile: true)) == .found(missingEvents: [], commands: [hookCommand]))
	}

	@Test func generatedFileForSomeEventsMissesTheOthers() throws {
		let events = ["Stop", "SessionEnd"]
		let missing = requiredHookEvents.filter { !events.contains($0) }
		#expect(try check(hookSettingsJSON(for: events, asFile: true)) == .found(missingEvents: missing, commands: [hookCommand]))
	}
}

@MainActor @Suite struct HookSetupTests {
	@Test func newSetupHasNoResults() throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		let setup = sandbox.makeSetup()
		#expect(setup.listenerError == nil)
		#expect(setup.settings == .fileMissing)
		#expect(setup.commandTest == .notRun)
		#expect(setup.notificationsAllowed == nil)
		#expect(setup.lastClaudeEvent == nil)
	}

	@Test func keysMatchTheOtherParts() {
		// AppDelegate.migrateSettings copies this key.
		#expect(HookSetup.lastClaudeEventKey == "lastClaudeEvent")
		#expect(HookSetup.selfTestEventName == "NotifierSelfTest")
	}

	@Test(arguments: [(nil, false), (.some(nil), true), (.some("Port in use"), false)] as [(String??, Bool)])
	func isListening(error: String??, expected: Bool) throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		let setup = sandbox.makeSetup()
		setup.listenerError = error
		#expect(setup.isListening == expected)
	}

	// The setup does not listen, so the real hook command does not run.
	@Test(arguments: [
		(nil, false),
		("not json", false),
		(#"{"disableAllHooks": true}"#, false),
		(hookSettingsJSON(for: ["Stop"], asFile: true), false),
		(hookSettingsJSON(for: requiredHookEvents, asFile: true), true),
	] as [(String?, Bool)])
	func hooksConfigured(settings: String?, expected: Bool) throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		if let settings { try settings.write(to: sandbox.settingsURL, atomically: true, encoding: .utf8) }
		let setup = sandbox.makeSetup()
		setup.refresh()
		#expect(setup.hooksConfigured == expected)
		#expect(setup.commandTest == .notRun)
	}

	@Test func refreshReadsTheSettingsAgain() throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		let setup = sandbox.makeSetup()
		setup.refresh()
		#expect(setup.settings == .fileMissing)
		try sandbox.writeHooks([sandbox.command])
		setup.refresh()
		#expect(setup.settings == .found(missingEvents: [], commands: [sandbox.command]))
		try FileManager.default.removeItem(at: sandbox.settingsURL)
		setup.refresh()
		#expect(setup.settings == .fileMissing)
	}

	@Test func refreshReadsThePermissionInALaterTask() async throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		let setup = sandbox.makeSetup()
		setup.refresh()
		#expect(setup.notificationsAllowed == nil)
		#expect(await waitUntil { setup.notificationsAllowed == true })
	}

	@Test func refreshTakesTheLatestPermission() async throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		sandbox.notificationsAllowed = false
		let setup = sandbox.makeSetup()
		setup.refresh()
		#expect(await waitUntil { setup.notificationsAllowed == false })
		sandbox.notificationsAllowed = true
		setup.refresh()
		#expect(await waitUntil { setup.notificationsAllowed == true })
	}

	@Test func permissionFromAnotherQueueArrives() async throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		let setup = HookSetup(settingsURL: sandbox.settingsURL, defaults: sandbox.defaults) { completion in
			DispatchQueue.global().async { completion(true) }
		}
		setup.refresh()
		#expect(await waitUntil { setup.notificationsAllowed == true })
	}

	@Test func refreshDoesNotTestTheCommandWhileNotListening() throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		try sandbox.writeHooks([sandbox.command])
		let setup = sandbox.makeSetup()
		setup.refresh()
		#expect(setup.commandTest == .notRun)
		setup.listenerError = .some("Port in use")
		setup.refresh()
		#expect(setup.commandTest == .notRun)
	}

	@Test func refreshDoesNotTestWithoutCommands() throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		try sandbox.writeHooks(["curl http://127.0.0.1:1234/event"])
		let setup = sandbox.makeSetup()
		setup.listenerError = .some(nil)
		setup.refresh()
		#expect(setup.settings == .found(missingEvents: requiredHookEvents, commands: []))
		#expect(setup.commandTest == .notRun)
	}

	@Test func refreshDoesNotTestDisabledHooks() throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		var object = settings(hooks: everyEvent([sandbox.command]))
		object["disableAllHooks"] = true
		try sandbox.writeSettings(object)
		let setup = sandbox.makeSetup()
		setup.listenerError = .some(nil)
		setup.refresh()
		#expect(setup.settings == .hooksDisabled)
		#expect(setup.commandTest == .notRun)
	}

	@Test func refreshTestsTheCommandWhileListening() async throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		try sandbox.writeHooks([sandbox.command])
		let setup = sandbox.makeSetup()
		setup.listenerError = .some(nil)
		setup.refresh()
		#expect(setup.commandTest == .running)
		setup.selfTestReceived(token: try await sandbox.token())
		#expect(setup.commandTest == .passed)
	}

	@Test func refreshTestsTheCommandOnceTheAppListens() async throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		try sandbox.writeHooks([sandbox.command])
		let setup = sandbox.makeSetup()
		setup.refresh()
		#expect(setup.commandTest == .notRun)
		// The settings stay the same, but the test has not run yet.
		setup.listenerError = .some(nil)
		setup.refresh()
		#expect(setup.commandTest == .running)
		setup.selfTestReceived(token: try await sandbox.token())
		#expect(setup.commandTest == .passed)
	}

	@Test func refreshTestsTheCommandOfIncompleteHooks() async throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		try sandbox.writeSettings(settings(hooks: ["Stop": [sandbox.command]]))
		let setup = sandbox.makeSetup()
		setup.listenerError = .some(nil)
		setup.refresh()
		#expect(!setup.hooksConfigured)
		#expect(setup.commandTest == .running)
		setup.selfTestReceived(token: try await sandbox.token())
		#expect(setup.commandTest == .passed)
	}

	@Test func refreshKeepsARunningTest() async throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		try sandbox.writeHooks([sandbox.command])
		let setup = sandbox.makeSetup()
		setup.listenerError = .some(nil)
		setup.refresh()
		let token = try await sandbox.token()
		setup.refresh()
		setup.selfTestReceived(token: token)
		#expect(setup.commandTest == .passed)
	}

	@Test func refreshDoesNotRepeatAPassedTest() async throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		try sandbox.writeHooks([sandbox.command])
		let setup = sandbox.makeSetup()
		setup.listenerError = .some(nil)
		setup.refresh()
		setup.selfTestReceived(token: try await sandbox.token())
		setup.refresh()
		#expect(setup.commandTest == .passed)
	}

	@Test func refreshRepeatsTheTestWhenTheCommandsChange() async throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		try sandbox.writeHooks([sandbox.command])
		let setup = sandbox.makeSetup()
		setup.listenerError = .some(nil)
		setup.refresh()
		setup.selfTestReceived(token: try await sandbox.token())

		let otherPayload = sandbox.folder.appendingPathComponent("other.json")
		try sandbox.writeHooks([sandbox.command, "cat > '\(otherPayload.path)' # :\(eventPort)/event"])
		try FileManager.default.removeItem(at: sandbox.payloadURL)
		setup.refresh()
		#expect(setup.commandTest == .running)
		let token = try await sandbox.token()
		#expect(await testEvent(at: otherPayload)?["session_id"] == token)
		setup.selfTestReceived(token: token)
		#expect(setup.commandTest == .passed)
	}

	@Test func refreshKeepsAPassedTestWhileNotListening() async throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		try sandbox.writeHooks([sandbox.command])
		let setup = sandbox.makeSetup()
		setup.listenerError = .some(nil)
		setup.refresh()
		setup.selfTestReceived(token: try await sandbox.token())
		setup.listenerError = .some("Port in use")
		setup.refresh()
		#expect(setup.commandTest == .passed)
	}

	@Test func refreshResetsAPassedTestWhenTheHooksAreGone() async throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		try sandbox.writeHooks([sandbox.command])
		let setup = sandbox.makeSetup()
		setup.listenerError = .some(nil)
		setup.refresh()
		setup.selfTestReceived(token: try await sandbox.token())
		try FileManager.default.removeItem(at: sandbox.settingsURL)
		setup.refresh()
		#expect(setup.settings == .fileMissing)
		#expect(setup.commandTest == .notRun)
	}

	@Test func refreshResetsARunningTestWhenTheHooksAreGone() async throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		try sandbox.writeHooks([sandbox.command])
		let setup = sandbox.makeSetup()
		setup.listenerError = .some(nil)
		setup.refresh()
		_ = try await sandbox.token()
		try sandbox.writeSettings(["disableAllHooks": true])
		setup.refresh()
		#expect(setup.settings == .hooksDisabled)
		#expect(setup.commandTest == .notRun)
	}

	@Test func commandGetsATestEvent() async throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		try sandbox.writeHooks([sandbox.command])
		let setup = sandbox.makeSetup()
		setup.refresh()
		setup.runCommandTest()
		#expect(setup.commandTest == .running)
		let event = try #require(await testEvent(at: sandbox.payloadURL))
		#expect(event.keys.sorted() == ["hook_event_name", "session_id"])
		#expect(event["hook_event_name"] == HookSetup.selfTestEventName)
		let token = try #require(event["session_id"])
		#expect(UUID(uuidString: token) != nil)
		setup.selfTestReceived(token: token)
		#expect(setup.commandTest == .passed)
	}

	@Test func eachCommandGetsTheSameTestEvent() async throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		let otherPayload = sandbox.folder.appendingPathComponent("other.json")
		try sandbox.writeHooks([sandbox.command, "cat > '\(otherPayload.path)' # :\(eventPort)/event"])
		let setup = sandbox.makeSetup()
		setup.refresh()
		setup.runCommandTest()
		let token = try await sandbox.token()
		#expect(await testEvent(at: otherPayload)?["session_id"] == token)
	}

	@Test func commandTestNeedsACommand() throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		let setup = sandbox.makeSetup()
		setup.runCommandTest()
		#expect(setup.commandTest == .notRun)
		try sandbox.writeHooks(["curl http://127.0.0.1:1234/event"])
		setup.refresh()
		setup.runCommandTest()
		#expect(setup.commandTest == .notRun)
	}

	@Test func wrongTokenKeepsTheTestRunning() async throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		try sandbox.writeHooks([sandbox.command])
		let setup = sandbox.makeSetup()
		setup.refresh()
		setup.runCommandTest()
		// Before any await, so that the 3 s timeout cannot end the test first.
		setup.selfTestReceived(token: "wrong")
		#expect(setup.commandTest == .running)
		setup.selfTestReceived(token: try await sandbox.token())
		#expect(setup.commandTest == .passed)
		setup.selfTestReceived(token: "wrong")
		#expect(setup.commandTest == .passed)
	}

	@Test func eachRunHasANewToken() async throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		try sandbox.writeHooks([sandbox.command])
		let setup = sandbox.makeSetup()
		setup.refresh()
		setup.runCommandTest()
		let first = try await sandbox.token()
		try FileManager.default.removeItem(at: sandbox.payloadURL)
		setup.runCommandTest()
		setup.selfTestReceived(token: first)
		#expect(setup.commandTest == .running)
		let second = try await sandbox.token()
		#expect(first != second)
		setup.selfTestReceived(token: second)
		#expect(setup.commandTest == .passed)
	}

	/// The »Check Again« button of the setup window.
	@Test func checkAgainRepeatsAPassedTest() async throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		try sandbox.writeHooks([sandbox.command])
		let setup = sandbox.makeSetup()
		setup.listenerError = .some(nil)
		setup.refresh()
		let first = try await sandbox.token()
		setup.selfTestReceived(token: first)
		try FileManager.default.removeItem(at: sandbox.payloadURL)
		setup.refresh()
		#expect(setup.commandTest == .passed)
		setup.runCommandTest()
		#expect(setup.commandTest == .running)
		setup.selfTestReceived(token: first)
		#expect(setup.commandTest == .running)
		setup.selfTestReceived(token: try await sandbox.token())
		#expect(setup.commandTest == .passed)
	}

	@Test func selfTestWithoutARunChangesNothing() throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		let setup = sandbox.makeSetup()
		setup.selfTestReceived(token: "")
		setup.selfTestReceived(token: UUID().uuidString)
		#expect(setup.commandTest == .notRun)
	}

	/// The only test that waits for the timeout of the command test.
	@Test func commandTestFailsAfter3SecondsWithoutEvent() async throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		try sandbox.writeHooks([sandbox.command])
		// The user answers the permission dialog later.
		var answerPermission: ((Bool?) -> Void)?
		let setup = HookSetup(settingsURL: sandbox.settingsURL, defaults: sandbox.defaults) { answerPermission = $0 }
		setup.listenerError = .some(nil)
		let start = Date()
		setup.refresh()
		let token = try await sandbox.token()
		#expect(await waitUntil(timeout: 5) { setup.commandTest != .running })
		#expect(Date().timeIntervalSince(start) >= 2.9)
		guard case .failed(let reason) = setup.commandTest else {
			Issue.record("Expected a failed test, got \(setup.commandTest)")
			return
		}
		#expect(reason.contains("3 s"))
		#expect(setup.problem == "Hooks Not Working")

		// Only changed settings or »Check Again« run a failed test again.
		setup.refresh()
		#expect(setup.commandTest == .failed(reason))

		answerPermission?(false)
		#expect(await waitUntil { setup.notificationsAllowed == false })
		#expect(setup.problem == "Notifications Blocked")
		setup.listenerError = .some("Port in use")
		#expect(setup.problem == "Not Listening")

		// A late event still counts.
		setup.selfTestReceived(token: token)
		#expect(setup.commandTest == .passed)
	}

	@Test func claudeEventIsKeptInTheDefaults() throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		let setup = sandbox.makeSetup()
		let before = Date()
		setup.claudeEventReceived()
		let after = Date()
		let date = try #require(setup.lastClaudeEvent)
		#expect(before <= date && date <= after)
		#expect(sandbox.defaults.object(forKey: HookSetup.lastClaudeEventKey) as? Date == date)

		// A new setup reads the date, and only a date.
		#expect(sandbox.makeSetup().lastClaudeEvent == date)
		sandbox.defaults.set("yesterday", forKey: HookSetup.lastClaudeEventKey)
		#expect(sandbox.makeSetup().lastClaudeEvent == nil)
	}

	@Test func setupIsCompleteWhenEachCheckPasses() async throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		try sandbox.writeHooks([sandbox.command])
		let setup = sandbox.makeSetup()
		setup.refresh()
		setup.runCommandTest()
		setup.selfTestReceived(token: try await sandbox.token())
		#expect(await waitUntil { setup.notificationsAllowed == true })
		#expect(setup.hooksConfigured)
		#expect(setup.commandTest == .passed)
		#expect(!setup.isComplete)

		setup.listenerError = .some(nil)
		#expect(setup.isComplete)

		sandbox.notificationsAllowed = false
		setup.refresh()
		#expect(await waitUntil { setup.notificationsAllowed == false })
		#expect(!setup.isComplete)
	}
}

@MainActor @Suite struct HookSetupProblemTests {
	@Test func newSetupIsNotListening() throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		let setup = sandbox.makeSetup()
		#expect(setup.problem == "Not Listening")
		#expect(setup.hasProblem)
	}

	@Test func listenerErrorWinsOverBlockedNotifications() async throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		sandbox.notificationsAllowed = false
		let setup = sandbox.makeSetup()
		setup.listenerError = .some("Port in use")
		setup.refresh()
		#expect(await waitUntil { setup.notificationsAllowed == false })
		#expect(setup.problem == "Not Listening")
	}

	@Test func blockedNotificationsWinOverMissingHooks() async throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		sandbox.notificationsAllowed = false
		let setup = sandbox.makeSetup()
		setup.listenerError = .some(nil)
		setup.refresh()
		#expect(await waitUntil { setup.notificationsAllowed == false })
		#expect(setup.problem == "Notifications Blocked")
		#expect(setup.hasProblem)
	}

	@Test func missingHooksAreAProblem() async throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		let setup = sandbox.makeSetup()
		setup.listenerError = .some(nil)
		setup.refresh()
		#expect(await waitUntil { setup.notificationsAllowed == true })
		#expect(setup.problem == "Hooks Not Working")
	}

	@Test func incompleteHooksAreAProblemAfterAPassedTest() async throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		try sandbox.writeSettings(settings(hooks: ["Stop": [sandbox.command]]))
		let setup = sandbox.makeSetup()
		setup.listenerError = .some(nil)
		setup.refresh()
		setup.selfTestReceived(token: try await sandbox.token())
		#expect(await waitUntil { setup.notificationsAllowed == true })
		#expect(setup.commandTest == .passed)
		#expect(setup.problem == "Hooks Not Working")
		#expect(!setup.isComplete)
	}

	@Test func runningTestIsNoProblem() async throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		try sandbox.writeHooks([sandbox.command])
		let setup = sandbox.makeSetup()
		setup.listenerError = .some(nil)
		setup.refresh()
		#expect(await waitUntil { setup.notificationsAllowed == true })
		#expect(setup.commandTest == .running)
		#expect(setup.problem == nil)
		#expect(!setup.hasProblem)
		#expect(!setup.isComplete)
		_ = try await sandbox.token()
	}

	@Test func undecidedNotificationsAreNoProblem() async throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		sandbox.notificationsAllowed = nil
		try sandbox.writeHooks([sandbox.command])
		let setup = sandbox.makeSetup()
		setup.listenerError = .some(nil)
		setup.refresh()
		setup.selfTestReceived(token: try await sandbox.token())
		#expect(setup.problem == nil)
		#expect(!setup.hasProblem)
		#expect(!setup.isComplete)
	}
}

@Suite struct CheckStatusTests {
	@Test(arguments: [
		(CheckStatus.ok, "checkmark.circle.fill"),
		(.waiting, "hourglass.circle"),
		(.failed, "xmark.circle.fill"),
		(.inactive, "circle.dashed"),
	])
	func symbol(status: CheckStatus, expected: String) {
		#expect(status.symbol == expected)
		#expect(NSImage(systemSymbolName: status.symbol, accessibilityDescription: nil) != nil)
	}

	@Test(arguments: [(CheckStatus.ok, Color.green), (.waiting, .orange), (.failed, .red), (.inactive, .secondary)])
	func color(status: CheckStatus, expected: Color) {
		#expect(status.color == expected)
	}
}

/// Renders the views without a window. The setups in these tests do not listen or have no command, so a refresh
/// from the timer of ``SetupView`` starts no command.
@MainActor @Suite struct SetupViewTests {
	@Test(arguments: [CheckStatus.ok, .waiting, .failed, .inactive])
	func checkRowRenders(status: CheckStatus) {
		let row = CheckRow(status: status, title: "Title", detail: "Detail")
		#expect(row.status == status && row.title == "Title" && row.detail == "Detail")
		#expect(ImageRenderer(content: row).nsImage != nil)
	}

	@Test func setupViewRendersANewSetup() throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		let image = ImageRenderer(content: SetupView().environmentObject(sandbox.makeSetup())).nsImage
		#expect(image?.size.width == 600)
	}

	@Test(arguments: [
		"not json",
		#"{"disableAllHooks": true}"#,
		#"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "curl http://127.0.0.1:1234/event"}]}]}}"#,
	])
	func setupViewRendersBrokenSettings(text: String) async throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		sandbox.notificationsAllowed = false
		try text.write(to: sandbox.settingsURL, atomically: true, encoding: .utf8)
		let setup = sandbox.makeSetup()
		setup.listenerError = .some("Port in use")
		setup.refresh()
		#expect(await waitUntil { setup.notificationsAllowed == false })
		#expect(ImageRenderer(content: SetupView().environmentObject(setup)).nsImage != nil)
	}

	@Test func setupViewRendersAPassedSetup() async throws {
		let sandbox = try Sandbox()
		defer { sandbox.remove() }
		try sandbox.writeHooks([sandbox.command])
		let setup = sandbox.makeSetup()
		setup.refresh()
		setup.runCommandTest()
		setup.selfTestReceived(token: try await sandbox.token())
		#expect(await waitUntil { setup.notificationsAllowed == true })
		#expect(ImageRenderer(content: SetupView().environmentObject(setup)).nsImage != nil)
	}
}
