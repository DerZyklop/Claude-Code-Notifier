import AppKit

/// The lights of the NuPhy keyboard show what the blink(1) shows, see ``Blink1``. The setup window chooses the areas
/// and the brightness of each signal, see ``KeyboardMapping``. Today's look is the default:
///
/// - The first two key rows show the wave of the menu bar: a dim green while sessions work, or purple while a report
///   runs, and a brighter segment of 4 keys that runs from left to right.
/// - The right end of the first two rows shows orange while the bubble shows.
/// - Both side bars show the red ring of the bubble in each round.
/// - The first 2 keys of the first two rows and the left bar show a steady purple while a report is unread.
///
/// Where areas overlap, the signal first in ``KeySignal`` wins. Everything else shows the normal effect of the
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
	/// The green of the keys is much stronger than on the blink(1), so the ring is pure red.
	static let ringColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)

	private let keyboard = NuPhyKeyboard()
	private let mapping = KeyboardMapping()
	private var isEnabled = SettingsKey.isOn(SettingsKey.usesKeyboard)
	private var scene = Scene()
	/// Sends the frames while the light moves.
	private var timer: Timer?

	/// Whether the keyboard is connected and shows the state.
	var isShowing: Bool { isEnabled && keyboard.isConnected }

	private init() {
		scene.lights = mapping.lights
		keyboard.onConnect = { [weak self] in self?.render() }
		NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated { self?.settingsChanged() }
		}
	}

	/// Lets the keys show `wave`, the bubble while `isWaiting`, and the mark of an unread report.
	func show(wave: Blink1.Wave, isWaiting: Bool, hasUnread: Bool) {
		let now = CACurrentMediaTime()
		if wave != scene.wave {
			scene.wave = wave
			scene.waveStart = now
		}
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
		scene = Scene(lights: scene.lights)
		keyboard.clear()
	}

	/// Follows the switch and the mapping of the setup window at once.
	private func settingsChanged() {
		let isEnabled = SettingsKey.isOn(SettingsKey.usesKeyboard), lights = mapping.lights
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
		let leds = scene.lights.values.reduce(Set<Int>()) { $0.union($1.leds) }
		let frames = leds.compactMap { led in scene.frame(led: led, at: now).map { (led, $0) } }
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

	/// What the keys show, as a function of the time.
	@MainActor
	struct Scene {
		struct Frame: Equatable {
			var color: NSColor
			var brightness: Double
		}

		var lights = KeyboardMapping.defaultLights
		var wave = Blink1.Wave.off
		var waveStart = 0.0
		var isWaiting = false
		var hasUnread = false
		var ringStart: Double?

		static let ringLength = AttentionBubble.glowTimes.rest * AttentionBubble.ringLength

		func isRinging(at now: Double) -> Bool {
			ringStart.map { now - $0 < Self.ringLength } ?? false
		}

		/// Whether the frames change after `now`. The segment runs also under other signals.
		func isMoving(at now: Double) -> Bool {
			isRinging(at: now) || wave != .off
		}

		/// The color of `led` at `now`: the first signal that covers it and has a color, after `signal`. `nil` while
		/// it has nothing to show.
		func frame(led: Int, at now: Double, after signal: KeySignal? = nil) -> Frame? {
			let signals = KeySignal.allCases
			let start = signal.flatMap { signals.firstIndex(of: $0).map { $0 + 1 } } ?? 0
			for signal in signals[start...] {
				guard let light = lights[signal], light.leds.contains(led) else { continue }
				if let frame = frame(of: signal, light: light, led: led, at: now) { return frame }
			}
			return nil
		}

		/// The color of `signal` on `led` at `now`, `nil` while the signal is off.
		private func frame(of signal: KeySignal, light: KeyLight, led: Int, at now: Double) -> Frame? {
			switch signal {
			case .ring:
				guard let ringStart, isRinging(at: now) else { return nil }
				// The ring rises from the color below it.
				let rest = frame(led: led, at: now, after: .ring) ?? Frame(color: KeyboardLight.ringColor, brightness: 0)
				return Self.ring(from: rest, to: light.level, at: (now - ringStart) / AttentionBubble.ringLength)
			case .waiting:
				return isWaiting ? Frame(color: Blink1.Badge.asksYou.color, brightness: light.level) : nil
			case .unread:
				return hasUnread ? Frame(color: Blink1.Badge.unread.color, brightness: light.level) : nil
			case .work:
				guard let color = Self.color(of: wave) else { return nil }
				let share = Self.segmentShare(of: NuPhyKeyboard.keyX[led], at: (now - waveStart) / Spinner.runDuration)
				let dim = KeyboardLight.dimShare * light.level
				return Frame(color: color, brightness: dim + (light.level - dim) * share)
			}
		}

		/// The color of the wave in the menu bar, `nil` without a wave.
		static func color(of wave: Blink1.Wave) -> NSColor? {
			switch wave {
			case .work: Spinner.color
			case .report: Spinner.reportColor
			case .off: nil
			}
		}

		/// The share of the key at `x` that the segment covers after `runs` runs from left to right. The segment leaves
		/// at the right end while it comes back in at the left, so it runs without a jump.
		static func segmentShare(of x: Double, at runs: Double) -> Double {
			let width = NuPhyKeyboard.rowWidth
			let start = (runs - runs.rounded(.down)) * width
			let key = x...(x + NuPhyKeyboard.keyWidth)
			// The part of the segment past the right end shows at the left.
			let covered = [start - width, start].reduce(0.0) { sum, segmentStart in
				let overlap = min(key.upperBound, segmentStart + KeyboardLight.segmentWidth) - max(key.lowerBound, segmentStart)
				return sum + max(overlap, 0)
			}
			return min(covered / NuPhyKeyboard.keyWidth, 1)
		}

		/// The ring at `x`, a share of ``AttentionBubble/ringLength``: up to red at `peak` fast, a long hold, back to `rest`.
		static func ring(from rest: Frame, to peak: Double, at x: Double) -> Frame {
			let times = AttentionBubble.glowTimes
			let red = x < times.up ? x / times.up : x < times.down ? 1 : max(1 - (x - times.down) / (times.rest - times.down), 0)
			return Frame(color: mix(rest.color, KeyboardLight.ringColor, red),
				brightness: rest.brightness + (peak - rest.brightness) * red)
		}

		/// `a` and `b` mixed in sRGB, at `fraction` of `b`. `NSColor.blended` mixes in another color space, so pure red
		/// gets green.
		static func mix(_ a: NSColor, _ b: NSColor, _ fraction: Double) -> NSColor {
			guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return b }
			func lerp(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * fraction }
			return NSColor(srgbRed: lerp(a.redComponent, b.redComponent), green: lerp(a.greenComponent, b.greenComponent),
				blue: lerp(a.blueComponent, b.blueComponent), alpha: 1)
		}
	}
}
