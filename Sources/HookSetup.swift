import AppKit
import SwiftUI
import UserNotifications

/// The local port the Claude Code hooks send their events to.
let eventPort: UInt16 = 47823

/// The hook command. It sends the hook's JSON from stdin to the app and never fails or blocks Claude Code for long.
let hookCommand = "curl -s -m 1 -H 'X-Claude-Hook: 1' --data-binary @- http://127.0.0.1:\(eventPort)/event >/dev/null 2>&1 || true"

/// The hook events the app needs, see ``SessionStore/handle(_:)``, each with the matcher its hook needs.
let requiredHooks: [(event: String, matcher: String?)] = [
	("SessionStart", nil),
	("UserPromptSubmit", nil),
	("PreToolUse", "AskUserQuestion|ExitPlanMode"),
	("PostToolUse", nil),
	("Notification", nil),
	("Stop", nil),
	("StopFailure", nil),
	("SessionEnd", nil),
]

let requiredHookEvents = requiredHooks.map(\.event)

/// The settings for the given events: a `hooks` block for `~/.claude/settings.json`, or the whole file.
func hookSettingsJSON(for events: [String], asFile: Bool) -> String {
	let entries = requiredHooks.filter { events.contains($0.event) }.map { hook in
		let matcher = hook.matcher.map { "\"matcher\": \"\($0)\", " } ?? ""
		return "    \"\(hook.event)\": [{ \(matcher)\"hooks\": [{ \"type\": \"command\", \"command\": \"\(hookCommand)\" }] }]"
	}
	let block = "\"hooks\": {\n" + entries.joined(separator: ",\n") + "\n}"
	return asFile ? "{\n" + block.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n") + "\n}" : block
}

/// The user settings of Claude Code. Like Claude Code, it honors `CLAUDE_CONFIG_DIR`.
let claudeSettingsURL: URL = {
	let configDirectory = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
		?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
	return configDirectory.appendingPathComponent("settings.json")
}()

enum SettingsCheck: Equatable {
	case fileMissing
	case unreadable(String)
	case hooksDisabled
	/// Lists the events without a hook that sends to this app, and the distinct commands of the hooks that do.
	case found(missingEvents: [String], commands: [String])
}

enum CommandTest: Equatable {
	case notRun, running, passed
	case failed(String)
}

/// Checks that the Claude Code hooks are set up and reach this app.
@MainActor
final class HookSetup: ObservableObject {
	static let shared = HookSetup()

	/// The `hook_event_name` of the test event that ``runCommandTest()`` sends through the configured command.
	static let selfTestEventName = "NotifierSelfTest"

	private static let lastClaudeEventKey = "lastClaudeEvent"

	/// `nil` until the server reports its state.
	@Published var listenerError: String??
	@Published private(set) var settings: SettingsCheck = .fileMissing
	@Published private(set) var commandTest: CommandTest = .notRun
	@Published private(set) var lastClaudeEvent = UserDefaults.standard.object(forKey: lastClaudeEventKey) as? Date
	/// Whether macOS shows the notifications of this app. `nil` while the user has not decided yet.
	@Published private(set) var notificationsAllowed: Bool?

	private var testToken: String?

	var isListening: Bool { listenerError == .some(nil) }

	var hooksConfigured: Bool {
		if case .found(let missing, _) = settings { return missing.isEmpty }
		return false
	}

	var isComplete: Bool { isListening && hooksConfigured && commandTest == .passed && notificationsAllowed == true }

	/// Reads the settings again. Tests the hook command once it is configured and has not passed yet.
	func refresh() {
		UNUserNotificationCenter.current().getNotificationSettings { settings in
			let allowed: Bool? = switch settings.authorizationStatus {
			case .authorized, .provisional, .ephemeral: true
			case .denied: false
			case .notDetermined: nil
			@unknown default: nil
			}
			Task { @MainActor in self.notificationsAllowed = allowed }
		}

		let previous = settings
		settings = Self.checkSettings()
		guard isListening, case .found(_, let commands) = settings, !commands.isEmpty else {
			if !hooksConfigured { commandTest = .notRun }
			return
		}
		if settings != previous || commandTest == .notRun { runCommandTest() }
	}

