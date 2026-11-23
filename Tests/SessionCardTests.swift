import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import ClaudeCodeNotifier

/// A store with one session per state, each in its own folder, or in the folder of `cwds`. The store and the setup use a fake system, and nothing writes to the defaults.
@MainActor
struct SessionCardFixture {
	let store: SessionStore
	let setup: HookSetup

	init(states: [SessionState], cwds: [String]? = nil) throws {
		let defaults = MemoryDefaults()
		let system = SessionStore.System(runningSessions: { [] }, archivedSessionIDs: { [] }, shellCommandCounts: { _ in [:] },
			addNotification: { _ in }, removeNotifications: { _ in }, sessionEnded: {}, defaults: defaults)
		// The setup never reads this file. It does not exist.
		let settingsURL = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeCodeNotifierTests-\(UUID().uuidString)/settings.json")
		setup = HookSetup(settingsURL: settingsURL, readNotificationsAllowed: { $0(true) })
		store = SessionStore(system: system, setup: setup, checksSessions: false)
		for (index, state) in states.enumerated() { try set(state, session: index, cwd: cwds?[index]) }
		#expect(store.sessions.count == states.count)
	}

	/// Adds the session `session-<index>`, or gives it a new state. A new session can get a title.
	func set(_ state: SessionState, session index: Int, cwd: String? = nil, title: String? = nil) throws {
		let cwd = cwd ?? "/tmp/project-\(index)"
		let json = #"{"hook_event_name":"SessionStart","session_id":"session-\#(index)","cwd":"\#(cwd)"}"#
		let new = title.map { Session(id: "session-\(index)", cwd: cwd, started: Date(), state: state, updated: Date(), title: $0) }
		store.set(state, for: try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8)), previous: store.sessions["session-\(index)"] ?? new)
	}

	/// The parts of the card for the sessions of the store.
	var parts: [SessionCard.Part] {
		SessionCard.parts(sessions: store.sortedSessions, order: store.projectOrder, hasHidden: !store.hiddenStates.isEmpty)
	}
}

/// Measures the card of a ``SessionCardFixture``: as wide as its widest part, and as high as all parts together.
@MainActor
private func cardSize(states: [SessionState], cwds: [String]? = nil) throws -> NSSize {
	let fixture = try SessionCardFixture(states: states, cwds: cwds)
	let model = SessionCardModel()
	model.parts = fixture.parts
	let sizes = model.parts.indices.map {
		NSHostingView(rootView: SessionCard(model: model, slot: $0, setup: fixture.setup, clock: MenuClock())).fittingSize
	}
	return NSSize(width: sizes.map(\.width).max() ?? 0, height: sizes.map(\.height).reduce(0, +))
}

@MainActor @Suite struct SessionCardTests {
	@Test(arguments: [
		(0, "00s"),
		(1, "01s"),
		(56, "56s"),
		(60, "01m 00s"),
		(202, "03m 22s"),
		(3599, "59m 59s"),
		(3600, "1h 00m"),
		(8400, "2h 20m"),
		(86_399, "23h 59m"),
		(86_400, "1d 0h"),
		(187_380, "2d 4h"),
		(259_199, "2d 23h"),
		(259_200, "3d"),
		(604_799, "6d"),
		(604_800, "1w"),
		(60_480_000, "100w"),
	])
	func elapsed(seconds: Int, expected: String) {
		let start = Date(timeIntervalSince1970: 1_000_000)
		#expect(SessionCard.elapsed(from: start, to: start.addingTimeInterval(Double(seconds))) == expected)
	}

	@Test(arguments: [
		(0, "1m"),
		(59, "1m"),
		(3599, "59m"),
		(3600, "1h"),
		(6839, "1.8h"),
		(7199, "1.9h"),
		(7200, "2h"),
		(86_399, "23h"),
		(86_400, "1d"),
		(121_000, "1.4d"),
		(172_800, "2d"),
		(734_400, "8d"),
	])
	func largestUnitOnly(seconds: Int, expected: String) {
		let start = Date(timeIntervalSince1970: 1_000_000)
		#expect(SessionCard.elapsed(from: start, to: start.addingTimeInterval(Double(seconds)), largestUnitOnly: true) == expected)
	}

