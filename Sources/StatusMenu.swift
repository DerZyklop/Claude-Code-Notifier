import AppKit
import Combine
import ServiceManagement

/// The menu bar item and its menu. AppKit instead of a SwiftUI `MenuBarExtra`, because only an `NSMenuItem` can align
/// the time of a session to the right.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
	private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
	private let menu = NSMenu()
	private var subscriptions = Set<AnyCancellable>()

	/// Updates the running times of the sessions every second while the menu is open.
	private var clock: Timer?
	private var sessionItems: [(item: NSMenuItem, session: Session)] = []

	override init() {
		super.init()
		menu.delegate = self
		statusItem.menu = menu

		// `objectWillChange` fires before the change, so the update waits for the next turn of the main queue.
		Publishers.Merge3(SessionStore.shared.objectWillChange, HookSetup.shared.objectWillChange, Spinner.shared.objectWillChange)
			.receive(on: DispatchQueue.main)
			.sink { [weak self] _ in self?.updateIcon() }
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
			button.image = Spinner.shared.image(workingCount: working)
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
		menu.addItem(.separator())

		let sessions = store.sortedSessions
		if sessions.isEmpty {
			menu.addItem(NSMenuItem(title: "No Claude Code sessions yet", action: nil, keyEquivalent: ""))
		}
		// Display only: without an action, the item is disabled. Its attributed title keeps the normal text color.
		sessionItems = sessions.map { session in
			let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
			item.image = Self.symbol(session.state.symbol)
			menu.addItem(item)
			return (item, session)
		}
		updateSessionTitles()
		if sessions.contains(where: { $0.state == .ended }) {
			menu.addItem(action("Remove Ended Sessions", #selector(removeEnded)))
		}
		menu.addItem(.separator())

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
			Task { @MainActor in self?.updateSessionTitles() }
		}
		// The `common` modes include the one the run loop uses while a menu is open.
		RunLoop.main.add(timer, forMode: .common)
		clock = timer
	}

	func menuDidClose(_ menu: NSMenu) {
		clock?.invalidate()
		clock = nil
	}

	/// The session on the left, its running time on the right: a right-aligned tab stop behind the widest text.
	private func updateSessionTitles() {
		let font = NSFont.menuFont(ofSize: 0)
		let timeFont = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
		let rows = sessionItems.map { (item: $0.item, left: "\($0.session.project) – \($0.session.state.title)", right: Self.elapsed(since: $0.session.started)) }
		let leftWidth = rows.map { ($0.left as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
		let rightWidth = rows.map { ($0.right as NSString).size(withAttributes: [.font: timeFont]).width }.max() ?? 0

		let paragraph = NSMutableParagraphStyle()
		paragraph.tabStops = [NSTextTab(textAlignment: .right, location: ceil(leftWidth + 32 + rightWidth))]
		for row in rows {
			let title = NSMutableAttributedString(string: row.left + "\t", attributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
			title.append(NSAttributedString(string: row.right, attributes: [.font: timeFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]))
			row.item.attributedTitle = title
		}
	}

	/// A running clock: »4:07«, or »1:04:07« from one hour on.
	private static func elapsed(since start: Date) -> String {
		let seconds = max(0, Int(Date().timeIntervalSince(start)))
		let (hours, minutes, rest) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
		return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
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
