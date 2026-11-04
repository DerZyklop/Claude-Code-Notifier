import AppKit
import UserNotifications

enum SettingsKey {
	/// Turns the notifications off.
	static let muted = "muted"
	/// Turns every sound of the app on or off.
	static let playsSound = "playsSound"
	/// Updates the morning overview on each weekday, see ``Report/runIfDue()``.
	static let updatesMorningOverview = "updatesMorningOverview"
	/// Updates DiDi on each Tuesday, see ``Report/runIfDue()``.
	static let updatesDiDi = "updatesDiDi"
	/// Keeps the sound off while a light shows the state, see ``SoundMode``.
	static let mutesSoundWithLights = "mutesSoundWithLights"
	/// Lets the blink(1) show the state, see ``Blink1``.
	static let usesBlink1 = "usesBlink1"
	/// Lets the blink(1) blink when a session or a report ends, see ``Blink1/pulse(_:)``.
	static let blinksAtEnd = "blinksAtEnd"
	/// Lets the NuPhy keyboard show the state, see ``KeyboardLight``.
	static let usesKeyboard = "usesKeyboard"
	/// Lets the letter keys of the NuPhy keyboard show the sessions, see ``KeyboardLight/shownSessions(_:at:)``.
	static let showsSessionsOnKeyboard = "showsSessionsOnKeyboard"
	/// Lets the backlight of the MacBook keyboard blink while sessions work, see ``MacBookBacklight``.
	static let usesMacBookBacklight = "usesMacBookBacklight"
	/// The value of each setting while the user has not changed it. Only other values are stored.
	static let defaultValues = [muted: false, playsSound: true, updatesMorningOverview: true, updatesDiDi: true,
		mutesSoundWithLights: false, usesBlink1: true, blinksAtEnd: true, usesKeyboard: true, showsSessionsOnKeyboard: true,
		usesMacBookBacklight: true]

	static func isOn(_ key: String, in defaults: UserDefaults = .standard) -> Bool {
		defaults.object(forKey: key) as? Bool ?? defaultValues[key] ?? false
	}

	/// Only a changed setting is stored, so that the app has no settings file while the user changes nothing.
	static func set(_ key: String, to value: Bool, in defaults: UserDefaults = .standard) {
		if value == defaultValues[key] ?? false { defaults.removeObject(forKey: key) } else { defaults.set(value, forKey: key) }
	}
}

enum SessionState: Int {
	case asksYou, yourTurn, working

	/// The place in the card: sessions that ask you on top, then the working ones, then the finished ones.
	var listOrder: Int {
		switch self {
		case .asksYou: 0
		case .working: 1
		case .yourTurn: 2
		}
	}

	var title: String {
		switch self {
		case .asksYou: "asks you"
		case .yourTurn: "your turn"
		case .working: "working"
		}
	}

	var symbol: String {
		switch self {
		case .asksYou: "questionmark.bubble.fill"
		case .yourTurn: "checkmark.circle.fill"
		case .working: "hourglass"
		}
	}
}

/// The situations that send a notification. Each has its own subtitle.
enum NotificationKind: CaseIterable {
	/// Claude waits for an answer within its turn: a permission, a question or a plan approval.
	case asksYou
	/// Claude has finished its turn, and the prompt is open for the next message.
	case yourTurn

	var subtitle: String {
		switch self {
		case .asksYou: "Claude asks you"
		case .yourTurn: "Your turn"
		}
	}

	var testBody: String {
		switch self {
		case .asksYou: "Claude needs your permission to use Bash."
		case .yourTurn: "Claude has finished. This is how its last message shows up here."
		}
	}
}

struct Session: Identifiable, Equatable {
	let id: String
	/// The working directory of the first event, for the project name. Claude can `cd` later.
	let cwd: String?
	/// When the session started: the first entry of its transcript, see ``SessionTitle/start(transcript:)``. Without
	/// a transcript, the start of its Claude Code process, or when the app saw it first.
	var started: Date
	var state: SessionState
	var updated: Date
	/// The transcript of the session, see ``SessionStore/checkSessions()``.
	var transcriptPath: String?
	/// The title that the Claude Code extension shows, see ``SessionTitle``.
	var title: String?
	/// The Claude Code process, once the app found the session file, see ``ClaudeSessionFiles``.
	var pid: Int32?
	/// The shell commands of the session that run now. After the turn, these are commands in the background.
	var shellCommands = 0
	/// The ids of the subagents that run now, from `SubagentStart` to `SubagentStop`. After the turn, these are
	/// subagents in the background.
	var agents: Set<String> = []