	/// Runs each configured hook command with a test event, the way Claude Code runs it, and waits for the event.
	func runCommandTest() {
		guard case .found(_, let commands) = settings, !commands.isEmpty else { return }
		let token = UUID().uuidString
		testToken = token
		commandTest = .running

		let payload = Data(#"{"hook_event_name":"\#(Self.selfTestEventName)","session_id":"\#(token)"}"#.utf8)
		for command in commands {
			let process = Process()
			process.executableURL = URL(fileURLWithPath: "/bin/sh")
			process.arguments = ["-c", command]
			let stdin = Pipe()
			process.standardInput = stdin
			process.standardOutput = FileHandle.nullDevice
			process.standardError = FileHandle.nullDevice
			do {
				try process.run()
				stdin.fileHandleForWriting.write(payload)
				try stdin.fileHandleForWriting.close()
			} catch {
				commandTest = .failed("The command could not start: \(error.localizedDescription)")
				return
			}
		}

		Task {
			try? await Task.sleep(nanoseconds: 3_000_000_000)
			if testToken == token && commandTest == .running {
				commandTest = .failed("The command ran, but no event reached the app within 3 s. Check the port and the header »X-Claude-Hook« in the command.")
			}
		}
	}

	func selfTestReceived(token: String) {
		if token == testToken { commandTest = .passed }
	}

	func claudeEventReceived() {
		let now = Date()
		lastClaudeEvent = now
		UserDefaults.standard.set(now, forKey: Self.lastClaudeEventKey)
	}

	private static func checkSettings() -> SettingsCheck {
		guard FileManager.default.fileExists(atPath: claudeSettingsURL.path) else { return .fileMissing }
		let root: [String: Any]
		do {
			let data = try Data(contentsOf: claudeSettingsURL)
			guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
				return .unreadable("The file holds no JSON object.")
			}
			root = object
		} catch {
			return .unreadable(error.localizedDescription)
		}
		if root["disableAllHooks"] as? Bool == true { return .hooksDisabled }

		let hooks = root["hooks"] as? [String: Any] ?? [:]
		var missing: [String] = []
		var commands: [String] = []
		for event in requiredHookEvents {
			let matchers = hooks[event] as? [[String: Any]] ?? []
			let eventCommands = matchers
				.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
				.compactMap { $0["command"] as? String }
				.filter { $0.contains(":\(eventPort)/event") }
			if eventCommands.isEmpty { missing.append(event) }
			for command in eventCommands where !commands.contains(command) { commands.append(command) }
		}
		return .found(missingEvents: missing, commands: commands)
	}
}

/// The setup window. An app without a Dock icon has to bring its window to the front itself.
@MainActor
enum SetupWindow {
	private static var window: NSWindow?

	static func show() {
		if window == nil {
			let hosting = NSHostingController(rootView: SetupView().environmentObject(HookSetup.shared))
			let newWindow = NSWindow(contentViewController: hosting)
			newWindow.title = "Claude Code Notifier Setup"
			newWindow.styleMask = [.titled, .closable]
			newWindow.isReleasedWhenClosed = false
			newWindow.center()
			window = newWindow
		}
		HookSetup.shared.refresh()
		NSApp.activate(ignoringOtherApps: true)
		window?.makeKeyAndOrderFront(nil)
	}

	static func close() {
		window?.close()
	}
}

private enum CheckStatus {
	case ok, waiting, failed, inactive

	var symbol: String {
		switch self {
		case .ok: "checkmark.circle.fill"
		case .waiting: "hourglass.circle"
		case .failed: "xmark.circle.fill"
		case .inactive: "circle.dashed"
		}
	}

	var color: Color {
		switch self {
		case .ok: .green
		case .waiting: .orange
		case .failed: .red
		case .inactive: .secondary
		}
	}
}

private struct CheckRow: View {
	let status: CheckStatus
	let title: String
	let detail: String

	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 10) {
			Image(systemName: status.symbol).foregroundStyle(status.color)
			VStack(alignment: .leading, spacing: 2) {
				Text(title).fontWeight(.medium)
				Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
			}
		}
	}
}

struct SetupView: View {
	@EnvironmentObject private var setup: HookSetup
	private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text("Claude Code Notifier learns about your sessions through Claude Code hooks. These checks make sure that the hooks reach the app.")
				.fixedSize(horizontal: false, vertical: true)

			listenerRow
			notificationsRow
			settingsRow
			commandRow
			claudeRow

			if !setup.hooksConfigured { instructions }

			HStack {
				Text("Send a test notification:")
				ForEach(NotificationKind.allCases, id: \.self) { kind in
					Button("»\(kind.subtitle)«") { SessionStore.shared.sendTestNotification(kind) }
				}
			}
			.disabled(setup.notificationsAllowed != true)

