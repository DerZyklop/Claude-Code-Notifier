import Combine
import Foundation
import Testing
import UserNotifications
@testable import ClaudeCodeNotifier

private let processStart = Date(timeIntervalSince1970: 1_000_000)

/// The time of ``prompt(_:)``.
private let promptTime = Date(timeIntervalSince1970: 1_792_571_415.25)

private func prompt(_ text: String) -> String {
	#"{"type":"user","timestamp":"2026-10-21T08:30:15.250Z","message":{"role":"user","content":"\#(text)"}}"#
}

private func titleLine(_ title: String) -> String {
	#"{"type":"ai-title","aiTitle":"\#(title)"}"#
}

private let answer = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done."}]}}"#
private let interrupt = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#

/// A Claude Code process. Its transcript path is in the Claude Code folder, under a project that does not exist.
private func process(_ id: String, pid: Int32, state: SessionState? = .yourTurn, started: Date = processStart, changed: Date = processStart) -> RunningSession {
	RunningSession(pid: pid, sessionID: id, cwd: "/nonexistent/\(UUID().uuidString)", started: started, state: state, stateChanged: changed)
}

/// The system in memory. The store calls `shellCommandCounts` on another thread, so a lock guards the state.
private final class FakeSystem: @unchecked Sendable {
	struct State {
		var running: [RunningSession] = []
		var archived: Set<String>? = []
		var shellCommands: [Int32: Int] = [:]
		var runningCalls = 0
		var archivedCalls = 0
		var countedPIDs: [Set<Int32>] = []
		var added: [UNNotificationRequest] = []
		var removed: [String] = []
	}

	private let lock = NSLock()
	private var state = State()

	subscript<Value>(keyPath: WritableKeyPath<State, Value>) -> Value {
		get { locked { $0[keyPath: keyPath] } }
		set { locked { $0[keyPath: keyPath] = newValue } }
	}

	func system(defaults: UserDefaults) -> SessionStore.System {
		SessionStore.System(
			runningSessions: { self.locked { $0.runningCalls += 1; return $0.running } },
			archivedSessionIDs: { self.locked { $0.archivedCalls += 1; return $0.archived } },
			shellCommandCounts: { pids in self.locked { $0.countedPIDs.append(pids); return $0.shellCommands } },
			addNotification: { request in self.locked { $0.added.append(request) } },
			removeNotifications: { ids in self.locked { $0.removed += ids } },
			defaults: defaults
		)
	}

	private func locked<T>(_ body: (inout State) -> T) -> T {
		lock.lock()
		defer { lock.unlock() }
		return body(&state)
	}
}

/// A store with a fake system, and a new folder for the transcripts of one test.
@MainActor
private final class Fixture {
	let fake = FakeSystem()
	let folder: URL
	let defaults: UserDefaults
	private(set) lazy var store = makeStore(checksSessions: false)

	init() throws {
		defaults = MemoryDefaults()
		folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
	}

	func cleanUp() {
		try? FileManager.default.removeItem(at: folder)
	}

	func makeStore(checksSessions: Bool) -> SessionStore {
		let setup = HookSetup(settingsURL: folder.appendingPathComponent("settings.json"), readNotificationsAllowed: { $0(nil) })
		return SessionStore(system: fake.system(defaults: defaults), setup: setup, checksSessions: checksSessions)
	}

	/// Writes the lines to a transcript in the folder and returns its path. The same name replaces the file.
	func transcript(_ lines: [String], name: String = UUID().uuidString) throws -> String {
		let url = folder.appendingPathComponent("\(name).jsonl")
		try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
		return url.path
	}

	/// Adds a session the way a hook event does. The pid comes from an earlier state of the session.
	@discardableResult
	func add(_ state: SessionState, id: String, transcript: String? = nil, pid: Int32? = nil) -> Session {
		let event = HookEvent(hook_event_name: "UserPromptSubmit", session_id: id, cwd: "/Users/me/Project", message: nil, notification_type: nil,
			tool_name: nil, last_assistant_message: nil, reason: nil, transcript_path: transcript, error: nil)
		let previous = pid.map { Session(id: id, cwd: nil, started: Date(), state: state, updated: Date(), pid: $0) }
		return store.set(state, for: event, previous: previous)
	}
}

/// Polls the condition every 10 ms, for at most 3 s.
@MainActor
private func waitUntil(_ condition: () -> Bool) async throws -> Bool {
	let deadline = Date().addingTimeInterval(3)
	while !condition() {
		if Date() > deadline { return false }
		try await Task.sleep(nanoseconds: 10_000_000)
	}
	return true
}

