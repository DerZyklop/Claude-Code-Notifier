import AppKit
import SwiftUI

/// The parts of ``SessionCard`` that the menu shows now. The view of each menu item reads its part from here, so a
/// change of the sessions changes the views in place.
@MainActor
final class SessionCardModel: ObservableObject {
	@Published var parts: [SessionCard.Part] = []
	/// The place of the part whose menu item is highlighted, by the pointer or by the arrow keys.
	@Published var highlightedSlot: Int?
	/// Whether the menu highlights an item at all, also one outside the card.
	@Published var hasHighlight = false
}

/// The menu items of ``SessionCard``: one item for each part, so that the arrow keys reach each session. Return opens
/// the chat of the highlighted session, like a click on its row. Only the item of a session is enabled, so the arrow
/// keys skip the other parts.
/// An item shows the part at its place, not a fixed session. When the order of the sessions changes, the items stay
/// and their views change. So the highlight of the menu keeps its place.
@MainActor
final class SessionCardItems: NSObject {
	let model = SessionCardModel()
	/// The items of the last ``add(to:)``, in the order of ``SessionCardModel/parts``.
	private(set) var items: [NSMenuItem] = []
	private weak var menu: NSMenu?
	private let store: SessionStore
	private let setup: HookSetup
	private let clock: MenuClock
	private let running: () -> [(title: String, started: Date?)]
	private let open: (Session) -> Void

	/// - Parameters:
	///   - running: The title and the start of each running report. They get a row above the sessions.
	///   - open: Opens the chat of a session, for a click and for a key of ``MenuItemKeyView/chooseKeys``.
	init(store: SessionStore, setup: HookSetup, clock: MenuClock, running: @escaping () -> [(title: String, started: Date?)] = { [] },
		open: @escaping (Session) -> Void) {
		self.store = store
		self.setup = setup
		self.clock = clock
		self.running = running
		self.open = open
	}

	/// Adds the items of the card at the end of `menu`. The card enables only the items of the sessions, also while
	/// the menu is open. So the menu does not enable its items itself from now on.
	func add(to menu: NSMenu) {
		menu.autoenablesItems = false
		self.menu = menu
		items = []
		model.parts = []
		highlight(nil)
		sync()
	}

	/// Forgets the menu. Only the items of an open menu need ``sync()``.
	func close() {
		menu = nil
		highlight(nil)
	}

	/// Makes the items match the sessions and the running reports, e.g. when a session starts while the menu is open.
	func sync() {
		guard let menu else { return }
		let old = model.parts
		let parts = SessionCard.parts(sessions: store.sortedSessions, order: store.projectOrder, running: running(),
			hasHidden: !store.hiddenStates.isEmpty)
		// A new item measures its part, so the parts come first.
		if parts != old { model.parts = parts }
		while items.count > parts.count { menu.removeItem(items.removeLast()) }
		// An item that comes later gets the width of the card, so that the open menu does not get wider.
		let width = old.isEmpty ? nil : items.first?.view?.frame.width
		while items.count < parts.count {
			let item = makeItem(slot: items.count, width: width)
			menu.insertItem(item, at: items.last.map { menu.index(of: $0) + 1 } ?? menu.numberOfItems)
			items.append(item)
		}
		for (slot, part) in parts.enumerated() {
			let item = items[slot]
			// The view draws the item. The title is for the type-select of the menu.
			let title = part.session?.name ?? ""
			if item.title != title { item.title = title }
			if item.isEnabled != (part.session != nil) { item.isEnabled = part.session != nil }
			if slot < old.count, !part.hasHeight(of: old[slot]) { item.view?.frame.size.height = size(ofSlot: slot).height }
		}
		// The highlighted item can show a part without a session now, or be gone.
		if let slot = model.highlightedSlot, !(slot < parts.count && parts[slot].session != nil) { highlight(nil) }
	}

	/// Tells the card which item the menu highlights now, see `menu(_:willHighlight:)`. Only the view of this item
	/// takes the keys.
	func highlight(_ item: NSMenuItem?) {
		let slot = item.flatMap { session(of: $0) == nil ? nil : items.firstIndex(of: $0) }
		if model.highlightedSlot != slot { model.highlightedSlot = slot }
		if model.hasHighlight != (item != nil) { model.hasHighlight = item != nil }
		for (index, cardItem) in items.enumerated() { (cardItem.view as? MenuItemKeyView)?.takesKeys = index == slot }
	}

	/// The session that `item` shows now.
	func session(of item: NSMenuItem) -> Session? {
		guard let slot = items.firstIndex(of: item), model.parts.indices.contains(slot) else { return nil }
		return model.parts[slot].session
	}

	/// - Parameter width: The width of the view, or `nil` for the width that the part needs. The menu is at least as
	///   wide as the view of each new item.
	private func makeItem(slot: Int, width: CGFloat?) -> NSMenuItem {
		let card = NSHostingView(rootView: card(slot: slot))
		// Measured before `sizingOptions` is empty: then the view leaves its size to the menu and measures 0.
		card.frame.size = size(ofSlot: slot, in: card)
		if let width { card.frame.size.width = width }
		card.sizingOptions = []
		let view = MenuItemKeyView(content: card)
		// The menu sets the width.
		view.autoresizingMask = [.width]
		let item = NSMenuItem()
		item.view = view
		item.isEnabled = false
		// Opens the session that the item shows at the time of the key, see ``sync()``.
		view.handle = { [weak self, weak item] event in
			guard MenuItemKeyView.chooseKeys.contains(event.keyCode) else { return false }
			if let self, let item, let session = self.session(of: item) { self.open(session) }
			return true
		}
		return item
	}

	/// The size that the part at `slot` needs, with a height in whole points, so that the parts touch without a gap.
	/// The view of an item cannot measure itself later, because it leaves its size to the menu. Then a second view with
	/// the same content measures it.
	private func size(ofSlot slot: Int, in view: NSHostingView<SessionCard>? = nil) -> NSSize {
		let size = (view ?? NSHostingView(rootView: card(slot: slot))).fittingSize
		return NSSize(width: size.width, height: size.height.rounded(.up))
	}

	private func card(slot: Int) -> SessionCard {
		SessionCard(model: model, slot: slot, setup: setup, clock: clock, open: open, hide: { [store] in store.hide($0.id) },
			toggleImportant: { [store] in store.toggleImportant($0.id) })
	}
}
