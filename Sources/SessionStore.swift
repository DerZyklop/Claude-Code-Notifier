import Foundation
import UserNotifications

enum SettingsKey {
	static let notifyOnDone = "notifyOnDone"
	static let muted = "muted"
	static let playsSound = "playsSound"
	/// The value of each setting while the user has not changed it. Only other values are stored.
	static let defaultValues = [notifyOnDone: true, muted: false, playsSound: true]
}

enum SessionState: Int {
	case asksYou, yourTurn, working, ended

	var title: String {
		switch self {
		case .asksYou: "asks you"
		case .yourTurn: "your turn"
		case .working: "working"
		case .ended: "ended"
		}
	}

	var symbol: String {
		switch self {
		case .asksYou: "questionmark.bubble.fill"
		case .yourTurn: "checkmark.circle.fill"
		case .working: "hourglass"
		case .ended: "stop.circle.fill"
		}
	}
}

/// The situations that send a notification. Each has its own subtitle and sound.
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

	/// A macOS sound that `build.sh` copies into the app bundle.
	var sound: UNNotificationSoundName {
		switch self {
		case .asksYou: UNNotificationSoundName("Purr.aiff")
		case .yourTurn: UNNotificationSoundName("Bottle.aiff")
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

	/// Whether the turn is over, but a shell command still runs in the background.
	var hasBackgroundTask: Bool { state == .yourTurn && shellCommands > 0 }

	/// The state to show. A session with a background task is working.
	var shownState: SessionState { hasBackgroundTask ? .working : state }

	/// The title of ``shownState``, for the tooltip of its icon.
	var stateTitle: String { hasBackgroundTask ? "working in the background" : state.title }

	var project: String {
		guard let cwd else { return "Claude Code" }
		return URL(fileURLWithPath: cwd).lastPathComponent
	}

	/// The title, or the project before the session has one.
	var name: String { title ?? project }
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
		var defaults: UserDefaults

		static let live = System(
			runningSessions: { ClaudeSessionFiles.running() },
			archivedSessionIDs: { VSCodeArchive.sessionIDs() },
			shellCommandCounts: { ClaudeSessionFiles.shellCommandCounts(of: $0) },
			addNotification: { UNUserNotificationCenter.current().add($0) },
			removeNotifications: { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: $0) },
			defaults: .standard
		)
	}

	static let shared = SessionStore(system: .live, setup: .shared, checksSessions: true)

	@Published private(set) var sessions: [String: Session] = [:]

	private let system: System
	private let setup: HookSetup
	private var interruptTimer: Timer?

	/// - Parameter checksSessions: Calls ``checkSessions()`` now and every 3 s.
	init(system: System, setup: HookSetup, checksSessions: Bool) {
		self.system = system
		self.setup = setup
		guard checksSessions else { return }
		interruptTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
			Task { @MainActor in self?.checkSessions() }
		}
		// Shows the sessions that run already when the app starts.
		checkSessions()
	}

	var sortedSessions: [Session] {
		sessions.values.sorted { ($0.shownState.rawValue, $1.updated) < ($1.shownState.rawValue, $0.updated) }
	}

	func handle(_ data: Data) {
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
		case "Notification":
			if event.isIdleReminder {
				if previous?.state == .yourTurn || previous?.state == .asksYou { return }
				let session = set(.yourTurn, for: event, previous: previous)
				notify(.yourTurn, session: session, body: event.message ?? "Claude is waiting for your input.")
				return
			}
			// A question or a plan reported this wait already.
			if previous?.state == .asksYou { return }
			let session = set(.asksYou, for: event, previous: previous)
			notify(.asksYou, session: session, body: event.message ?? "Claude needs your input.")
		case "Stop":
			let session = set(.yourTurn, for: event, previous: previous)
			if system.defaults.object(forKey: SettingsKey.notifyOnDone) as? Bool ?? true {
				notify(.yourTurn, session: session, body: Self.preview(of: event.last_assistant_message) ?? "Claude has finished.")
			}
		case "StopFailure":
			let session = set(.yourTurn, for: event, previous: previous)
			notify(.yourTurn, session: session, body: "Claude stopped because of an error: \(event.error ?? "unknown").")
		case "SessionEnd":
			// `/clear` ends the session too, but only to start the next one at once.
			if event.reason == "clear" {
				sessions[id] = nil
				removeNotification(of: id)
				return
			}
			// No notification: the user closes a session. An archived one leaves the menu with the next check.
			set(.ended, for: event, previous: previous)
			removeNotification(of: id)
		default:
			return
		}
	}

	func removeEnded() {
		sessions = sessions.filter { $0.value.state != .ended }
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
		let session = Session(id: event.session_id, cwd: previous?.cwd ?? event.cwd, started: previous?.started ?? transcriptPath.flatMap(SessionTitle.start) ?? Date(), state: state, updated: Date(), transcriptPath: transcriptPath, title: title, pid: previous?.pid)
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
			if let state = process.state, state != session.state, session.state != .ended, process.stateChanged > session.updated.addingTimeInterval(1) {
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
			await MainActor.run { self.apply(shellCommands: commands) }
		}

		// A process that ended without a `SessionEnd` hook, e.g. in a session that started before the hooks.
		let runningIDs = Set(running.map(\.sessionID))
		for (id, session) in sessions where session.pid != nil && session.state != .ended && !runningIDs.contains(id) {
			sessions[id]?.state = .ended
			sessions[id]?.updated = Date()
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
		if system.defaults.bool(forKey: SettingsKey.muted) { return }
		// One notification per session: a new one replaces the old one.
		post(kind, title: session.name, body: body, identifier: session.id)
	}

	func post(_ kind: NotificationKind, title: String, body: String, identifier: String) {
		let content = UNMutableNotificationContent()
		content.title = title
		content.subtitle = kind.subtitle
		content.body = body
		if system.defaults.object(forKey: SettingsKey.playsSound) as? Bool ?? true {
			content.sound = UNNotificationSound(named: kind.sound)
		}
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