@Suite struct SessionStoreSyncTests {
	@MainActor @Suite struct SyncWithSessionFiles {
		@Test func unknownRunningSessionIsAdded() throws {
			let fixture = try Fixture()
			defer { fixture.cleanUp() }
			let file = process("a", pid: 101, state: .working, changed: processStart + 60)
			fixture.fake[\.running] = [file]

			fixture.store.syncWithSessionFiles(archived: [])

			let expected = Session(id: "a", cwd: file.cwd, started: processStart, state: .working, updated: processStart + 60,
				transcriptPath: file.transcriptPath, title: nil, pid: 101)
			#expect(fixture.store.sessions == ["a": expected])
			#expect(fixture.fake[\.added].isEmpty)
			#expect(fixture.fake[\.removed].isEmpty)
		}

		@Test(arguments: [(.working, .working), (.asksYou, .asksYou), (.yourTurn, .yourTurn), (nil, .yourTurn)] as [(SessionState?, SessionState)])
		func newSessionTakesTheStateOfTheFile(file: SessionState?, expected: SessionState) throws {
			let fixture = try Fixture()
			defer { fixture.cleanUp() }
			fixture.fake[\.running] = [process("a", pid: 1, state: file)]

			fixture.store.syncWithSessionFiles(archived: [])

			#expect(fixture.store.sessions["a"]?.state == expected)
		}

		@Test func knownSessionGetsThePIDAndKeepsItsData() throws {
			let fixture = try Fixture()
			defer { fixture.cleanUp() }
			let path = try fixture.transcript([prompt("Fix the bug"), titleLine("Title")])
			let known = fixture.add(.working, id: "a", transcript: path)
			fixture.fake[\.running] = [process("a", pid: 7, state: .working, started: promptTime + 60, changed: known.updated + 60)]

			fixture.store.syncWithSessionFiles(archived: [])

			var expected = known
			expected.pid = 7
			#expect(fixture.store.sessions == ["a": expected])
		}

		@Test func startIsTheEarlierOfTranscriptAndProcess() throws {
			let fixture = try Fixture()
			defer { fixture.cleanUp() }
			try fixture.add(.yourTurn, id: "early", transcript: fixture.transcript([prompt("One")]))
			try fixture.add(.yourTurn, id: "late", transcript: fixture.transcript([prompt("Two")]))
			#expect(fixture.store.sessions["early"]?.started == promptTime)
			fixture.fake[\.running] = [process("early", pid: 1, started: promptTime - 60), process("late", pid: 2, started: promptTime + 60)]

			fixture.store.syncWithSessionFiles(archived: [])

			#expect(fixture.store.sessions["early"]?.started == promptTime - 60)
			#expect(fixture.store.sessions["late"]?.started == promptTime)
		}

		@Test(arguments: [(.working, .yourTurn), (.working, .asksYou), (.yourTurn, .working), (.asksYou, .working)] as [(SessionState, SessionState)])
		func fileStateWinsWhenNewerThanTheLastEvent(hook: SessionState, file: SessionState) throws {
			let fixture = try Fixture()
			defer { fixture.cleanUp() }
			let path = try fixture.transcript([titleLine("Old")], name: "a")
			let updated = fixture.add(hook, id: "a", transcript: path).updated
			_ = try fixture.transcript([titleLine("New")], name: "a")
			fixture.fake[\.running] = [process("a", pid: 1, state: file, changed: updated + 2)]

			fixture.store.syncWithSessionFiles(archived: [])

			let session = try #require(fixture.store.sessions["a"])
			#expect(session.state == file)
			#expect(session.updated == updated + 2)
			#expect(session.title == "New")
			// Only work makes a notification old.
			#expect(fixture.fake[\.removed] == (file == .working ? ["a"] : []))
			#expect(fixture.fake[\.added].isEmpty)
		}

		@Test(arguments: [-60.0, 0, 1])
		func fileStateLosesWhenNotNewerThanTheLastEventPlusOneSecond(offset: TimeInterval) throws {
			let fixture = try Fixture()
			defer { fixture.cleanUp() }
			let updated = fixture.add(.yourTurn, id: "a").updated
			fixture.fake[\.running] = [process("a", pid: 1, state: .working, changed: updated + offset)]

			fixture.store.syncWithSessionFiles(archived: [])

			#expect(fixture.store.sessions["a"]?.state == .yourTurn)
			#expect(fixture.store.sessions["a"]?.updated == updated)
			#expect(fixture.fake[\.removed].isEmpty)
		}

		@Test func unknownFileStateChangesNothing() throws {
			let fixture = try Fixture()
			defer { fixture.cleanUp() }
			let known = fixture.add(.working, id: "a")
			fixture.fake[\.running] = [process("a", pid: 1, state: nil, started: known.started, changed: known.updated + 60)]

			fixture.store.syncWithSessionFiles(archived: [])

			var expected = known
			expected.pid = 1
			#expect(fixture.store.sessions == ["a": expected])
			#expect(fixture.fake[\.removed].isEmpty)
		}

