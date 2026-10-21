import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import ClaudeCodeNotifier

/// The red, green, blue and alpha of the color in sRGB, in the given appearance.
@MainActor
private func components(_ color: NSColor, in name: NSAppearance.Name) throws -> [Double] {
	let appearance = try #require(NSAppearance(named: name))
	var resolved: NSColor?
	appearance.performAsCurrentDrawingAppearance {
		resolved = color.usingColorSpace(.sRGB)
	}
	let color = try #require(resolved)
	return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
}

private func isClose(_ a: [Double], _ b: [Double]) -> Bool {
	a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 0.001 }
}

/// Measures the card with one session per state, each in a folder named after the project. The store and the setup
/// use a fake system, and nothing writes to the defaults.
@MainActor
private func cardSize(states: [SessionState], project: String = "project") throws -> NSSize {
	let defaults = MemoryDefaults()
	let system = SessionStore.System(runningSessions: { [] }, archivedSessionIDs: { [] }, shellCommandCounts: { _ in [:] },
		addNotification: { _ in }, removeNotifications: { _ in }, defaults: defaults)
	// The setup never reads this file. It does not exist.
	let settingsURL = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeCodeNotifierTests-\(UUID().uuidString)/settings.json")
	let setup = HookSetup(settingsURL: settingsURL, readNotificationsAllowed: { $0(true) })
	let store = SessionStore(system: system, setup: setup, checksSessions: false)
	for (index, state) in states.enumerated() {
		let json = #"{"hook_event_name":"SessionStart","session_id":"session-\#(index)","cwd":"/tmp/\#(project)-\#(index)"}"#
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
		let all = try cardSize(states: [.asksYou, .yourTurn, .working, .ended])
		#expect(one.width >= 300)
		#expect(two.height > one.height)
		#expect(all.height > two.height)
		#expect(all.height > empty.height)
	}

	@Test func longNameGetsAtMost300Points() throws {
		let short = try cardSize(states: [.working])
		let long = try cardSize(states: [.working], project: String(repeating: "long-name-", count: 50))
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

	@Test func workingIsTheAccentColor() {
		#expect(SessionState.working.color == .accentColor)
	}

	@Test func endedIsSecondary() {
		#expect(SessionState.ended.color == .secondary)
	}

	@Test func yourTurnIsTheGreen() throws {
		let color = NSColor(SessionState.yourTurn.color)
		#expect(isClose(try components(color, in: .aqua), [0.10, 0.56, 0.24, 1]))
		#expect(isClose(try components(color, in: .darkAqua), [0.30, 0.87, 0.45, 1]))
	}

	@Test func eachStateHasItsOwnColor() {
		let colors = [SessionState.asksYou, .yourTurn, .working, .ended].map(\.color)
		#expect(Set(colors).count == 4)
	}

	@Test func greenIsDarkerInLightMode() throws {
		#expect(isClose(try components(SessionState.yourTurn.yourTurnGreen, in: .aqua), [0.10, 0.56, 0.24, 1]))
	}

	@Test func greenIsBrighterInDarkMode() throws {
		#expect(isClose(try components(SessionState.yourTurn.yourTurnGreen, in: .darkAqua), [0.30, 0.87, 0.45, 1]))
	}
}
