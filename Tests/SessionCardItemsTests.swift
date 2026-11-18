import AppKit
import Foundation
import Testing
@testable import ClaudeCodeNotifier

@MainActor @Suite struct SessionCardPartsTests {
	private static let date = Date(timeIntervalSince1970: 1_000_000)

	private func session(_ id: String, _ cwd: String) -> Session {
		Session(id: id, cwd: cwd, started: Self.date, state: .working, updated: Self.date)
	}

	@Test func aTextTakesThePlaceOfTheRows() {
		#expect(SessionCard.parts(sessions: []) == [.init(content: .header), .init(content: .empty(hasHidden: false), isLast: true)])
		#expect(SessionCard.parts(sessions: [], hasHidden: true).last?.content == .empty(hasHidden: true))
	}

	@Test func eachSessionOfOneProjectIsAPartWithALineBetweenTheRows() {
		let (a, b, c) = (session("a", "/x/one"), session("b", "/x/one"), session("c", "/x/one"))
		#expect(SessionCard.parts(sessions: [a, b, c]) == [
			.init(content: .header),
			.init(content: .session(a)),
			.init(content: .session(b), hasDivider: true),
			.init(content: .session(c), hasDivider: true, isLast: true),
		])
	}

	@Test func eachProjectGetsAHeadline() {
		let (a, b, c) = (session("a", "/x/one"), session("b", "/x/two"), session("c", "/x/one"))
		#expect(SessionCard.parts(sessions: [a, b, c]) == [
			.init(content: .header),
			.init(content: .headline(project: "one", isFirst: true)),
			.init(content: .session(a)),
			.init(content: .session(c), hasDivider: true),
			.init(content: .headline(project: "two", isFirst: false)),
			.init(content: .session(b), isLast: true),
		])
	}

	@Test func runningReportsComeFirstWithALineBelow() {
		let (a, b) = (session("a", "/x/one"), session("b", "/x/two"))
		let running: [(title: String, started: Date?)] = [("Morning Overview", Self.date), ("DiDi", nil)]
		let reports: [SessionCard.Part] = [
			.init(content: .header),
			.init(content: .report(title: "Morning Overview", started: Self.date)),
			.init(content: .report(title: "DiDi", started: nil), hasDivider: true),
		]
		#expect(SessionCard.parts(sessions: [a], running: running) == reports + [.init(content: .session(a), hasDivider: true, isLast: true)])
		// With headlines, the line is above the first headline, and no headline is the first row of the card.
		#expect(SessionCard.parts(sessions: [a, b], running: running) == reports + [
			.init(content: .headline(project: "one", isFirst: false), hasDivider: true),
			.init(content: .session(a)),
			.init(content: .headline(project: "two", isFirst: false)),
			.init(content: .session(b), isLast: true),
		])
	}

	@Test func aReportWithoutSessionsIsTheLastPart() {
		#expect(SessionCard.parts(sessions: [], running: [("DiDi", nil)]) == [
			.init(content: .header),
			.init(content: .report(title: "DiDi", started: nil), isLast: true),
		])
	}

	@Test func onlyPartsOfTheSameKindAndPlaceHaveTheSameHeight() {
		let (a, b) = (session("a", "/x/one"), session("b", "/x/two"))
		let row = SessionCard.Part(content: .session(a))
		#expect(row.hasHeight(of: .init(content: .session(b))))
		#expect(!row.hasHeight(of: .init(content: .session(a), hasDivider: true)))
		#expect(!row.hasHeight(of: .init(content: .session(a), isLast: true)))
		#expect(!row.hasHeight(of: .init(content: .headline(project: "one", isFirst: true))))
		#expect(!SessionCard.Part(content: .headline(project: "one", isFirst: true)).hasHeight(of: .init(content: .headline(project: "one", isFirst: false))))
		#expect(SessionCard.Part(content: .headline(project: "one", isFirst: true)).hasHeight(of: .init(content: .headline(project: "two", isFirst: true))))
	}
}

/// The card items of a ``SessionCardFixture`` in a menu, with one more item below them.
@MainActor
private struct ItemsFixture {
	let sessions: SessionCardFixture
	let items: SessionCardItems
	let menu = NSMenu()
	let below = NSMenuItem(title: "Below", action: nil, keyEquivalent: "")
	let opened = Opened()
	let running = Running()

	final class Opened {
		var ids: [String] = []
	}

	/// The running reports of the card.
	final class Running {
		var reports: [(title: String, started: Date?)] = []
	}

	init(states: [SessionState], cwds: [String]? = nil) throws {
		sessions = try SessionCardFixture(states: states, cwds: cwds)
		items = SessionCardItems(store: sessions.store, setup: sessions.setup, clock: MenuClock(), running: { [running] in running.reports },
			open: { [opened] in opened.ids.append($0.id) })
		menu.addItem(NSMenuItem(title: "Above", action: nil, keyEquivalent: ""))
		items.add(to: menu)
		menu.addItem(below)
	}

	func view(of item: NSMenuItem) throws -> SessionCardItemView {
		try #require(item.view as? SessionCardItemView)
	}