	/// Whether the turn is over, but a shell command or a subagent still runs in the background.
	var hasBackgroundTask: Bool { state == .yourTurn && (shellCommands > 0 || !agents.isEmpty) }

	/// The state to show. A session with a background task is working.
	var shownState: SessionState { hasBackgroundTask ? .working : state }

	/// True while the session works or asks you. Only the end of a busy session pulses the light: VS Code ends and
	/// restarts an idle session when you open its tab.
	var isBusy: Bool { shownState == .working || shownState == .asksYou }

	/// The title of ``shownState``, for the tooltip of its icon. A background task names what runs, e.g. »working in
	/// the background: 2 agents, 1 shell command«.
	var stateTitle: String {
		guard hasBackgroundTask else { return state.title }
		let parts = [(agents.count, "agent"), (shellCommands, "shell command")].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
		return "working in the background: " + parts.joined(separator: ", ")
	}

	var project: String {
		guard let cwd else { return "Claude Code" }
		return URL(fileURLWithPath: cwd).lastPathComponent
	}

	/// The title, or the project before the session has one.
	var name: String { title ?? project }
}

/// The Claude tab in the front VS Code window, from the extension in `vscode-extension/`.
struct FocusedTab: Decodable, Equatable {
	/// The label of the tab: the session title, shortened by the Claude Code extension.
	let title: String
	/// The workspace folders of the window.
	let folders: [String]

	/// Whether the tab shows the session: the same label, and the session runs in a folder of the window.
	func shows(_ session: Session) -> Bool {
		guard let cwd = session.cwd, folders.contains(where: { cwd == $0 || cwd.hasPrefix($0 + "/") }) else { return false }
		return Self.label(of: session.title) == title
	}

	/// The label of a tab with the title, like the Claude Code extension makes it: at most 25 UTF-16 units.
	static func label(of title: String?) -> String {
		guard let title, !title.isEmpty else { return "Claude Code" }
		let units = Array(title.utf16)
		return units.count > 25 ? String(decoding: units.prefix(24), as: UTF16.self) + "…" : title
	}
}

/// The message of the VS Code extension. `tab` is `nil` while VS Code is in the background or shows no Claude tab.
private struct TabFocusEvent: Decodable {
	static let name = "TabFocus"

	let hook_event_name: String
	let tab: FocusedTab?
}

/// The fields of the hook input that this app uses.
struct HookEvent: Decodable {
	let hook_event_name: String
	let session_id: String
	let cwd: String?
	let message: String?
	let notification_type: String?
	let tool_name: String?
	let last_assistant_message: String?
	let reason: String?
	let transcript_path: String?
	let error: String?
	/// The subagent of a `SubagentStart` or `SubagentStop`.
	let agent_id: String?

	/// Claude Code also sends a `Notification` when it waits for input for a while after it finished.
	var isIdleReminder: Bool {
		notification_type == "idle_prompt" || (message?.localizedCaseInsensitiveContains("waiting for your input") ?? false)
	}
}

@MainActor
final class SessionStore: ObservableObject {
	/// The parts of the system that the store reads and changes. Tests replace them.
	struct System {
		var runningSessions: () -> [RunningSession]
		var archivedSessionIDs: () -> Set<String>?
		var shellCommandCounts: (Set<Int32>) -> [Int32: Int]
		var addNotification: (UNNotificationRequest) -> Void
		var removeNotifications: ([String]) -> Void
		var sessionEnded: @MainActor () -> Void
		var defaults: UserDefaults

