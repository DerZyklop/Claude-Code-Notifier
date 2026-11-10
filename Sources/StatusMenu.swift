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
		Publishers.MergeMany([SessionStore.shared.objectWillChange.eraseToAnyPublisher(), HookSetup.shared.objectWillChange.eraseToAnyPublisher(),
			LightSimulation.shared.objectWillChange.eraseToAnyPublisher()]
			+ Report.all.map { $0.objectWillChange.eraseToAnyPublisher() })
			.receive(on: DispatchQueue.main)
			.sink { [weak self] _ in self?.updateIcon() }
			.store(in: &subscriptions)
		// Only the sessions and the running reports change the height of the card. Measuring it builds a view, so other
		// changes skip it.
		Publishers.MergeMany([SessionStore.shared.objectWillChange.eraseToAnyPublisher()]
			+ Report.all.map { $0.objectWillChange.eraseToAnyPublisher() })
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
	/// sessions, the number of working sessions, and the wave in the space that is left. A report file that you did not
	/// open yet puts a purple dot left of the wave. Without work, the wave stands
	/// still in the menu bar color, and a setup problem breaks it in the middle. A running report moves the wave in purple. Sessions that ask you get the bubble, so that a forgotten prompt does not hide the work in other sessions.
	/// The simulation of the setup window adds its signals to the icon and the lights, see ``LightSimulation``.
	private func updateIcon() {
		guard let button = statusItem.button else { return }
		let sessions = SessionStore.shared.sessions.values
		let hasProblem = HookSetup.shared.hasProblem
		let simulation = LightSimulation.shared
		var waiting = hasProblem ? 0 : sessions.filter { $0.state == .asksYou }.count
		if simulation.waiting { waiting = max(waiting, 1) }
		let runningReports = Report.all.filter(\.isRunning).count
		let workingSessions = hasProblem ? 0 : sessions.filter { $0.shownState == .working }.count
		let isWorking = workingSessions > 0 || simulation.work
		let isReporting = runningReports > 0 || simulation.report
		let working = max(workingSessions + runningReports, isWorking || isReporting ? 1 : 0)
		let hasUnread = Report.all.contains { $0.isUnread } || simulation.unread
		attention.track(asking: Set(sessions.filter { $0.state == .asksYou }.map(\.id)))
		let isDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
		let layout = Self.layout(working: working, waiting: waiting, hasUnread: hasUnread)

		let image = icon(layout: layout, isDark: isDark)
		if button.image !== image { button.image = image }
		button.layoutSubtreeIfNeeded()
		let imageFrame = button.cell?.imageRect(forBounds: button.bounds)
		spinner.show(waveStart: layout.waveStart, waveEnd: layout.waveEnd, over: imageFrame, isWorking: working > 0,
			hasGap: hasProblem, stillColor: Self.textColor(isDark: isDark), isReport: isReporting)
		let waves = Set([isWorking ? LightWave.work : nil, isReporting ? LightWave.report : nil].compactMap { $0 })
		let store = SessionStore.shared
		let letters = hasProblem ? [:] : Dictionary(uniqueKeysWithValues: store.letters.compactMap { id, letter in
			store.sessions[id].map { (letter, $0) }
		})
		Lights.show(waves: waves, isWaiting: layout.waiting > 0, hasUnread: hasUnread, sessions: letters)
		// The bubble is centered vertically, so its frame is the same with and without a flipped y axis.
		let bubbleSize = Self.bubble(count: 1).size
		let bubbleFrame = imageFrame.flatMap { frame in
			layout.bubbleX.map { NSRect(x: frame.minX + $0, y: frame.midY - bubbleSize.height / 2, width: bubbleSize.width, height: bubbleSize.height) }
		}
		attention.show(count: layout.waiting, image: { Self.bubble(count: layout.waiting, color: $0) }, in: bubbleFrame)
		spinner.glow(with: attention)
	}

	static let iconWidth = 70.0
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
		/// The wave runs from here to ``waveEnd``.
		var waveStart = 0.0
		/// The dot of an unread report.
		var dotCenterX: Double?
	}

	static let dotDiameter = 8.0

	static func layout(working: Int, waiting: Int, hasUnread: Bool = false) -> IconLayout {
		var layout = IconLayout(working: min(working, 10), waiting: min(waiting, 10))
		if hasUnread {
			layout.dotCenterX = 1 + dotDiameter / 2
			layout.waveStart = 1 + dotDiameter + gap
		}
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

	/// The number and the dot in one image, above which ``Spinner`` draws the wave and ``AttentionBubble`` the bubble. The image
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
			if let x = layout.dotCenterX {
				Spinner.reportColor.setFill()
				NSBezierPath(ovalIn: NSRect(x: x - Self.dotDiameter / 2, y: rect.midY - Self.dotDiameter / 2,
					width: Self.dotDiameter, height: Self.dotDiameter)).fill()
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

	/// The groups: the sessions with the status of the app, one for each report, and the app itself. The setup window
	/// holds the settings of the outputs.
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
		addUsageCard(to: menu)

		for report in Report.all { addGroup(for: report, to: menu) }

		menu.addItem(.separator())
		let launchAtLogin = action("Launch at Login", #selector(toggleLaunchAtLogin))
		launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
		menu.addItem(launchAtLogin)
		menu.addItem(action("Setup …", #selector(showOutputs)))
		let quit = action("Quit Claude Code Pulse", #selector(quit))
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
		SessionCard(store: SessionStore.shared, setup: HookSetup.shared, clock: clock) { [weak menu] session in
			menu?.cancelTracking()
			VSCodeWindows.shared.open(session)
		}
	}

	/// Gives the card the height of its rows, e.g. when a session starts while the menu is open.
	private func fitCard() {
		guard let card else { return }
		let height = cardSize().height
		if card.frame.height != height { card.frame.size.height = height }
	}

	/// The usage limits of the accounts, see ``AccountUsageStore``. The menu sets the width, and the card keeps its height.
	private func addUsageCard(to menu: NSMenu) {
		AccountUsageStore.shared.refreshIfStale()
		let card = AccountUsageCard(store: AccountUsageStore.shared, clock: clock) { [weak menu] in
			menu?.cancelTracking()
			SetupWindow.show(tab: .accounts)
		}
		// Measured before `sizingOptions` is empty: then the view leaves its size to the menu and measures 0.
		let view = NSHostingView(rootView: card)
		view.frame.size = view.fittingSize
		view.sizingOptions = []
		view.autoresizingMask = [.width]
		let item = NSMenuItem()
		item.view = view
		menu.addItem(item)
	}

	/// The group of a report: the buttons to update and to open, and the reason of a failure. The setup window holds the setting of the
	/// automatic run.
	private func addGroup(for report: Report, to menu: NSMenu) {
		let kind = report.kind
		menu.addItem(.separator())
		menu.addItem(sectionHeader(kind.title))
		let buttons = NSHostingView(rootView: ReportButtons(report: report) { [weak menu] in menu?.cancelTracking() })
		// The menu sets the width.
		buttons.frame.size = buttons.fittingSize
		buttons.autoresizingMask = [.width]
		let buttonsItem = NSMenuItem()
		buttonsItem.view = buttons
		menu.addItem(buttonsItem)
		if let failure = report.failure {
			// Without an action, the item shows the reason in gray and does nothing on a click.
			let reason = NSMenuItem(title: failure.count > 80 ? failure.prefix(80) + "…" : failure, action: nil, keyEquivalent: "")
			reason.toolTip = failure
			reason.indentationLevel = 1
			menu.addItem(reason)
		}
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

	static func symbol(_ name: String) -> NSImage? {
		let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
		image?.isTemplate = true
		return image
	}

	// MARK: - Actions

	@objc private func toggleLaunchAtLogin() {
		if SMAppService.mainApp.status == .enabled {
			try? SMAppService.mainApp.unregister()
		} else {
			try? SMAppService.mainApp.register()
		}
	}

	@objc private func showSetup() {
		SetupWindow.show(tab: .hooks)
	}

	@objc private func showOutputs() {
		SetupWindow.show(tab: .outputs)
	}

	@objc private func quit() {
		NSApp.terminate(nil)
	}
}