			HStack {
				Text("The checks update by themselves while this window is open.")
					.font(.caption).foregroundStyle(.secondary)
				Spacer()
				Button("Check Again") {
					setup.refresh()
					setup.runCommandTest()
				}
				Button("Done") { SetupWindow.close() }
					.keyboardShortcut(.defaultAction)
			}
		}
		.padding(20)
		.frame(width: 600)
		.onReceive(timer) { _ in setup.refresh() }
	}

	private var listenerRow: some View {
		switch setup.listenerError {
		case .none:
			CheckRow(status: .waiting, title: "App listens for events", detail: "Starting …")
		case .some(.none):
			CheckRow(status: .ok, title: "App listens for events", detail: "On 127.0.0.1:\(String(eventPort)).")
		case .some(.some(let error)):
			CheckRow(status: .failed, title: "App listens for events", detail: "Port \(String(eventPort)) is not available: \(error) Is another copy of the app running?")
		}
	}

	private var notificationsRow: some View {
		let title = "Notifications are allowed"
		return HStack(alignment: .firstTextBaseline) {
			switch setup.notificationsAllowed {
			case .some(true):
				CheckRow(status: .ok, title: title, detail: "macOS shows the notifications of this app.")
			case .some(false):
				CheckRow(status: .failed, title: title, detail: "macOS blocks them. Allow them in System Settings › Notifications › Claude Code Notifier.")
				Spacer()
				Button("Open Notification Settings") {
					NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
				}
			case .none:
				CheckRow(status: .waiting, title: title, detail: "Waiting for your answer in the macOS dialog.")
			}
		}
	}

	private var settingsRow: some View {
		let title = "Hooks in ~/.claude/settings.json"
		switch setup.settings {
		case .fileMissing:
			return CheckRow(status: .failed, title: title, detail: "The file does not exist yet.")
		case .unreadable(let error):
			return CheckRow(status: .failed, title: title, detail: "The file cannot be read: \(error)")
		case .hooksDisabled:
			return CheckRow(status: .failed, title: title, detail: "»disableAllHooks« is on, so Claude Code runs no hooks. Remove it, then add the hooks.")
		case .found(let missing, _):
			if missing.isEmpty {
				return CheckRow(status: .ok, title: title, detail: "All \(requiredHookEvents.count) hooks are there.")
			}
			return CheckRow(status: .failed, title: title, detail: "Missing for: \(missing.joined(separator: ", ")).")
		}
	}

	private var commandRow: some View {
		let title = "Hook command reaches the app"
		switch setup.commandTest {
		case .notRun:
			return CheckRow(status: .inactive, title: title, detail: "Runs once the hooks are there.")
		case .running:
			return CheckRow(status: .waiting, title: title, detail: "Running the command with a test event …")
		case .passed:
			return CheckRow(status: .ok, title: title, detail: "The test event arrived.")
		case .failed(let reason):
			return CheckRow(status: .failed, title: title, detail: reason)
		}
	}

	private var claudeRow: some View {
		let title = "Event from Claude Code"
		if let date = setup.lastClaudeEvent {
			return CheckRow(status: .ok, title: title, detail: "Last event: \(date.formatted(date: .abbreviated, time: .shortened)).")
		}
		return CheckRow(status: setup.hooksConfigured ? .waiting : .inactive, title: title, detail: "Send a prompt in any Claude Code session. Claude Code reads the hooks when a session starts, so restart sessions that were open before you added them.")
	}

	private var instructions: some View {
		let fileMissing = setup.settings == .fileMissing
		let path = (claudeSettingsURL.path as NSString).abbreviatingWithTildeInPath
		var events = requiredHookEvents
		if case .found(let missing, _) = setup.settings { events = missing }
		let snippet = hookSettingsJSON(for: events, asFile: fileMissing)
		return VStack(alignment: .leading, spacing: 8) {
			Text(fileMissing
				? "Create the file \(path) with this content:"
				: "Add the missing hooks to \(path). If the file has a »hooks« block already, add the entries to it. If an event has entries already, add the inner hook to its list.")
				.fixedSize(horizontal: false, vertical: true)
			ScrollView([.vertical, .horizontal]) {
				Text(snippet)
					.font(.system(.caption, design: .monospaced))
					.textSelection(.enabled)
					.padding(8)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
			.frame(height: 150)
			.background(Color(nsColor: .textBackgroundColor))
			.clipShape(RoundedRectangle(cornerRadius: 6))
			HStack {
				Button(fileMissing ? "Copy File Content" : "Copy Hooks") {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(snippet, forType: .string)
				}
				if fileMissing {
					Button("Show Folder in Finder") {
						NSWorkspace.shared.open(claudeSettingsURL.deletingLastPathComponent())
					}
				} else {
					Button("Open settings.json") { openClaudeSettings() }
				}
			}
		}
	}
}

/// Opens `~/.claude/settings.json` in VS Code, or in the default app for JSON files.
@MainActor
private func openClaudeSettings() {
	if let vscode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") {
		NSWorkspace.shared.open([claudeSettingsURL], withApplicationAt: vscode, configuration: NSWorkspace.OpenConfiguration())
	} else {
		NSWorkspace.shared.open(claudeSettingsURL)
	}
}
