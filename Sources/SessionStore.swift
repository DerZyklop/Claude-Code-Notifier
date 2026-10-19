import Foundation
import UserNotifications

enum SettingsKey {
	static let notifyOnDone = "notifyOnDone"
	static let muted = "muted"
	static let playsSound = "playsSound"
	static let notifyOnSessionEnd = "notifyOnSessionEnd"
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
		case .yourTurn: "checkmark.circle"
		case .working: "hourglass"
		case .ended: "stop.circle"
		}
	}
}

/// The situations that send a notification. Each has its own subtitle and sound.
enum NotificationKind: CaseIterable {
	/// Claude waits for an answer within its turn: a permission, a question or a plan approval.
	case asksYou
	/// Claude has finished its turn, and the prompt is open for the next message.
	case yourTurn
	/// The session is closed.
	case sessionEnded

	var subtitle: String {
		switch self {
		case .asksYou: "Claude asks you"
		case .yourTurn: "Your turn"
		case .sessionEnded: "Session ended"
		}
	}

	/// A macOS sound that `build.sh` copies into the app bundle.
	var sound: UNNotificationSoundName {
		switch self {
		case .asksYou: UNNotificationSoundName("Purr.aiff")
		case .yourTurn: UNNotificationSoundName("Bottle.aiff")
		case .sessionEnded: UNNotificationSoundName("Pop.aiff")
		}
	}

	var testBody: String {
		switch self {
		case .asksYou: "Claude needs your permission to use Bash."
		case .yourTurn: "Claude has finished. This is how its last message shows up here."
		case .sessionEnded: "The session was closed."
		}
	}
}

struct Session: Identifiable {
	let id: String
	/// The working directory of the first event, for the project name. Claude can `cd` later.
	let cwd: String?
	/// When the app saw the session first: its start, unless the app started later.
	let started: Date
	var state: SessionState
	var updated: Date
	/// The transcript of the session, see ``SessionStore/checkSessions()``.
	var transcriptPath: String?

	var project: String {
		guard let cwd else { return "Claude Code" }
		return URL(fileURLWithPath: cwd).lastPathComponent
	}
}

/// The fields of the hook input that this app uses.
private struct HookEvent: Decodable {
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
	static let shared = SessionStore()

	@Published private(set) var sessions: [String: Session] = [:]

	private var interruptTimer: Timer?

	private init() {
		interruptTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
			Task { @MainActor in self?.checkSessions() }
		}
	}

	var sortedSessions: [Session] {
		sessions.values.sorted { ($0.state.rawValue, $1.updated) < ($1.state.rawValue, $0.updated) }
	}

	func handle(_ data: Data) {
		guard let event = try? JSONDecoder().decode(HookEvent.self, from: data) else { return }
		if event.hook_event_name == HookSetup.selfTestEventName {
			HookSetup.shared.selfTestReceived(token: event.session_id)
			return
		}
		HookSetup.shared.claudeEventReceived()
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
			if UserDefaults.standard.object(forKey: SettingsKey.notifyOnDone) as? Bool ?? true {
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
			set(.ended, for: event, previous: previous)
			removeNotification(of: id)
			// An archived session leaves the menu without a notification: the user archived it. VS Code writes the
			// archive list with a short delay, so the check waits for it.
			Task {
				try? await Task.sleep(nanoseconds: 2_000_000_000)
				guard let session = sessions[id], session.state == .ended else { return }
				if VSCodeArchive.sessionIDs()?.contains(id) == true {
					sessions[id] = nil
				} else if UserDefaults.standard.object(forKey: SettingsKey.notifyOnSessionEnd) as? Bool ?? true {
					notify(.sessionEnded, session: session, body: "The session was closed.")
				}
			}
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
	private func set(_ state: SessionState, for event: HookEvent, previous: Session?) -> Session {
		let session = Session(id: event.session_id, cwd: previous?.cwd ?? event.cwd, started: previous?.started ?? Date(), state: state, updated: Date(), transcriptPath: event.transcript_path ?? previous?.transcriptPath)
		sessions[session.id] = session
		return session
	}

	/// Finds the changes that Claude Code reports with no hook.
	///
	/// - Interrupt: Claude Code only writes a marker into the transcript, so the sessions that still work or ask are
	///   checked for it.
	/// - Archive: the user can archive a session in VS Code while it runs or after it ended, see ``VSCodeArchive``.
	///   It leaves the menu.
	func checkSessions() {
		for session in sessions.values where session.state == .working || session.state == .asksYou {
			guard let path = session.transcriptPath, Self.endsWithInterrupt(transcript: path) else { continue }
			sessions[session.id]?.state = .yourTurn
			sessions[session.id]?.updated = Date()
			removeNotification(of: session.id)
		}

		guard !sessions.isEmpty, let archived = VSCodeArchive.sessionIDs() else { return }
		for id in sessions.keys where archived.contains(id) {
			sessions[id] = nil
			removeNotification(of: id)
		}
	}

	/// Whether the last message in the transcript is the interrupt marker. Reads only the end of the file, and skips
	/// the metadata lines that Claude Code writes after a message.
	private static func endsWithInterrupt(transcript path: String) -> Bool {
		guard let handle = FileHandle(forReadingAtPath: path) else { return false }
		defer { try? handle.close() }
		guard let end = try? handle.seekToEnd() else { return false }
		try? handle.seek(toOffset: end > 65_536 ? end - 65_536 : 0)
		guard let data = try? handle.readToEnd() else { return false }

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

	private func notify(_ kind: NotificationKind, session: Session, body: String) {
		if UserDefaults.standard.bool(forKey: SettingsKey.muted) { return }
		// One notification per session: a new one replaces the old one.
		post(kind, title: session.project, body: body, identifier: session.id)
	}

	private func post(_ kind: NotificationKind, title: String, body: String, identifier: String) {
		let content = UNMutableNotificationContent()
		content.title = title
		content.subtitle = kind.subtitle
		content.body = body
		if UserDefaults.standard.object(forKey: SettingsKey.playsSound) as? Bool ?? true {
			content.sound = UNNotificationSound(named: kind.sound)
		}
		content.threadIdentifier = identifier
		UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
	}

	private func removeNotification(of sessionID: String) {
		UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [sessionID])
	}

	/// The start of Claude's last message, in one line, or `nil` if there is none.
	private static func preview(of message: String?) -> String? {
		guard let message else { return nil }
		let line = message.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
		if line.isEmpty { return nil }
		return line.count > 180 ? line.prefix(180) + "…" : line
	}
}