		@Test func fileStateKeepsTheTitleWhenTheTranscriptIsGone() throws {
			let fixture = try Fixture()
			defer { fixture.cleanUp() }
			let path = try fixture.transcript([titleLine("Old")])
			let updated = fixture.add(.working, id: "a", transcript: path).updated
			try FileManager.default.removeItem(atPath: path)
			fixture.fake[\.running] = [process("a", pid: 1, state: .yourTurn, changed: updated + 2)]

			fixture.store.syncWithSessionFiles(archived: [])

			let session = try #require(fixture.store.sessions["a"])
			#expect(session.state == .yourTurn)
			#expect(session.title == "Old")
		}

		@Test func newProcessOfAKnownSessionReplacesThePID() throws {
			let fixture = try Fixture()
			defer { fixture.cleanUp() }
			let known = fixture.add(.working, id: "a", pid: 1)
			fixture.fake[\.running] = [process("a", pid: 2, state: .working, started: known.started + 60, changed: known.updated)]

			fixture.store.syncWithSessionFiles(archived: [])

			var expected = known
			expected.pid = 2
			#expect(fixture.store.sessions == ["a": expected])
		}

		@Test func fileStateDoesNotChangeAnEndedSession() throws {
			let fixture = try Fixture()
			defer { fixture.cleanUp() }
			let updated = fixture.add(.ended, id: "a").updated
			fixture.fake[\.running] = [process("a", pid: 1, state: .working, changed: updated + 60)]

			fixture.store.syncWithSessionFiles(archived: [])

			let session = try #require(fixture.store.sessions["a"])
			#expect(session.state == .ended)
			#expect(session.updated == updated)
			#expect(session.pid == 1)
			#expect(fixture.fake[\.removed].isEmpty)
		}

		@Test func archivedProcessIsSkipped() async throws {
			let fixture = try Fixture()
			defer { fixture.cleanUp() }
			fixture.fake[\.running] = [process("a", pid: 1), process("b", pid: 2)]

			fixture.store.syncWithSessionFiles(archived: ["b"])

			#expect(Set(fixture.store.sessions.keys) == ["a"])
			#expect(try await waitUntil { !fixture.fake[\.countedPIDs].isEmpty })
			#expect(fixture.fake[\.countedPIDs] == [[1]])
		}

		@Test(arguments: [SessionState.asksYou, .yourTurn, .working])
		func sessionEndsWhenItsProcessIsGone(state: SessionState) throws {
			let fixture = try Fixture()
			defer { fixture.cleanUp() }
			fixture.add(state, id: "a", pid: 1)
			let before = Date()

			fixture.store.syncWithSessionFiles(archived: [])

			let session = try #require(fixture.store.sessions["a"])
			#expect(session.state == .ended)
			#expect(session.updated >= before)
		}

		@Test func endedSessionWithoutProcessKeepsItsTime() throws {
			let fixture = try Fixture()
			defer { fixture.cleanUp() }
			let ended = fixture.add(.ended, id: "a", pid: 1)

			fixture.store.syncWithSessionFiles(archived: [])

			#expect(fixture.store.sessions["a"] == ended)
		}

		@Test func sessionWithoutPIDStays() throws {
			let fixture = try Fixture()
			defer { fixture.cleanUp() }
			let session = fixture.add(.working, id: "a")

			fixture.store.syncWithSessionFiles(archived: [])

			#expect(fixture.store.sessions["a"] == session)
		}

		@Test func sameFilesAgainPublishNothing() throws {
			let fixture = try Fixture()
			defer { fixture.cleanUp() }
			fixture.fake[\.running] = [process("a", pid: 1, state: .working)]
			fixture.store.syncWithSessionFiles(archived: [])
			var changes = 0
			let subscription = fixture.store.objectWillChange.sink { changes += 1 }

			fixture.store.syncWithSessionFiles(archived: [])

			subscription.cancel()
			#expect(changes == 0)
		}

		@Test func shellCommandCountsOfTheProcessesReachTheStore() async throws {
			let fixture = try Fixture()
			defer { fixture.cleanUp() }
			fixture.fake[\.shellCommands] = [1: 2]
			fixture.fake[\.running] = [process("a", pid: 1), process("b", pid: 2)]

			fixture.store.syncWithSessionFiles(archived: [])

			#expect(try await waitUntil { fixture.store.sessions["a"]?.shellCommands == 2 })
			#expect(fixture.store.sessions["b"]?.shellCommands == 0)
			#expect(fixture.fake[\.countedPIDs] == [[1, 2]])
		}
	}