	@Test func elapsedIsZeroForAStartInTheFuture() {
		let now = Date(timeIntervalSince1970: 1_000_000)
		#expect(SessionCard.elapsed(from: now.addingTimeInterval(5), to: now) == "00s")
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

	@Test func groupWithAnImportantSessionComesFirst() {
		let date = Date(timeIntervalSince1970: 1_000_000)
		var sessions = [("a", "/x/one"), ("b", "/x/two")].map { id, cwd in
			Session(id: id, cwd: cwd, started: date, state: .working, updated: date)
		}
		sessions[1].isImportant = true
		#expect(SessionCard.groups(sessions, order: ["one", "two"]).map(\.project) == ["two", "one"])
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

	@Test func stackedPartsLookLikeOneCard() throws {
		let heights: [CGFloat] = [20, 28, 9, 33]
		let parts = VStack(spacing: 0) {
			ForEach(Array(heights.enumerated()), id: \.offset) { index, height in
				Color.clear.frame(height: height).cardPart(isFirst: index == 0, isLast: index == heights.count - 1)
			}
		}
		let card = Color.clear.frame(height: heights.reduce(0, +)).menuCard()
		let pixels = try pixels(of: parts.frame(width: 320))
		#expect(pixels.contains { $0 != 0 })
		#expect(try pixels == self.pixels(of: card.frame(width: 320)))
	}

	@Test func theHighlightedRowDrawsItsHighlight() throws {
		let fixture = try SessionCardFixture(states: [.working, .yourTurn], cwds: ["/tmp/one", "/tmp/one"])
		let model = SessionCardModel()
		model.parts = fixture.parts
		// One clock, so that the time of the row is the same in each image.
		// The row of the session that waits: its wave is still, so the pixels do not change with the time.
		let row = SessionCard(model: model, slot: 2, setup: fixture.setup, clock: MenuClock()).frame(width: 320)
		let plain = try pixels(of: row)
		model.highlightedSlot = 2
		model.hasHighlight = true
		#expect(try !isNearly(pixels(of: row), plain))
		// The highlight of another row.
		model.highlightedSlot = 1
		#expect(try isNearly(pixels(of: row), plain))
	}

	/// Whether no byte differs by more than 2. After a change of the state, SwiftUI can draw the text of the row
	/// with 1 step of difference at its edges.
	private func isNearly(_ pixels: [UInt8], _ other: [UInt8]) -> Bool {
		pixels.count == other.count && zip(pixels, other).allSatisfy { abs(Int($0) - Int($1)) <= 2 }
	}

	@Test func aPlaceWithoutAPartShowsNothing() throws {
		let fixture = try SessionCardFixture(states: [.working])
		let model = SessionCardModel()
		model.parts = fixture.parts
		#expect(NSHostingView(rootView: SessionCard(model: model, slot: 5, setup: fixture.setup, clock: MenuClock())).fittingSize == .zero)
	}

	/// The pixels of the view as RGBA, at 2 pixels per point.
	private func pixels(of view: some View) throws -> [UInt8] {
		let renderer = ImageRenderer(content: view)
		renderer.scale = 2
		let image = try #require(renderer.cgImage)
		let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
			space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
		context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
		let data = try #require(context.data)
		return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
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

	@Test func workingHasTheTextColor() {
		#expect(SessionState.working.color == .primary)
	}

	@Test func yourTurnIsWhite() {
		#expect(SessionState.yourTurn.color == .white)
	}

	@Test func eachStateHasItsOwnColor() {
		let colors = [SessionState.asksYou, .yourTurn, .working].map(\.color)
		#expect(Set(colors).count == 3)
	}
}
