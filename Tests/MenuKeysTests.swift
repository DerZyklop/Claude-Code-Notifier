import AppKit
import SwiftUI
import Testing
@testable import ClaudeCodeNotifier

/// A ``MenuButtonsItem`` with the buttons a, b and c, in a menu with one more item.
@MainActor
private final class ButtonsFixture {
	let focus = MenuButtonFocus()
	let other = NSMenuItem(title: "Other", action: nil, keyEquivalent: "")
	var enabled: Set<String> = ["a", "b", "c"]
	var pressed: [String] = []
	private(set) var buttons: MenuButtonsItem!

	init(main: String = "b") {
		buttons = MenuButtonsItem(title: "Buttons", content: NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 20)), focus: focus,
			main: main) { [unowned self] in
			["a", "b", "c"].map { id in MenuKeyButton(id: id, isEnabled: self.enabled.contains(id)) { self.pressed.append(id) } }
		}
	}

	var item: NSMenuItem { buttons.item }
	var view: MenuItemKeyView { item.view as! MenuItemKeyView }

	/// What the menu does for a key: it gives the key to the view. Not `keyDown(with:)`: a view outside a window beeps
	/// for a key that it passes on.
	@discardableResult
	func press(_ keyCode: UInt16) throws -> Bool {
		try view.handleKey(#require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
			context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode)))
	}
}

@MainActor @Suite struct MenuKeysTests {
	@Test func theArrowKeysStopAtARowOfButtons() {
		let fixture = ButtonsFixture()
		#expect(fixture.item.isEnabled)
		#expect(fixture.item.title == "Buttons")
		#expect(!fixture.buttons.takesKeys)
	}

	@Test func aKeyPutsTheRingOnTheMainButton() {
		let fixture = ButtonsFixture()
		fixture.buttons.highlight(fixture.item, byKey: true)
		#expect(fixture.buttons.takesKeys)
		#expect(fixture.view.acceptsFirstResponder)
		#expect(fixture.focus.buttonID == "b")
		fixture.buttons.highlight(fixture.other, byKey: true)
		#expect(!fixture.buttons.takesKeys)
		#expect(fixture.focus.buttonID == nil)
	}

	@Test func thePointerPutsNoRingOnAButton() throws {
		let fixture = ButtonsFixture()
		fixture.buttons.highlight(fixture.item, byKey: false)
		#expect(fixture.buttons.takesKeys)
		#expect(fixture.focus.buttonID == nil)
		// Then a key only shows the ring. It presses nothing.
		#expect(try fixture.press(36))
		#expect(fixture.focus.buttonID == "b")
		#expect(fixture.pressed == [])
	}

	@Test func theSameHighlightAgainKeepsTheRing() throws {
		let fixture = ButtonsFixture()
		fixture.buttons.highlight(fixture.item, byKey: true)
		try fixture.press(124)
		fixture.buttons.highlight(fixture.item, byKey: true)
		#expect(fixture.focus.buttonID == "c")
	}

	@Test func leftAndRightMoveTheRingAndStopAtTheEnds() throws {
		let fixture = ButtonsFixture()
		fixture.buttons.highlight(fixture.item, byKey: true)
		#expect(try fixture.press(124))
		#expect(fixture.focus.buttonID == "c")
		try fixture.press(124)
		#expect(fixture.focus.buttonID == "c")
		try fixture.press(123)
		try fixture.press(123)
		try fixture.press(123)
		#expect(fixture.focus.buttonID == "a")
		#expect(fixture.pressed == [])
	}

	@Test func theRingSkipsDisabledButtons() throws {
		let fixture = ButtonsFixture(main: "a")
		fixture.enabled = ["a", "c"]
		fixture.buttons.highlight(fixture.item, byKey: true)
		try fixture.press(124)
		#expect(fixture.focus.buttonID == "c")
	}

	@Test func aDisabledMainButtonGivesTheRingToTheFirstEnabledButton() {
		let fixture = ButtonsFixture()
		fixture.enabled = ["c"]
		fixture.buttons.highlight(fixture.item, byKey: true)
		#expect(fixture.focus.buttonID == "c")
	}

	@Test(arguments: [36, 76, 49] as [UInt16])
	func returnEnterAndSpacePressTheButtonWithTheRing(keyCode: UInt16) throws {
		let fixture = ButtonsFixture()
		fixture.buttons.highlight(fixture.item, byKey: true)
		try fixture.press(123)
		#expect(try fixture.press(keyCode))
		#expect(fixture.pressed == ["a"])
	}

	@Test func aButtonThatIsDisabledNowGetsNoPress() throws {
		let fixture = ButtonsFixture()
		fixture.buttons.highlight(fixture.item, byKey: true)
		fixture.enabled = ["a", "c"]
		try fixture.press(36)
		#expect(fixture.pressed == [])
		#expect(fixture.focus.buttonID == "a")
	}

	@Test func otherKeysGoToTheMenu() throws {
		let fixture = ButtonsFixture()
		fixture.buttons.highlight(fixture.item, byKey: true)
		// Arrow down and up, Escape and the letter a.
		for keyCode in [125, 126, 53, 0] as [UInt16] { #expect(try !fixture.press(keyCode)) }
		#expect(fixture.focus.buttonID == "b")
	}

	@Test func aRowWithoutTheHighlightTakesNoKeys() throws {
		let fixture = ButtonsFixture()
		#expect(try !fixture.press(36))
		fixture.buttons.highlight(fixture.item, byKey: true)
		fixture.buttons.highlight(nil, byKey: false)
		#expect(try !fixture.press(36))
		#expect(fixture.pressed == [])
	}

	@Test func theRingDrawsAroundTheButton() {
		let plain = pixels(of: Button("Open") {}.padding(8).keyFocusRing(false).padding(8))
		let ring = pixels(of: Button("Open") {}.padding(8).keyFocusRing(true).padding(8))
		#expect(plain != nil && ring != nil && plain != ring)
	}

	@Test func theReportButtonsGoFromLeftToRight() throws {
		let fixture = try ReportFixture()
		defer { fixture.cleanUp() }
		let buttons = ReportButtons(report: fixture.report) {}.keyButtons
		let ids = fixture.report.kind.statsFileName == nil ? ["update", "open"] : ["update", "open", "stats"]
		#expect(buttons.map(\.id) == ids)
		#expect(buttons.first?.isEnabled == true)
	}

	private func pixels(of view: some View) -> Data? {
		ImageRenderer(content: view).nsImage?.tiffRepresentation
	}
}