	@MainActor @Suite struct ApplyShellCommands {
		@Test func countsGoToTheSessionOfTheirProcess() throws {
			let fixture = try Fixture()
			defer { fixture.cleanUp() }
			fixture.add(.yourTurn, id: "a", pid: 1)
			fixture.add(.working, id: "b", pid: 2)
			fixture.add(.yourTurn, id: "noPID")

			fixture.store.apply(shellCommands: [1: 3, 2: 1, 99: 5])
			#expect(fixture.store.sessions.mapValues(\.shellCommands) == ["a": 3, "b": 1, "noPID": 0])

			fixture.store.apply(shellCommands: [2: 2])
			#expect(fixture.store.sessions.mapValues(\.shellCommands) == ["a": 0, "b": 2, "noPID": 0])
		}

		@Test func noCountsSetAllToZero() throws {
			let fixture = try Fixture()
			defer { fixture.cleanUp() }
			fixture.add(.yourTurn, id: "a", pid: 1)
			fixture.store.apply(shellCommands: [1: 3])

			fixture.store.apply(shellCommands: [:])

			#expect(fixture.store.sessions["a"]?.shellCommands == 0)
		}
	}

	@MainActor @Suite struct CheckSessions {
		@Test(arguments: [SessionState.working, .asksYou])
		func interruptMakesItYourTurn(state: SessionState) throws {
			let fixture = try Fixture()
			defer { fixture.cleanUp() }
			try fixture.add(state, id: "a", transcript: fixture.transcript([prompt("Fix the bug"), answer, interrupt]))
			let before = Date()

			fixture.store.checkSessions()

			let session = try #require(fixture.store.sessions["a"])
			#expect(session.state == .yourTurn)
			#expect(session.updated >= before)
			#expect(fixture.fake[\.removed] == ["a"])
		}

		@Test(arguments: [SessionState.yourTurn, .ended])
		func interruptDoesNotChangeOtherStates(state: SessionState) throws {
			let fixture = try Fixture()
			defer { fixture.cleanUp() }
			let session = try fixture.add(state, id: "a", transcript: fixture.transcript([prompt("Fix the bug"), interrupt]))

			fixture.store.checkSessions()

			#expect(fixture.store.sessions["a"] == session)
			#expect(fixture.fake[\.removed].isEmpty)
		}

		@Test func workingSessionWithoutInterruptKeepsWorking() throws {
			let fixture = try Fixture()
			defer { fixture.cleanUp() }
			let answered = try fixture.add(.working, id: "answered", transcript: fixture.transcript([prompt("Fix the bug"), answer]))
			let noTranscript = fixture.add(.working, id: "noTranscript")

			fixture.store.checkSessions()

			#expect(fixture.store.sessions == ["answered": answered, "noTranscript": noTranscript])
			#expect(fixture.fake[\.removed].isEmpty)
		}

		@Test func archivedSessionsLeaveTheStore() throws {
			let fixture = try Fixture()
			defer { fixture.cleanUp() }
			fixture.add(.yourTurn, id: "a")
			fixture.add(.working, id: "b")
			fixture.fake[\.archived] = ["a", "c"]
			fixture.fake[\.running] = [process("c", pid: 3)]

			fixture.store.checkSessions()

			#expect(Set(fixture.store.sessions.keys) == ["b"])
			#expect(fixture.fake[\.removed] == ["a"])
		}

		@Test func unreadableArchiveKeepsAllSessions() throws {
			let fixture = try Fixture()
			defer { fixture.cleanUp() }
			fixture.add(.yourTurn, id: "a")
			fixture.fake[\.archived] = nil
			fixture.fake[\.running] = [process("b", pid: 2)]

			fixture.store.checkSessions()

			#expect(Set(fixture.store.sessions.keys) == ["a", "b"])
			#expect(fixture.fake[\.removed].isEmpty)
			#expect(fixture.fake[\.archivedCalls] == 1)
		}
	}

	@MainActor @Suite struct Init {
		@Test func checksSessionsOnceWhenAsked() throws {
			let fixture = try Fixture()
			defer { fixture.cleanUp() }
			fixture.fake[\.running] = [process("a", pid: 1)]

			let store = fixture.makeStore(checksSessions: true)

			#expect(fixture.fake[\.runningCalls] == 1)
			#expect(fixture.fake[\.archivedCalls] == 1)
			#expect(Set(store.sessions.keys) == ["a"])
		}

		@Test func checksNothingWhenNotAsked() throws {
			let fixture = try Fixture()
			defer { fixture.cleanUp() }
			fixture.fake[\.running] = [process("a", pid: 1)]

			let store = fixture.makeStore(checksSessions: false)

			#expect(fixture.fake[\.runningCalls] == 0)
			#expect(fixture.fake[\.archivedCalls] == 0)
			#expect(store.sessions.isEmpty)
		}
	}
}
