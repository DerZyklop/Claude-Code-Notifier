import AppKit

/// The lights of the NuPhy keyboard show the signals of ``LightScene``. The setup window chooses the areas and the
/// brightness of each signal, see ``LightMapping``. Today's look is the default:
///
/// - The first two key rows show the wave of the menu bar: a dim green while sessions work, or purple while a report
///   runs, and a brighter segment of 4 keys that runs from left to right.
/// - The right end of the first two rows shows orange while the bubble shows.
/// - Both side bars show the red ring of the bubble in each round.
/// - The first 2 keys of the first two rows and the left bar show a steady purple while a report is unread.
/// - The letter keys show the sessions of the card, each on its own letter, see ``SessionStore/letters``. The colors are
///   those of their icons: a green pulse while it works, a half bright white on your turn, orange while it asks you,
///   a dim white after it ended. A session without activity for ``idleLimit`` stays dark. A switch of the setup
///   window turns the letter keys off.
///
/// Where areas overlap, the signal first in ``LightSignal`` wins. An LED goes off when its signal ends. Everything
/// else shows the normal effect of the keyboard. A keyboard that you plug in later gets the current colors too.
@MainActor
final class KeyboardLight {
	static let shared = KeyboardLight()
	/// The keyboard has no fades, so the app sends each step of a fade, at this rate.
	static let frameTime = 1.0 / 30
	/// The dim color of the wave, as a share of its segment.
	static let dimShare = 0.2
	/// The width of the segment, in the units of ``NuPhyKeyboard/keyX``: 4 keys.
	static let segmentWidth = 4 * NuPhyKeyboard.keyWidth
	/// A session without an event for this time stays dark on its letter key: 5 hours.
	static let idleLimit: TimeInterval = 5 * 60 * 60

	private let keyboard = NuPhyKeyboard()
	private let mapping = LightMapping()
	private var isEnabled = SettingsKey.isOn(SettingsKey.usesKeyboard)
	private var showsSessions = SettingsKey.isOn(SettingsKey.showsSessionsOnKeyboard)
	/// The session on each letter, from the last ``show(waves:isWaiting:hasUnread:sessions:)``.
	private var sessions: [Int: Session] = [:]
	private var scene = LightScene(device: .keyboard)
	/// Sends the frames while the light moves.
	private var timer: Timer?

	/// Whether the keyboard is connected and shows the state.
	var isShowing: Bool { isEnabled && keyboard.isConnected }

	private init() {
		scene.lights = mapping.lights(on: .keyboard)
		keyboard.onConnect = { [weak self] in self?.render() }
		NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated { self?.settingsChanged() }
		}
		// A session can pass the idle limit without an event.
		let idleTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.updateSessionLights() }
		}
		RunLoop.main.add(idleTimer, forMode: .common)
	}

	/// Lets the keys show `waves`, the bubble while `isWaiting`, the mark of an unread report, and `sessions` on the
	/// letter keys.
	func show(waves: Set<LightWave>, isWaiting: Bool, hasUnread: Bool, sessions: [Int: Session] = [:]) {
		self.sessions = sessions
		scene.sessionLights = Self.sessionLights(of: showsSessions ? Self.shownSessions(sessions, at: Date()) : [:])
		scene.waveStarts = scene.waveStarts.filter { waves.contains($0.key) }
		for wave in waves where scene.waveStarts[wave] == nil { scene.waveStarts[wave] = CACurrentMediaTime() }
		if isWaiting != scene.isWaiting {
			scene.isWaiting = isWaiting
			scene.ringStart = nil
		}
		scene.hasUnread = hasUnread
		render()
	}

	/// The shown state of each session in `sessions` that is busy, or that had an event in the last ``idleLimit``.
	static func shownSessions(_ sessions: [Int: Session], at now: Date) -> [Int: SessionState] {
		sessions.filter { $0.value.isBusy || now.timeIntervalSince($0.value.updated) < idleLimit }.mapValues(\.shownState)
	}

	/// Sends the session lights again when a session passed the idle limit or the switch changed.
	private func updateSessionLights() {
		let lights = Self.sessionLights(of: showsSessions ? Self.shownSessions(sessions, at: Date()) : [:])
		guard lights != scene.sessionLights else { return }
		scene.sessionLights = lights
		render()
	}

	/// The light of each LED for the state of the session on each letter, see ``SessionStore/letters``.
	static func sessionLights(of sessions: [Int: SessionState]) -> [Int: SessionLight] {
		var colors: [Int: SessionLight] = [:]
		for (letter, state) in sessions where NuPhyKeyboard.letterKeys.indices.contains(letter) {
			let key = NuPhyKeyboard.letterKeys[letter]
			switch state {
			case .working: colors[key] = SessionLight(color: Spinner.color, pulses: true)
			case .yourTurn: colors[key] = SessionLight(color: .white, brightness: 0.5)
			case .asksYou: colors[key] = SessionLight(color: LightSignal.orange)
			case .ended: colors[key] = SessionLight(color: .white, brightness: dimShare)
			}
		}
		return colors
	}

	/// Rings the keys of the red ring once, together with the bubble.
	func ring() {
		scene.ringStart = CACurrentMediaTime()
		render()
	}

	/// Stops every animation and gives the keyboard its normal effect back, e.g. when the app quits.
	func turnOff() {
		stopTimer()
		scene = LightScene(device: .keyboard, lights: scene.lights)
		keyboard.clear()
	}

	/// Follows the switch and the mapping of the setup window at once.
	private func settingsChanged() {
		showsSessions = SettingsKey.isOn(SettingsKey.showsSessionsOnKeyboard)
		updateSessionLights()
		let isEnabled = SettingsKey.isOn(SettingsKey.usesKeyboard), lights = mapping.lights(on: .keyboard)
		guard isEnabled != self.isEnabled || lights != scene.lights else { return }
		self.isEnabled = isEnabled
		scene.lights = lights
		render()
	}

	/// Sends the frames of now, and runs the timer while the light moves.
	private func render() {
		guard keyboard.isConnected, isEnabled else {
			keyboard.clear()
			stopTimer()
			return
		}
		let now = CACurrentMediaTime()
		let frames = scene.points.compactMap { led in scene.frame(point: led, at: now).map { (led, $0) } }
		// An LED without a frame goes off, or shows the normal effect of the keyboard if it never had a color.
		keyboard.show(Dictionary(uniqueKeysWithValues: frames.map { led, frame in (led, (color: frame.color, brightness: frame.brightness)) }))
		// A failed report needs the next frame to send all colors again.
		if !scene.isMoving(at: now) && !keyboard.isOutOfSync {
			stopTimer()
		} else if timer == nil {
			let timer = Timer(timeInterval: Self.frameTime, repeats: true) { [weak self] _ in
				MainActor.assumeIsolated { self?.render() }
			}
			// The `common` modes include the one the run loop uses while a menu is open.
			RunLoop.main.add(timer, forMode: .common)
			self.timer = timer
		}
	}

	private func stopTimer() {
		timer?.invalidate()
		timer = nil
	}
}
