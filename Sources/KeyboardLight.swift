import AppKit

/// The lights of the NuPhy keyboard show the signals of ``LightScene``. The setup window chooses the areas and the
/// brightness of each signal, see ``LightMapping``. Today's look is the default:
///
/// - The first two key rows show the wave of the menu bar: a dim green while sessions work, or purple while a report
///   runs, and a brighter segment of 4 keys that runs from left to right.
/// - The right end of the first two rows shows orange while the bubble shows.
/// - Both side bars show the red ring of the bubble in each round.
/// - The first 2 keys of the first two rows and the left bar show a steady purple while a report is unread.
///
/// Where areas overlap, the signal first in ``LightSignal`` wins. Everything else shows the normal effect of the
/// keyboard. A keyboard that you plug in later gets the current colors too.
@MainActor
final class KeyboardLight {
	static let shared = KeyboardLight()
	/// The keyboard has no fades, so the app sends each step of a fade, at this rate.
	static let frameTime = 1.0 / 30
	/// The dim color of the wave, as a share of its segment.
	static let dimShare = 0.2
	/// The width of the segment, in the units of ``NuPhyKeyboard/keyX``: 4 keys.
	static let segmentWidth = 4 * NuPhyKeyboard.keyWidth

	private let keyboard = NuPhyKeyboard()
	private let mapping = LightMapping()
	private var isEnabled = SettingsKey.isOn(SettingsKey.usesKeyboard)
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
	}

	/// Lets the keys show `waves`, the bubble while `isWaiting`, and the mark of an unread report.
	func show(waves: Set<LightWave>, isWaiting: Bool, hasUnread: Bool) {
		scene.waveStarts = scene.waveStarts.filter { waves.contains($0.key) }
		for wave in waves where scene.waveStarts[wave] == nil { scene.waveStarts[wave] = CACurrentMediaTime() }
		if isWaiting != scene.isWaiting {
			scene.isWaiting = isWaiting
			scene.ringStart = nil
		}
		scene.hasUnread = hasUnread
		render()
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
		if frames.isEmpty {
			keyboard.clear()
		} else {
			// An LED without a frame shows the normal effect of the keyboard.
			keyboard.show(Dictionary(uniqueKeysWithValues: frames.map { led, frame in (led, (color: frame.color, brightness: frame.brightness)) }))
		}
		if !scene.isMoving(at: now) {
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