	/// What the menu does for a key: it gives the key to the view of `item`, if this view takes the keys.
	func press(_ keyCode: UInt16, on item: NSMenuItem) throws {
		let view = try view(of: item)
		// A view outside a window beeps for a key that it passes on.
		if try view.chooses(Self.key(keyCode)) { try view.keyDown(with: Self.key(keyCode)) }
	}

	static func key(_ keyCode: UInt16) throws -> NSEvent {
		try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
			characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode))
	}

	/// The heights of the item views, from the top.
	var heights: [CGFloat] { items.items.map { $0.view?.frame.height ?? 0 } }
}

@MainActor @Suite struct SessionCardItemsTests {
	@Test func theCardIsAStackOfItemsInTheMenu() throws {
		let fixture = try ItemsFixture(states: [.working, .yourTurn], cwds: ["/tmp/one", "/tmp/one"])
		#expect(fixture.items.items.count == fixture.sessions.parts.count)
		// The title of a session item is for the type-select. The other parts have none.
		#expect(fixture.menu.items.map(\.title) == ["Above", "", "one", "one", "Below"])
		#expect(fixture.items.items.allSatisfy { $0.view is SessionCardItemView })
		#expect(fixture.heights.allSatisfy { $0 > 0 && $0 == $0.rounded() })
	}

	@Test func theArrowKeysStopOnlyAtTheSessions() throws {
		let fixture = try ItemsFixture(states: [.working, .yourTurn], cwds: ["/tmp/one", "/tmp/two"])
		// The header and the two headlines are not enabled.
		#expect(fixture.items.items.map(\.isEnabled) == [false, false, true, false, true])
		// The menu does not enable the items without an action again.
		#expect(!fixture.menu.autoenablesItems)
		let empty = try ItemsFixture(states: [])
		#expect(empty.items.items.map(\.isEnabled) == [false, false])
	}

	@Test(arguments: [36, 76, 49] as [UInt16])
	func returnEnterAndSpaceOpenTheHighlightedSession(keyCode: UInt16) throws {
		let fixture = try ItemsFixture(states: [.working, .yourTurn], cwds: ["/tmp/one", "/tmp/one"])
		let items = fixture.items.items
		fixture.items.highlight(items[2])
		try fixture.press(keyCode, on: items[2])
		#expect(fixture.opened.ids == ["session-1"])
		// The view of another item does not take the key.
		try fixture.press(keyCode, on: items[1])
		#expect(fixture.opened.ids == ["session-1"])
	}

