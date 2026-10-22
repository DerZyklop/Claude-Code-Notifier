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
	/// Above the waves, because ``updateIcon()`` creates it after ``spinner``.
	private lazy var attention = AttentionBubble(button: statusItem.button!)
	/// The sessions whose turn runs, to notice when one starts to work.
	private var workingTurnIDs: Set<String> = []
	/// The icons, by their layout and the menu bar appearance.
	private var iconCache: [String: NSImage] = [:]
	private var appearanceObservation: NSKeyValueObservation?

	override init() {
		super.init()
		menu.delegate = self
		statusItem.menu = menu
		statusItem.button?.title = ""
		statusItem.button?.imagePosition = .imageOnly

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
		// The app colors the number and the still wave itself, see ``textColor(isDark:)``.
		appearanceObservation = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
			Task { @MainActor in self?.updateIcon() }
		}
		updateIcon()
	}

	/// The icon always has the same width, so that the menu bar never shifts. From the right: the bubble of the waiting
	/// sessions, the number of working sessions, and the wave in the space that is left. Without work, the wave stands
	/// still in the menu bar color, and a setup problem breaks it in the middle. Sessions that ask you get the bubble, so that a forgotten prompt does not hide the work in other sessions.
	private func updateIcon() {
		guard let button = statusItem.button else { return }
		let sessions = SessionStore.shared.sessions.values
		let hasProblem = HookSetup.shared.hasProblem
		let waiting = hasProblem ? 0 : sessions.filter { $0.state == .asksYou }.count
		let working = hasProblem ? 0 : sessions.filter { $0.shownState == .working }.count
		// An answer lets a session work again, so the chime may play again for the next question.
		let turnIDs = Set(sessions.filter { $0.state == .working }.map(\.id))
		if !turnIDs.isSubset(of: workingTurnIDs) { attention.restartChimeTime() }
		workingTurnIDs = turnIDs
		let isDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
		let layout = Self.layout(working: working, waiting: waiting)

		let image = icon(layout: layout, isDark: isDark)
		if button.image !== image { button.image = image }
		button.layoutSubtreeIfNeeded()
		let imageFrame = button.cell?.imageRect(forBounds: button.bounds)
		spinner.show(waveEnd: layout.waveEnd, over: imageFrame, isWorking: working > 0,
			hasGap: hasProblem, stillColor: Self.textColor(isDark: isDark))
		// The bubble is centered vertically, so its frame is the same with and without a flipped y axis.
		let bubbleSize = Self.bubble(count: 1).size
		let bubbleFrame = imageFrame.flatMap { frame in
			layout.bubbleX.map { NSRect(x: frame.minX + $0, y: frame.midY - bubbleSize.height / 2, width: bubbleSize.width, height: bubbleSize.height) }
		}
		attention.show(count: layout.waiting, image: { Self.bubble(count: layout.waiting, color: $0) }, in: bubbleFrame)
		spinner.glow(with: attention)
	}

	static let iconWidth = 58.0
	static let gap = 2.0
	/// The number of working sessions reads as »×2«: two times the wave.
	static let workingPrefix = "×"

	/// Where the parts of the icon go.
	struct IconLayout: Hashable {
		var working = 0
		var waiting = 0
		/// The wave runs from the left end to here.
		var waveEnd = 0.0
		var numberCenterX: Double?
		var bubbleX: Double?
	}

	static func layout(working: Int, waiting: Int) -> IconLayout {
		var layout = IconLayout(working: min(working, 10), waiting: min(waiting, 10))
		var right = iconWidth
		if waiting > 0 {
			right -= bubbleWidth
			layout.bubbleX = right
			right -= gap
		}
		if working > 1 {
			let width = Spinner.countWidth(working, prefix: workingPrefix)
			layout.numberCenterX = right - width / 2
			right -= width + 2 * gap
		}
		layout.waveEnd = right
		return layout
	}

	static let bubbleWidth = bubble(count: 1).size.width

	/// The menu bar color, for the still wave and the number.
	static func textColor(isDark: Bool) -> NSColor {
		isDark ? NSColor.white : NSColor.black.withAlphaComponent(0.85)
	}

	/// The number in one image, above which ``Spinner`` draws the wave and ``AttentionBubble`` the bubble. The image
	/// keeps the height of the bubble, so the parts stay centered. It cannot be a template image, because the number
	/// must match the colors of the layers, so it colors the number itself.
	private func icon(layout: IconLayout, isDark: Bool) -> NSImage {
		let cacheKey = "\(layout)-\(isDark)"
		if let image = iconCache[cacheKey] { return image }
		let height = max(18, Self.bubble(count: 1).size.height)
		let color = Self.textColor(isDark: isDark)
		let image = NSImage(size: NSSize(width: Self.iconWidth, height: height), flipped: false) { rect in
			if let x = layout.numberCenterX {
				Spinner.drawCount(layout.working, at: NSPoint(x: x, y: rect.midY), color: color, prefix: Self.workingPrefix)
			}
			return true
		}
		iconCache[cacheKey] = image
		return image
	}

	/// An orange speech bubble with the count in white inside it from two sessions on, in the color of »asks you« in the card. Space above
	/// the bubble makes the middle of its body the middle of the image, so the body lines up with the spinner and the
	/// tail hangs below.
	static func bubble(count: Int, color: NSColor = .systemOrange) -> NSImage {
		let configuration = NSImage.SymbolConfiguration(pointSize: NSFont.menuBarFont(ofSize: 0).pointSize + 4, weight: .regular)
			.applying(NSImage.SymbolConfiguration(paletteColors: [color]))
		guard let bubble = NSImage(systemSymbolName: "bubble.left.fill", accessibilityDescription: "\(count) asking")?.withSymbolConfiguration(configuration) else { return NSImage() }
		let bodyMiddle = bubble.size.height * 0.58
		let size = NSSize(width: bubble.size.width, height: (bodyMiddle * 2).rounded(.up))
		return NSImage(size: size, flipped: false) { rect in
			bubble.draw(in: NSRect(origin: rect.origin, size: bubble.size))
			// One waiting session needs no number: the bubble alone says it.
			if count > 1 { Spinner.drawCount(count, at: NSPoint(x: rect.midX, y: rect.minY + bodyMiddle), color: .white) }
			return true
		}
	}

	// MARK: - Menu

	/// Three groups: the sessions with the status of the app, the notification settings, and the app itself.
	func menuNeedsUpdate(_ menu: NSMenu) {
		menu.removeAllItems()

		// A problem gets a clickable item above the card. The card header names the problem too.
		if let problem = HookSetup.shared.problem {
			menu.addItem(action("⚠︎ \(problem) – Open Setup …", #selector(showSetup)))
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
		if SessionStore.shared.sessions.values.contains(where: { $0.state == .ended }) {
			menu.addItem(action("Remove Ended Sessions", #selector(removeEnded)))
		}

		menu.addItem(.separator())
		menu.addItem(sectionHeader("Notifications"))
		menu.addItem(toggle("Show Notifications", SettingsKey.muted, isInverted: true))
		menu.addItem(toggle("When It Is Your Turn", SettingsKey.notifyOnDone))
		let tests = NSMenu()
		for kind in NotificationKind.allCases {
			let item = action(kind.subtitle, #selector(sendTestNotification(_:)))
			item.representedObject = kind
			tests.addItem(item)
		}
		let testsItem = NSMenuItem(title: "Send Test", action: nil, keyEquivalent: "")
		testsItem.submenu = tests
		menu.addItem(testsItem)
		menu.addItem(sectionHeader("Sounds"))
		menu.addItem(toggle("Play Sounds", SettingsKey.playsSound))

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
		// Only the card of the open menu needs ``fitCard()``.
		card = nil
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

	/// - Parameter isInverted: Shows a check mark while the setting is off.
	private func toggle(_ title: String, _ key: String, isInverted: Bool = false) -> NSMenuItem {
		let item = action(title, #selector(toggleSetting(_:)))
		let defaultValue = SettingsKey.defaultValues[key] ?? true
		item.representedObject = (key, defaultValue)
		item.state = (UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue) != isInverted ? .on : .off
		return item
	}

	static func symbol(_ name: String) -> NSImage? {
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
		let defaults = UserDefaults.standard
		let value = !(defaults.object(forKey: key) as? Bool ?? defaultValue)
		// Only a changed setting is stored, so that the app has no settings file while the user changes nothing.
		if value == defaultValue { defaults.removeObject(forKey: key) } else { defaults.set(value, forKey: key) }
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
