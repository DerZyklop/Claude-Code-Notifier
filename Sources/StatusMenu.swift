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

	/// A session that asks you wins over a working one: it needs you now.
	private func updateIcon() {
		guard let button = statusItem.button else { return }
		let sessions = SessionStore.shared.sessions.values
		let waiting = sessions.filter { $0.state == .asksYou }.count
		let working = sessions.filter { $0.state == .working }.count

		button.title = ""
		if HookSetup.shared.hasProblem {
			button.image = Self.symbol("bell.slash")
		} else if waiting > 0 {
			button.image = Self.symbol("bell.badge.fill")
			button.title = " \(waiting)"
		} else if working > 0 {
			let isDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
			button.image = Spinner.shared.image(workingCount: working, isDark: isDark)
		} else {
			button.image = Self.symbol("bell")
		}
		button.imagePosition = .imageLeading
	}

	// MARK: - Menu

	func menuNeedsUpdate(_ menu: NSMenu) {
		menu.removeAllItems()
		let setup = HookSetup.shared
		let store = SessionStore.shared

		if !setup.isListening {
			menu.addItem(action("⚠︎ Not Listening – Open Setup …", #selector(showSetup)))
		} else if setup.notificationsAllowed == false {
			menu.addItem(action("⚠︎ Notifications Blocked – Open Setup …", #selector(showSetup)))
		} else if setup.hasProblem {
			menu.addItem(action("⚠︎ Hooks Not Working – Open Setup …", #selector(showSetup)))
		} else {
			menu.addItem(NSMenuItem(title: "Listening on 127.0.0.1:\(eventPort)", action: nil, keyEquivalent: ""))
		}

		clock.tick()
		let card = NSHostingView(rootView: SessionCard(store: store, clock: clock))
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

		menu.addItem(toggle("Notify When It Is Your Turn", SettingsKey.notifyOnDone))
		menu.addItem(toggle("Notify When a Session Ends", SettingsKey.notifyOnSessionEnd))
		menu.addItem(toggle("Play Sound", SettingsKey.playsSound))
		menu.addItem(toggle("Mute All Notifications", SettingsKey.muted, default: false))

		let tests = NSMenu()
		for kind in NotificationKind.allCases {
			let item = action(kind.subtitle, #selector(sendTestNotification(_:)))
			item.representedObject = kind
			tests.addItem(item)
		}
		let testsItem = NSMenuItem(title: "Send Test Notification", action: nil, keyEquivalent: "")
		testsItem.submenu = tests
		menu.addItem(testsItem)

		let launchAtLogin = action("Launch at Login", #selector(toggleLaunchAtLogin))
		launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
		menu.addItem(launchAtLogin)
		menu.addItem(action("Hook Setup …", #selector(showSetup)))
		menu.addItem(.separator())
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
		NSHostingView(rootView: SessionCard(store: SessionStore.shared, clock: clock)).fittingSize
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