		static let live = System(
			runningSessions: { ClaudeSessionFiles.running() },
			archivedSessionIDs: { VSCodeArchive.sessionIDs() },
			shellCommandCounts: { ClaudeSessionFiles.shellCommandCounts(of: $0) },
			addNotification: { UNUserNotificationCenter.current().add($0) },
			removeNotifications: { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: $0) },
			sessionEnded: { Blink1.shared.pulse(Spinner.color) },
			defaults: .standard
		)
	}

	static let shared = SessionStore(system: .live, setup: .shared, checksSessions: true)

	@Published private(set) var sessions: [String: Session] = [:] {
		didSet {
			let kept = hiddenStates.filter { sessions[$0.key]?.shownState == $0.value }
			if kept.count != hiddenStates.count { hiddenStates = kept }
			updateLetters()
			projectOrder = Self.projectOrder(keeping: projectOrder, for: sessions.values)
		}
	}
	/// The order of the projects on the card. When the app starts, the last used project is first. A project keeps its
	/// place, and a new project comes last.
	private(set) var projectOrder: [String] = []
	/// The sessions that the user removed from the card, with their shown state at that time. A session comes back
	/// when its shown state changes.
	@Published private(set) var hiddenStates: [String: SessionState] = [:] {
		didSet { updateLetters() }
	}
	/// The letter key of each session on the keyboard, as an index in ``NuPhyKeyboard/letterKeys``. A session keeps its
	/// letter while it is on the card, also when it ends, because VS Code ends and restarts an idle session when you
	/// open its tab.
	@Published private(set) var letters: [String: Int] = [:]
	/// The Claude tab that the user looks at. Its session gets no notification.
	private(set) var focusedTab: FocusedTab?

	private let system: System
	private let setup: HookSetup

	/// - Parameter checksSessions: Calls ``checkSessions()`` now and every 3 s.
	init(system: System, setup: HookSetup, checksSessions: Bool) {
		self.system = system
		self.setup = setup
		guard checksSessions else { return }
		Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
			Task { @MainActor in self?.checkSessions() }
		}
		// Shows the sessions that run already when the app starts.
		checkSessions()
		projectOrder = Self.projectOrder(keeping: [], for: sessions.values)
	}

	/// The sessions of the card, without the hidden ones.
	var sortedSessions: [Session] {
		sessions.values.filter { hiddenStates[$0.id] == nil }.sorted { ($0.shownState.listOrder, $1.updated) < ($1.shownState.listOrder, $0.updated) }
	}

	/// `old`, then the new projects of `sessions`, the last used one first.
	static func projectOrder(keeping old: [String], for sessions: some Collection<Session>) -> [String] {
		var order = old
		for session in sessions.sorted(by: { $0.updated > $1.updated }) where !order.contains(session.project) {
			order.append(session.project)
		}
		return order
	}

	/// The letters of `old` for the sessions that are still in `ids`. Each new session in `ids` gets the first free one of
	/// `count` letters, in the order of `ids`. Without a free letter, a session gets none.
	static func letters(keeping old: [String: Int], for ids: [String], count: Int) -> [String: Int] {
		var letters = old.filter { ids.contains($0.key) }
		for id in ids where letters[id] == nil {
			let used = Set(letters.values)
			guard let free = (0..<count).first(where: { !used.contains($0) }) else { break }
			letters[id] = free
		}
		return letters
	}

	private func updateLetters() {
		// A new chat gets its letter with the first prompt.
		let ids = sortedSessions.filter { letters[$0.id] != nil || $0.title != nil || $0.isBusy }.map(\.id)
		let letters = Self.letters(keeping: letters, for: ids, count: NuPhyKeyboard.letterKeys.count)
		if letters != self.letters { self.letters = letters }
	}

	func handle(_ data: Data) {
		if let event = try? JSONDecoder().decode(TabFocusEvent.self, from: data), event.hook_event_name == TabFocusEvent.name {
			focus(event.tab)
			return
		}
		guard let event = try? JSONDecoder().decode(HookEvent.self, from: data) else { return }
		if event.hook_event_name == HookSetup.selfTestEventName {
			setup.selfTestReceived(token: event.session_id)
			return
		}
		setup.claudeEventReceived()
		let id = event.session_id
		let previous = sessions[id]

		switch event.hook_event_name {
		case "SessionStart":
			set(.yourTurn, for: event, previous: previous)
		case "UserPromptSubmit", "PostToolUse":
			set(.working, for: event, previous: previous)
			removeNotification(of: id)
		case "PreToolUse":
			// The hook matches only the tools that wait for the user. Their permission prompt follows 6 s later.
			let body = switch event.tool_name {
			case "AskUserQuestion": "Claude has a question for you."
			case "ExitPlanMode": "Claude wants you to approve the plan."
			default: nil as String?
			}
			guard let body else { return }
			let session = set(.asksYou, for: event, previous: previous)
			notify(.asksYou, session: session, body: body)
		case "Notification" where event.isIdleReminder:
			if previous?.state == .yourTurn || previous?.state == .asksYou { return }
			let session = set(.yourTurn, for: event, previous: previous)
			notify(.yourTurn, session: session, body: event.message ?? "Claude is waiting for your input.")
		case "Notification":
			// A question or a plan reported this wait already.
			if previous?.state == .asksYou { return }
			let session = set(.asksYou, for: event, previous: previous)
			notify(.asksYou, session: session, body: event.message ?? "Claude needs your input.")
		case "Stop":
			let session = set(.yourTurn, for: event, previous: previous)
			notify(.yourTurn, session: session, body: Self.preview(of: event.last_assistant_message) ?? "Claude has finished.")
		case "StopFailure":
			let session = set(.yourTurn, for: event, previous: previous)
			notify(.yourTurn, session: session, body: "Claude stopped because of an error: \(event.error ?? "unknown").")
		case "SubagentStart":
			set(.working, for: event, previous: previous)
			removeNotification(of: id)
			if let agent = event.agent_id { sessions[id]?.agents.insert(agent) }
		case "SubagentStop":
			// The state stays: Claude can still work, or its turn is over and other subagents run in the background.
			guard let agent = event.agent_id, previous?.agents.contains(agent) == true else { return }
			sessions[id]?.agents.remove(agent)
		case "SessionEnd":
			// No notification: the user closes the session, and it leaves the card. `/clear` ends it too, but only to
			// start the next one at once, so it does not pulse.
			sessions[id] = nil
			removeNotification(of: id)
			if event.reason != "clear", previous?.isBusy == true { system.sessionEnded() }
		default:
			return
		}
	}

	/// Closes the notifications of the sessions that the tab shows.
	func focus(_ tab: FocusedTab?) {
		focusedTab = tab
		guard let tab else { return }
		let ids = sessions.values.filter(tab.shows).map(\.id)
		if !ids.isEmpty { system.removeNotifications(ids) }
	}

	/// Removes the session from the card until its shown state changes.
	func hide(_ id: String) {
		hiddenStates[id] = sessions[id]?.shownState
	}

	/// Sends a notification of the given kind, also while the notifications are muted.
	func sendTestNotification(_ kind: NotificationKind) {
		post(kind, title: "Test notification", body: kind.testBody, identifier: "test-\(kind)")
	}

	@discardableResult
	func set(_ state: SessionState, for event: HookEvent, previous: Session?) -> Session {
		let transcriptPath = event.transcript_path ?? previous?.transcriptPath
		// The title changes with a new prompt or turn at most, so a tool call does not read the transcript again.
		var title = previous?.title
		if title == nil || event.hook_event_name != "PostToolUse", let transcriptPath {
			title = SessionTitle.read(transcript: transcriptPath) ?? title
		}
		let session = Session(id: event.session_id, cwd: previous?.cwd ?? event.cwd, started: previous?.started ?? transcriptPath.flatMap(SessionTitle.start) ?? Date(), state: state, updated: Date(), transcriptPath: transcriptPath, title: title, pid: previous?.pid, agents: previous?.agents ?? [])
		sessions[session.id] = session
		return session
	}

	/// Finds the changes that Claude Code reports with no hook.
	///
	/// - Session files: the sessions that run already, and the status of sessions without hooks, see
	///   ``syncWithSessionFiles(archived:)``.
	/// - Interrupt: Claude Code only writes a marker into the transcript, so the sessions that still work or ask are
	///   checked for it.
	/// - Archive: the user can archive a session in VS Code while it runs or after it ended, see ``VSCodeArchive``.
	///   It leaves the menu.
	func checkSessions() {
		let archived = system.archivedSessionIDs()
		syncWithSessionFiles(archived: archived ?? [])

		for session in sessions.values where session.state == .working || session.state == .asksYou {
			guard let path = session.transcriptPath, Self.endsWithInterrupt(transcript: path) else { continue }
			sessions[session.id]?.state = .yourTurn
			sessions[session.id]?.updated = Date()
			// The interrupt stops the subagents too, maybe with no `SubagentStop`.
			sessions[session.id]?.agents = []
			removeNotification(of: session.id)
		}

		guard let archived else { return }
		for id in sessions.keys where archived.contains(id) {
			sessions[id] = nil
			removeNotification(of: id)
		}
	}

	/// Adds the running sessions that the app does not know yet, e.g. the ones that started before the app. Follows the
	/// status that Claude Code writes for each process, which matters for sessions without hooks. Sends no
	/// notification: those come from the hooks.
	func syncWithSessionFiles(archived: Set<String>) {
		let running = system.runningSessions().filter { !archived.contains($0.sessionID) }
		for process in running {
			let previous = sessions[process.sessionID]
			var session = previous ?? Session(id: process.sessionID, cwd: process.cwd, started: SessionTitle.start(transcript: process.transcriptPath) ?? process.started,
				state: process.state ?? .yourTurn, updated: process.stateChanged, transcriptPath: process.transcriptPath,
				title: SessionTitle.read(transcript: process.transcriptPath))
			// VS Code restarts the process of a session now and then, so the process can start later than the session.
			session.started = min(session.started, process.started)
			session.pid = process.pid
			// The file wins only when it is newer than the last hook event, because a hook comes faster.
			if let state = process.state, state != session.state, process.stateChanged > session.updated.addingTimeInterval(1) {
				session.state = state
				session.updated = process.stateChanged
				session.title = session.transcriptPath.flatMap(SessionTitle.read) ?? session.title
				if state == .working { removeNotification(of: session.id) }
			}
			if session != previous { sessions[session.id] = session }
		}

		// The process scan takes some milliseconds, so it runs off the main thread.
		let pids = Set(running.map(\.pid))
		let shellCommandCounts = system.shellCommandCounts
		Task.detached(priority: .utility) {
			let commands = shellCommandCounts(pids)
			await self.apply(shellCommands: commands)
		}

		// A process that ended without a `SessionEnd` hook, e.g. in a session that started before the hooks.
		let runningIDs = Set(running.map(\.sessionID))
		for (id, session) in sessions where session.pid != nil && !runningIDs.contains(id) {
			sessions[id] = nil
			removeNotification(of: id)
			if session.isBusy { system.sessionEnded() }
		}
	}

	func apply(shellCommands commands: [Int32: Int]) {
		for (id, session) in sessions {
			let count = session.pid.flatMap { commands[$0] } ?? 0
			if session.shellCommands != count { sessions[id]?.shellCommands = count }
		}
	}

	/// Whether the last message in the transcript is the interrupt marker. Reads only the end of the file, and skips
	/// the metadata lines that Claude Code writes after a message.
	static func endsWithInterrupt(transcript path: String) -> Bool {
		guard let handle = FileHandle.regularFile(atPath: path) else { return false }
		defer { try? handle.close() }
		guard let end = try? handle.seekToEnd() else { return false }
		try? handle.seek(toOffset: end > 65_536 ? end - 65_536 : 0)
		guard let data = try? handle.read(upToCount: 65_536) else { return false }

		for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
			guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return false }
			switch json["type"] as? String {
			case "assistant": return false
			case "user": return String(decoding: line, as: UTF8.self).contains("[Request interrupted by user")
			default: continue
			}
		}
		return false
	}

	func notify(_ kind: NotificationKind, session: Session, body: String) {
		if system.defaults.bool(forKey: SettingsKey.muted) || focusedTab?.shows(session) == true { return }
		// One notification per session: a new one replaces the old one.
		post(kind, title: session.name, body: body, identifier: session.id)
	}

	func post(_ kind: NotificationKind, title: String, body: String, identifier: String) {
		post(subtitle: kind.subtitle, title: title, body: body, identifier: identifier)
	}

	func post(subtitle: String, title: String, body: String, identifier: String) {
		let content = UNMutableNotificationContent()
		content.title = title
		content.subtitle = subtitle
		// No sound: the chime of the bubble is the only sound of the app, see ``AttentionBubble``.
		content.body = body
		// No thread identifier: macOS then stacks all notifications of the app in one group.
		system.addNotification(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
	}

	func removeNotification(of sessionID: String) {
		system.removeNotifications([sessionID])
	}

	/// The start of Claude's last message, in one line, or `nil` if there is none.
	static func preview(of message: String?) -> String? {
		guard let message else { return nil }
		let line = message.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
		if line.isEmpty { return nil }
		return line.count > 180 ? line.prefix(180) + "…" : line
	}
}
