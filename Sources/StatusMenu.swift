import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// The menu bar item and its menu. AppKit instead of a SwiftUI `MenuBarExtra`, because only an `NSMenuItem` can hold
/// a custom view like ``SessionCard``.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
	private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
	private let menu = NSMenu()
	private var subscriptions = Set<AnyCancellable>()

	/// Updates the running times of the sessions every second while the menu is open.
	private var timer: Timer?
	private let clock = MenuClock()
	private var card: NSHostingView<SessionCard>?

	override init() {
		super.init()
		menu.delegate = self
		statusItem.menu = menu

		// `objectWillChange` fires before the change, so the update waits for the next turn of the main queue.
		Publishers.Merge3(SessionStore.shared.objectWillChange, HookSetup.shared.objectWillChange, Spinner.shared.objectWillChange)
			.receive(on: DispatchQueue.main)
			.sink { [weak self] _ in
				self?.updateIcon()
				self?.fitCard()
			}
			.store(in: &subscriptions)
		updateIcon()
	}

	/// The spinner while sessions work, else the sparkle. Sessions that ask you add an orange question bubble with their
	/// count, so that a forgotten prompt does not hide the work in other sessions.
	private func updateIcon() {
		guard let button = statusItem.button else { return }
		let sessions = SessionStore.shared.sessions.values
		let waiting = sessions.filter { $0.state == .asksYou }.count
		let working = sessions.filter { $0.state == .working }.count

		button.imagePosition = .imageLeading
		if HookSetup.shared.hasProblem {
			button.image = Self.crossedOutSparkle
			button.title = ""
			return
		}
		if working > 0 {
			button.image = Spinner.shared.image(workingCount: working)
		} else {
			button.image = Self.sparkle
		}
		button.attributedTitle = waiting > 0 ? Self.waitingBadge(count: waiting) : NSAttributedString()
	}

	/// An orange speech bubble with the count in white inside it, in the color of »asks you« in the card.
	private static func waitingBadge(count: Int) -> NSAttributedString {
		let font = NSFont.menuBarFont(ofSize: 0)
		let title = NSMutableAttributedString(string: " ", attributes: [.font: font])
		let configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize + 2, weight: .regular)
			.applying(NSImage.SymbolConfiguration(paletteColors: [.systemOrange]))
		guard let bubble = NSImage(systemSymbolName: "bubble.left.fill", accessibilityDescription: "\(count) asking")?.withSymbolConfiguration(configuration) else { return title }

		let image = NSImage(size: bubble.size, flipped: false) { rect in
			bubble.draw(in: rect)
			// The body of the bubble is above its tail, so the number centers in the upper part.
			let text = count > 9 ? "9+" : "\(count)"
			let numberFont = NSFont.monospacedDigitSystemFont(ofSize: count > 9 ? 7.5 : 10, weight: .bold)
			let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: numberFont, .foregroundColor: NSColor.white]))
			let outline = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
			guard let context = NSGraphicsContext.current?.cgContext else { return true }
			context.textPosition = CGPoint(x: rect.midX - outline.midX, y: rect.minY + rect.height * 0.58 - outline.midY)
			CTLineDraw(line, context)
			return true
		}
		let attachment = NSTextAttachment()
		attachment.image = image
		attachment.bounds = NSRect(x: 0, y: font.descender, width: image.size.width, height: image.size.height)
		title.append(NSAttributedString(attachment: attachment))
		return title
	}

	private static let sparkle: NSImage? = {
		let image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Claude Code Notifier")?
			.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
		image?.isTemplate = true
		return image
	}()

	/// The sparkle with a diagonal line, for a setup problem. macOS has no crossed-out sparkle symbol. Like the system's
	/// crossed-out symbols, the line has a small gap on each side.
	private static let crossedOutSparkle: NSImage? = {
		guard let sparkle else { return nil }
		let image = NSImage(size: sparkle.size, flipped: false) { rect in
			sparkle.draw(in: rect)
			let inset = rect.width * 0.12
			let line = NSBezierPath()
			line.move(to: NSPoint(x: rect.minX + inset, y: rect.maxY - inset))
			line.line(to: NSPoint(x: rect.maxX - inset, y: rect.minY + inset))
			line.lineCapStyle = .round
			NSGraphicsContext.current?.compositingOperation = .clear
			line.lineWidth = 3.2
			line.stroke()
			NSGraphicsContext.current?.compositingOperation = .sourceOver
			line.lineWidth = 1.2
			NSColor.black.setStroke()
			line.stroke()
			return true
		}
		image.isTemplate = true
		return image
	}()

	// MARK: - Menu

	/// Three groups: the sessions with the status of the app, the notification settings, and the app itself.
	func menuNeedsUpdate(_ menu: NSMenu) {
		menu.removeAllItems()
		let setup = HookSetup.shared
		let store = SessionStore.shared

		// A problem gets a clickable item above the card. The card header names the problem too.
		if setup.hasProblem {
			menu.addItem(action("⚠︎ \(setup.problem ?? "Setup Incomplete") – Open Setup …", #selector(showSetup)))
		}
		clock.tick()
		let card = NSHostingView(rootView: sessionCard())
		// The menu sets the width, and ``fitCard()`` sets the height.
		card.sizingOptions = []
		card.autoresizingMask = [.width]
		card.frame.size = cardSize()
		self.card = card
		let cardItem = NSMenuItem()
		cardItem.view = card
		menu.addItem(cardItem)
		if store.sessions.values.contains(where: { $0.state == .ended }) {
			menu.addItem(action("Remove Ended Sessions", #selector(removeEnded)))
		}

		menu.addItem(.separator())
		menu.addItem(sectionHeader("Notifications"))
		menu.addItem(toggle("When It Is Your Turn", SettingsKey.notifyOnDone))
		menu.addItem(toggle("When a Session Ends", SettingsKey.notifyOnSessionEnd))
		menu.addItem(toggle("Play Sound", SettingsKey.playsSound))
		menu.addItem(toggle("Mute All", SettingsKey.muted, default: false))
		let tests = NSMenu()
		for kind in NotificationKind.allCases {
			let item = action(kind.subtitle, #selector(sendTestNotification(_:)))
			item.representedObject = kind
			tests.addItem(item)
		}
		let testsItem = NSMenuItem(title: "Send Test", action: nil, keyEquivalent: "")
		testsItem.submenu = tests
		menu.addItem(testsItem)

		menu.addItem(.separator())
		let launchAtLogin = action("Launch at Login", #selector(toggleLaunchAtLogin))
		launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
		menu.addItem(launchAtLogin)
		menu.addItem(action("Hook Setup …", #selector(showSetup)))
		let quit = action("Quit Claude Code Notifier", #selector(quit))
		quit.keyEquivalent = "q"
		menu.addItem(quit)
	}

	func menuWillOpen(_ menu: NSMenu) {
		let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
			Task { @MainActor in self?.clock.tick() }
		}
		// The `common` modes include the one the run loop uses while a menu is open.
		RunLoop.main.add(timer, forMode: .common)
		self.timer = timer
	}

	func menuDidClose(_ menu: NSMenu) {
		timer?.invalidate()
		timer = nil
	}

	/// The size that the card needs. The card in the menu cannot measure itself, because it leaves its size to the menu,
	/// so a second view with the same content measures it.
	private func cardSize() -> NSSize {
		NSHostingView(rootView: sessionCard()).fittingSize
	}

	private func sessionCard() -> SessionCard {
		SessionCard(store: SessionStore.shared, setup: HookSetup.shared, clock: clock)
	}

	/// Gives the card the height of its rows, e.g. when a session starts while the menu is open.
	private func fitCard() {
		guard let card else { return }
		let height = cardSize().height
		if card.frame.height != height { card.frame.size.height = height }
	}

	// MARK: - Items

	private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
		let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
		item.target = self
		return item
	}

	private func sectionHeader(_ title: String) -> NSMenuItem {
		if #available(macOS 14, *) { return .sectionHeader(title: title) }
		return NSMenuItem(title: title, action: nil, keyEquivalent: "")
	}

	private func toggle(_ title: String, _ key: String, default defaultValue: Bool = true) -> NSMenuItem {
		let item = action(title, #selector(toggleSetting(_:)))
		item.representedObject = (key, defaultValue)
		item.state = (UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue) ? .on : .off
		return item
	}

	private static func symbol(_ name: String) -> NSImage? {
		let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
		image?.isTemplate = true
		return image
	}

	// MARK: - Actions

	@objc private func removeEnded() {
		SessionStore.shared.removeEnded()
	}

	@objc private func toggleSetting(_ sender: NSMenuItem) {
		guard let (key, defaultValue) = sender.representedObject as? (String, Bool) else { return }
		let current = UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
		UserDefaults.standard.set(!current, forKey: key)
	}

	@objc private func sendTestNotification(_ sender: NSMenuItem) {
		guard let kind = sender.representedObject as? NotificationKind else { return }
		SessionStore.shared.sendTestNotification(kind)
	}

	@objc private func toggleLaunchAtLogin() {
		if SMAppService.mainApp.status == .enabled {
			try? SMAppService.mainApp.unregister()
		} else {
			try? SMAppService.mainApp.register()
		}
	}

	@objc private func showSetup() {
		SetupWindow.show()
	}

	@objc private func quit() {
		NSApp.terminate(nil)
	}
}
