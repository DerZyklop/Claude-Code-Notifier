import AppKit
import SwiftUI

/// The view of a menu item with a custom view that takes the keys. The menu sends no action for Return on such an item.
/// It gives the key to the view that has the key focus. So the view of the highlighted item takes the key focus. The
/// menu moves the highlight for the arrow keys up and down itself, and then gives these keys to the view too.
final class MenuItemKeyView: NSView {
	/// Return, Enter and Space, the keys that choose an item of a menu.
	static let chooseKeys: Set<UInt16> = [36, 76, 49]

	/// Handles a key while the view takes the keys, and tells whether it did. The menu gets the other keys.
	var handle: (NSEvent) -> Bool = { _ in false }
	/// Whether the item is highlighted. Only then, the view takes the keys: a menu that opens highlights the item of
	/// the first view that takes them.
	var takesKeys = false {
		didSet {
			guard takesKeys != oldValue, let window else { return }
			if takesKeys {
				window.makeFirstResponder(self)
			} else if window.firstResponder === self {
				window.makeFirstResponder(nil)
			}
		}
	}

	/// - Parameter content: Fills the view. The view gets its size.
	init(content: NSView) {
		super.init(frame: content.frame)
		content.frame.origin = .zero
		content.autoresizingMask = [.width, .height]
		addSubview(content)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) is not available")
	}

	override var acceptsFirstResponder: Bool { takesKeys }

	/// Handles `event` with ``handle`` if the view takes the keys, and tells whether it did.
	func handleKey(_ event: NSEvent) -> Bool {
		takesKeys && event.type == .keyDown && handle(event)
	}

	override func keyDown(with event: NSEvent) {
		if !handleKey(event) { super.keyDown(with: event) }
	}
}

/// A button in the view of a menu item, for the keys. See ``MenuButtonsItem``.
struct MenuKeyButton {
	let id: String
	let isEnabled: Bool
	let press: @MainActor () -> Void
}

/// The button of a menu item that the keys press. The view of the item draws a focus ring around it.
@MainActor
final class MenuButtonFocus: ObservableObject {
	/// The ID of the button with the ring. `nil` until a key moves the highlight to the item or a key is pressed on it.
	@Published var buttonID: String?
}

/// A menu item whose view shows a row of buttons. The arrow keys stop at the item. Then the left and right arrow keys
/// move the focus ring from button to button, and Return, Enter and Space press the button with the ring.
@MainActor
final class MenuButtonsItem {
	static let leftKey: UInt16 = 123
	static let rightKey: UInt16 = 124

	let item = NSMenuItem()
	let focus: MenuButtonFocus
	private let view: MenuItemKeyView
	private let main: String
	private let buttons: @MainActor () -> [MenuKeyButton]

	/// - Parameters:
	///   - title: For the type-select of the menu.
	///   - content: The view with the buttons. It reads ``focus``.
	///   - main: The ID of the button that gets the ring first. If it is disabled, the first enabled button gets it.
	///   - buttons: The buttons of `content` from left to right, at the time of the key.
	init(title: String, content: NSView, focus: MenuButtonFocus, main: String, buttons: @escaping @MainActor () -> [MenuKeyButton]) {
		self.focus = focus
		self.main = main
		self.buttons = buttons
		view = MenuItemKeyView(content: content)
		// The menu sets the width.
		view.autoresizingMask = [.width]
		item.title = title
		item.view = view
		item.isEnabled = true
		view.handle = { [weak self] in self?.handle($0) ?? false }
	}

	/// Whether the view of the item takes the keys now.
	var takesKeys: Bool { view.takesKeys }

	/// Tells the item which item the menu highlights now, see `menu(_:willHighlight:)`.
	/// - Parameter byKey: Whether a key moved the highlight. Only then, the main button gets the ring.
	func highlight(_ highlighted: NSMenuItem?, byKey: Bool) {
		let isHighlighted = highlighted === item
		// The menu tells the same highlight more than once.
		guard isHighlighted != view.takesKeys else { return }
		view.takesKeys = isHighlighted
		focus.buttonID = isHighlighted && byKey ? mainID(in: buttons().filter(\.isEnabled)) : nil
	}

	/// A key without a ring, or with the ring on a button that is disabled now, only puts the ring on the main button.
	private func handle(_ event: NSEvent) -> Bool {
		let isChoose = MenuItemKeyView.chooseKeys.contains(event.keyCode)
		guard isChoose || [Self.leftKey, Self.rightKey].contains(event.keyCode) else { return false }
		let enabled = buttons().filter(\.isEnabled)
		guard let index = enabled.firstIndex(where: { $0.id == focus.buttonID }) else {
			focus.buttonID = mainID(in: enabled)
			return true
		}
		if isChoose {
			enabled[index].press()
		} else {
			let next = index + (event.keyCode == Self.rightKey ? 1 : -1)
			if enabled.indices.contains(next) { focus.buttonID = enabled[next].id }
		}
		return true
	}

	private func mainID(in enabled: [MenuKeyButton]) -> String? {
		enabled.contains { $0.id == main } ? main : enabled.first?.id
	}
}

extension View {
	/// The focus ring of the keys around a button, see ``MenuButtonsItem``. The button does not take the key focus of
	/// the system: else the menu highlights its item at once when it opens.
	func keyFocusRing(_ isFocused: Bool) -> some View {
		focusable(false).overlay {
			if isFocused {
				RoundedRectangle(cornerRadius: 6)
					.strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
					.padding(-3)
					.allowsHitTesting(false)
			}
		}
	}
}