	@Test func otherKeysOpenNothing() throws {
		let fixture = try ItemsFixture(states: [.working])
		let item = fixture.items.items[1]
		fixture.items.highlight(item)
		// Arrow down, Escape and the letter a.
		for keyCode in [125, 53, 0] as [UInt16] { #expect(try !fixture.view(of: item).chooses(ItemsFixture.key(keyCode))) }
		#expect(try fixture.view(of: item).chooses(ItemsFixture.key(36)))
	}

	@Test func theCardKnowsTheHighlightedItem() throws {
		let fixture = try ItemsFixture(states: [.working, .yourTurn], cwds: ["/tmp/one", "/tmp/one"])
		let items = fixture.items.items
		let takesKeys = { try items.map { try fixture.view(of: $0).takesKeys } }
		#expect(try takesKeys() == [false, false, false])
		fixture.items.highlight(items[2])
		#expect(fixture.items.model.highlightedSlot == 2)
		// Only the view of the highlighted item takes the keys.
		#expect(try takesKeys() == [false, false, true])
		#expect(try fixture.view(of: items[2]).acceptsFirstResponder)
		#expect(try !fixture.view(of: items[1]).acceptsFirstResponder)
		fixture.items.highlight(fixture.below)
		#expect(fixture.items.model.highlightedSlot == nil)
		#expect(try takesKeys() == [false, false, false])
		fixture.items.highlight(items[1])
		fixture.items.highlight(nil)
		#expect(fixture.items.model.highlightedSlot == nil)
		fixture.items.highlight(items[1])
		fixture.items.close()
		#expect(fixture.items.model.highlightedSlot == nil)
		#expect(try takesKeys() == [false, false, false])
	}

	@Test func aPartWithoutASessionGetsNoHighlight() throws {
		let fixture = try ItemsFixture(states: [.working, .yourTurn], cwds: ["/tmp/one", "/tmp/one"])
		let items = fixture.items.items
		fixture.items.highlight(items[0])
		#expect(fixture.items.model.highlightedSlot == nil)
		fixture.items.highlight(items[1])
		// A session of a second project puts a headline at the place of the highlighted row.
		try fixture.sessions.set(.yourTurn, session: 2, cwd: "/tmp/two")
		fixture.items.sync()
		#expect(fixture.items.session(of: items[1]) == nil)
		#expect(fixture.items.model.highlightedSlot == nil)
		#expect(try !fixture.view(of: items[1]).takesKeys)
		try fixture.press(36, on: items[1])
		#expect(fixture.opened.ids == [])
	}

	@Test func aNewSessionAddsAnItemBelowTheOthers() throws {
		let fixture = try ItemsFixture(states: [.yourTurn])
		let old = fixture.items.items
		let title = String(repeating: "long title ", count: 20)
		try fixture.sessions.set(.working, session: 1, cwd: "/tmp/project-0", title: title)
		fixture.items.sync()
		#expect(fixture.items.items.count == old.count + 1)
		#expect(fixture.items.items.prefix(old.count).elementsEqual(old) { $0 === $1 })
		#expect(fixture.menu.items.map(\.title) == ["Above", "", title, "project-0", "Below"])
		// The new item does not make the menu wider.
		#expect(fixture.items.items.map { $0.view?.frame.width } == [300, 300, 300])
		// The working session is the first row now.
		#expect(fixture.items.session(of: fixture.items.items[1])?.id == "session-1")
		#expect(fixture.items.items.map(\.isEnabled) == [false, true, true])
	}

	@Test func theItemsStayWhenTheOrderChanges() throws {
		let fixture = try ItemsFixture(states: [])
		try fixture.sessions.set(.working, session: 0, cwd: "/tmp/one", title: "Alpha")
		try fixture.sessions.set(.yourTurn, session: 1, cwd: "/tmp/one", title: "Beta")
		fixture.items.sync()
		let old = fixture.items.items
		#expect(old.map { fixture.items.session(of: $0)?.id } == [nil, "session-0", "session-1"])
		#expect(old.map(\.title) == ["", "Alpha", "Beta"])
		fixture.items.highlight(old[1])
		try fixture.sessions.set(.asksYou, session: 1)
		fixture.items.sync()
		#expect(fixture.items.items.elementsEqual(old) { $0 === $1 })
		#expect(old.map { fixture.items.session(of: $0)?.id } == [nil, "session-1", "session-0"])
		#expect(old.map(\.title) == ["", "Beta", "Alpha"])
		// The highlight keeps its place, and Return opens the session that the item shows now.
		#expect(fixture.items.model.highlightedSlot == 1)
		try fixture.press(36, on: old[1])
		#expect(fixture.opened.ids == ["session-1"])
	}

	@Test func aHiddenSessionRemovesItsItem() throws {
		let fixture = try ItemsFixture(states: [.working, .yourTurn], cwds: ["/tmp/one", "/tmp/one"])
		fixture.items.highlight(fixture.items.items[2])
		fixture.sessions.store.hide("session-1")
		fixture.items.sync()
		#expect(fixture.items.items.count == 2)
		#expect(fixture.menu.items.map(\.title) == ["Above", "", "one", "Below"])
		// The highlighted item is gone.
		#expect(fixture.items.model.highlightedSlot == nil)
		fixture.sessions.store.hide("session-0")
		fixture.items.sync()
		#expect(fixture.items.model.parts.map(\.content) == [.header, .empty(hasHidden: true)])
		#expect(fixture.items.items.map(\.isEnabled) == [false, false])
		#expect(fixture.menu.items.map(\.title) == ["Above", "", "", "Below"])
	}

	@Test func aRunningReportGetsAnItemAboveTheSessions() throws {
		let fixture = try ItemsFixture(states: [.working])
		fixture.running.reports = [("Morning Overview", Date())]
		fixture.items.sync()
		#expect(fixture.items.model.parts.map(\.content) == [.header, .report(title: "Morning Overview", started: fixture.running.reports[0].started),
			.session(try #require(fixture.sessions.store.sessions["session-0"]))])
		// The arrow keys skip the report.
		#expect(fixture.items.items.map(\.isEnabled) == [false, false, true])
		fixture.running.reports = []
		fixture.items.sync()
		#expect(fixture.items.items.map(\.isEnabled) == [false, true])
	}

	@Test func eachItemGetsTheHeightOfItsNewPart() throws {
		let fixture = try ItemsFixture(states: [.working, .yourTurn, .yourTurn], cwds: ["/tmp/one", "/tmp/one", "/tmp/two"])
		// One project is left, so the headlines go away and other parts take their places.
		fixture.sessions.store.hide("session-2")
		fixture.items.sync()
		let fresh = try ItemsFixture(states: [.working, .yourTurn], cwds: ["/tmp/one", "/tmp/one"])
		#expect(fixture.heights == fresh.heights)
		// The last part has the bottom edge of the card, so it is higher than the same row above it.
		#expect(fixture.heights[2] > fixture.heights[1])
	}

	@Test func aClosedMenuKeepsItsItems() throws {
		let fixture = try ItemsFixture(states: [.working])
		fixture.items.close()
		try fixture.sessions.set(.working, session: 1, cwd: "/tmp/project-0")
		fixture.items.sync()
		#expect(fixture.items.items.count == 2)
		// The next menu gets new items.
		let menu = NSMenu()
		fixture.items.add(to: menu)
		#expect(menu.items.count == 3)
		#expect(menu.items.elementsEqual(fixture.items.items) { $0 === $1 })
	}
}
