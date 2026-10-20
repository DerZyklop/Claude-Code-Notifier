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
	private lazy var spinner = Spinner(button: statusItem.button!)
	/// The icons with a bubble, by their content and the menu bar appearance.
	private var iconCache: [String: NSImage] = [:]
	private var appearanceObservation: NSKeyValueObservation?

	override init() {
		super.init()
		menu.delegate = self
		statusItem.menu = menu

		// `objectWillChange` fires before the change, so the update waits for the next turn of the main queue.
		Publishers.Merge(SessionStore.shared.objectWillChange, HookSetup.shared.objectWillChange)
			.receive(on: DispatchQueue.main)
			.sink { [weak self] _ in self?.updateIcon() }
			.store(in: &subscriptions)
		// Only the sessions change the height of the card. Measuring it builds a view, so other changes skip it.
		SessionStore.shared.objectWillChange
			.receive(on: DispatchQueue.main)
			.sink { [weak self] _ in self?.fitCard() }
			.store(in: &subscriptions)
		// An icon with a bubble colors its left part itself, see ``icon(left:key:waiting:isDark:)``.
		appearanceObservation = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
			Task { @MainActor in self?.updateIcon() }
		}
		updateIcon()
	}

	/// The spinner while sessions work, else the sparkle. Sessions that ask you add an orange bubble with their count,
	/// so that a forgotten prompt does not hide the work in other sessions.
	private func updateIcon() {
		guard let button = statusItem.button else { return }
		let sessions = SessionStore.shared.sessions.values
		let waiting = HookSetup.shared.hasProblem ? 0 : sessions.filter { $0.state == .asksYou }.count
		let working = sessions.filter { $0.shownState == .working }.count
		let isSpinning = working > 0 && !HookSetup.shared.hasProblem

		let (left, key) = HookSetup.shared.hasProblem ? (Self.crossedOutSparkle, "problem")
			: isSpinning ? (spinner.image(workingCount: working), "spinner-\(min(working, 10))")
			: (Self.sparkle, "sparkle")
		let isDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
		let image = left.map { icon(left: $0, key: key, waiting: waiting, isDark: isDark) }
		if button.image !== image { button.image = image }
		button.title = ""

		// The left part of the icon is at its left edge, vertically centered.
		button.layoutSubtreeIfNeeded()
		let frame = button.cell?.imageRect(forBounds: button.bounds)
		spinner.show(around: isSpinning ? frame.map { NSRect(x: $0.minX, y: $0.midY - Spinner.size.height / 2, width: Spinner.size.width, height: Spinner.size.height) } : nil)
	}

	/// The left image alone as a template image, or together with the bubble of the waiting sessions. A combined icon
	/// cannot be a template image, because the menu bar would color the bubble too. So it colors the left part itself.
	/// Drawn in one image, the bubble sits 2 pt from the spinner. As the title of the button, it kept a wider gap.
	private func icon(left: NSImage, key: String, waiting: Int, isDark: Bool) -> NSImage {
		guard waiting > 0 else { return left }
		let cacheKey = "\(key)-\(min(waiting, 10))-\(isDark)"
		if let image = iconCache[cacheKey] { return image }
		let bubble = Self.bubble(count: waiting)
		let gap = 2.0
		let size = NSSize(width: left.size.width + gap + bubble.size.width, height: max(left.size.height, bubble.size.height))
		let color = isDark ? NSColor.white : NSColor.black.withAlphaComponent(0.85)
		let image = NSImage(size: size, flipped: false) { rect in
			let leftRect = NSRect(x: 0, y: (rect.height - left.size.height) / 2, width: left.size.width, height: left.size.height)
			let tinted = NSImage(size: left.size, flipped: false) { tintRect in
				left.draw(in: tintRect)
				color.set()
				tintRect.fill(using: .sourceAtop)
				return true
			}
			tinted.draw(in: leftRect)
			bubble.draw(in: NSRect(x: left.size.width + gap, y: (rect.height - bubble.size.height) / 2, width: bubble.size.width, height: bubble.size.height))
			return true
		}
		iconCache[cacheKey] = image
		return image
	}

	/// An orange speech bubble with the count in white inside it, in the color of »asks you« in the card. Space above
	/// the bubble makes the middle of its body the middle of the image, so the body lines up with the spinner and the
	/// tail hangs below.
	private static func bubble(count: Int) -> NSImage {
		let configuration = NSImage.SymbolConfiguration(pointSize: NSFont.menuBarFont(ofSize: 0).pointSize + 4, weight: .regular)
			.applying(NSImage.SymbolConfiguration(paletteColors: [.systemOrange]))
		guard let bubble = NSImage(systemSymbolName: "bubble.left.fill", accessibilityDescription: "\(count) asking")?.withSymbolConfiguration(configuration) else { return NSImage() }
		let bodyMiddle = bubble.size.height * 0.58
		let size = NSSize(width: bubble.size.width, height: (bodyMiddle * 2).rounded(.up))
		return NSImage(size: size, flipped: false) { rect in
			bubble.draw(in: NSRect(origin: rect.origin, size: bubble.size))
			Spinner.drawCount(count, at: NSPoint(x: rect.midX, y: rect.minY + bodyMiddle), color: .white)
			return true
		}
	}

	/// On the canvas of the spinner, so that the icon keeps its width when the spinner starts or stops.
	private static let sparkle: NSImage? = {
		guard let symbol = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Claude Code Notifier")?
			.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)) else { return nil }
		let image = NSImage(size: Spinner.size, flipped: false) { rect in
			symbol.draw(in: NSRect(x: rect.midX - symbol.size.width / 2, y: rect.midY - symbol.size.height / 2, width: symbol.size.width, height: symbol.size.height))
			return true
		}
		image.isTemplate = true
		return image
	}()

	/// The sparkle with a diagonal line, for a setup problem. macOS has no crossed-out sparkle symbol. Like the system's
	/// crossed-out symbols, the line has a small gap on each side.
	private static let crossedOutSparkle: NSImage? = {
		guard let sparkle else { return nil }
		let image = NSImage(size: sparkle.size, flipped: false) { rect in
			sparkle.draw(in: rect)
			let inset = rect.width * 0.2
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
