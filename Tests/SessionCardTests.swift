import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import ClaudeCodeNotifier

/// Measures the card with one session per state, each in its own folder, or in the folder of `cwds`. The store and the setup use a fake system, and nothing writes to the defaults.
@MainActor
private func cardSize(states: [SessionState], cwds: [String]? = nil) throws -> NSSize {
	let defaults = MemoryDefaults()
	let system = SessionStore.System(runningSessions: { [] }, archivedSessionIDs: { [] }, shellCommandCounts: { _ in [:] },
		addNotification: { _ in }, removeNotifications: { _ in }, sessionEnded: {}, defaults: defaults)
	// The setup never reads this file. It does not exist.
	let settingsURL = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeCodeNotifierTests-\(UUID().uuidString)/settings.json")
	let setup = HookSetup(settingsURL: settingsURL, readNotificationsAllowed: { $0(true) })
	let store = SessionStore(system: system, setup: setup, checksSessions: false)
	for (index, state) in states.enumerated() {
		let cwd = cwds?[index] ?? "/tmp/project-\(index)"
		let json = #"{"hook_event_name":"SessionStart","session_id":"session-\#(index)","cwd":"\#(cwd)"}"#
		store.set(state, for: try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8)), previous: nil)
	}
	#expect(store.sessions.count == states.count)
	return NSHostingView(rootView: SessionCard(store: store, setup: setup, clock: MenuClock())).fittingSize
}

@MainActor @Suite struct SessionCardTests {
	@Test(arguments: [
		(0, "0s"),
		(58, "58s"),
		(60, "1:00"),
		(247, "4:07"),
		(3599, "59:59"),
		(3600, "1h 00m"),
		(4140, "1h 09m"),
		(86_399, "23h 59m"),
		(86_400, "1d 0h 00m"),
		(187_380, "2d 4h 03m"),
	])
	func elapsed(seconds: Int, expected: String) {
		let start = Date(timeIntervalSince1970: 1_000_000)
		#expect(SessionCard.elapsed(from: start, to: start.addingTimeInterval(Double(seconds))) == expected)
	}

	@Test func elapsedIsZeroForAStartInTheFuture() {
		let now = Date(timeIntervalSince1970: 1_000_000)
		#expect(SessionCard.elapsed(from: now.addingTimeInterval(5), to: now) == "0s")
	}

	@Test func cardWithoutSessionsHasASize() throws {
		let size = try cardSize(states: [])
		#expect(size.width >= 300)
		#expect(size.height > 0)
	}

	@Test func eachSessionAddsARow() throws {
		let empty = try cardSize(states: [])
		let one = try cardSize(states: [.working])
		let two = try cardSize(states: [.working, .yourTurn])
		let all = try cardSize(states: [.asksYou, .yourTurn, .working])
		#expect(one.width >= 300)
		#expect(two.height > one.height)
		#expect(all.height > two.height)
		#expect(all.height > empty.height)
	}

	@Test func groupsKeepTheOrderOfTheirFirstSession() {
		let date = Date(timeIntervalSince1970: 1_000_000)
		let folders: [(String, String?)] = [("a", "/x/one"), ("b", "/x/two"), ("c", "/y/one"), ("d", nil)]
		let sessions = folders.map { id, cwd in
			Session(id: id, cwd: cwd, started: date, state: .working, updated: date)
		}
		let groups = SessionCard.groups(sessions)
		#expect(groups.map(\.project) == ["one", "two", "Claude Code"])
		#expect(groups.map { $0.sessions.map(\.id) } == [["a", "c"], ["b"], ["d"]])
	}

	@Test func groupsFollowTheProjectOrder() {
		let date = Date(timeIntervalSince1970: 1_000_000)
		let sessions = [("a", "/x/one"), ("b", "/x/two"), ("c", "/x/three")].map { id, cwd in
			Session(id: id, cwd: cwd, started: date, state: .working, updated: date)
		}
		#expect(SessionCard.groups(sessions, order: ["two", "one"]).map(\.project) == ["two", "one", "three"])
	}

	@Test func projectOrderKeepsOldProjectsAndAddsNewOnesLast() {
		let date = Date(timeIntervalSince1970: 1_000_000)
		let sessions = [("a", "/x/one", 1.0), ("b", "/x/two", 3.0), ("c", "/x/three", 2.0)].map { id, cwd, time in
			Session(id: id, cwd: cwd, started: date, state: .working, updated: date.addingTimeInterval(time))
		}
		#expect(SessionStore.projectOrder(keeping: [], for: sessions) == ["two", "three", "one"])
		#expect(SessionStore.projectOrder(keeping: ["one"], for: sessions) == ["one", "two", "three"])
	}

	@Test func projectHeadlinesOnlyWithMoreThanOneProject() throws {
		let oneProject = try cardSize(states: [.working, .yourTurn], cwds: ["/tmp/one", "/tmp/one"])
		let twoProjects = try cardSize(states: [.working, .yourTurn], cwds: ["/tmp/one", "/tmp/two"])
		#expect(twoProjects.height > oneProject.height)
	}

	@Test func longNameGetsAtMost300Points() throws {
		let short = try cardSize(states: [.working])
		let long = try cardSize(states: [.working], cwds: ["/tmp/" + String(repeating: "long-name-", count: 50)])
		#expect(long.width > short.width)
		#expect(long.width < short.width + 300)
		#expect(long.height == short.height)
	}
}

@MainActor @Suite struct MenuClockTests {
	@Test func nowIsTheTimeOfCreation() {
		let before = Date()
		let clock = MenuClock()
		#expect(clock.now >= before)
		#expect(clock.now <= Date())
	}

	@Test func tickMovesNowForward() async throws {
		let clock = MenuClock()
		let created = clock.now
		try await Task.sleep(for: .milliseconds(5))
		let before = Date()
		clock.tick()
		#expect(clock.now > created)
		#expect(clock.now >= before)
		#expect(clock.now <= Date())
	}

	@Test func tickTellsTheViews() {
		let clock = MenuClock()
		var changes = 0
		let subscription = clock.objectWillChange.sink { _ in changes += 1 }
		clock.tick()
		clock.tick()
		subscription.cancel()
		#expect(changes == 2)
	}
}

@MainActor @Suite struct SessionStateColorTests {
	@Test func asksYouIsOrange() {
		#expect(SessionState.asksYou.color == .orange)
	}

	@Test func workingIsTheSegmentGreenOfTheWave() {
		#expect(SessionState.working.color == Color(nsColor: Spinner.segmentColor(of: Spinner.color)))
	}

	@Test func yourTurnIsWhite() {
		#expect(SessionState.yourTurn.color == .white)
	}

	@Test func eachStateHasItsOwnColor() {
		let colors = [SessionState.asksYou, .yourTurn, .working].map(\.color)
		#expect(Set(colors).count == 3)
	}
}
