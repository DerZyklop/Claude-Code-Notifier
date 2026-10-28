import AppKit

/// The backlight of the NuPhy keyboard shows the same as the blink(1), see ``Blink1``. The keyboard has one light for
/// all keys, so the badge wins over the wave: steady orange while the bubble shows, with a red ring in each round, and
/// steady purple while the dot of an unread report shows. Without a badge, the keys breathe in green while sessions
/// work and in purple while a report runs. The 3 blinks of an ended session or a ready report win over all. Without
/// anything to show, the keyboard has its own light. A keyboard that you plug in later gets the current colors too.
@MainActor
final class KeyboardLight {
	static let shared = KeyboardLight()
	/// The keyboard has no fades, so the app sends each step of a fade, at this rate.
	static let frameTime = 1.0 / 30
	/// The keys are less bright than the blink(1), so they get more of their light.
	static let badgeBrightness = 0.5
	static let reportBrightness = 0.15...0.6
	static let workBrightness = 0.15...0.35

	private let keyboard = NuPhyKeyboard()
	private var scene = Scene()
	/// Sends the frames while the light moves.
	private var timer: Timer?

	private init() {
		keyboard.onReady = { [weak self] in self?.render() }
	}

	/// Lets the keys show `badge`, or `wave` without a badge.
	func show(wave: Blink1.Wave, badge: Blink1.Badge?) {
		let now = CACurrentMediaTime()
		let breath = Self.breath(wave)
		if breath != scene.wave {
			scene.wave = breath
			scene.waveStart = now
		}
		if badge != scene.badge {
			scene.badge = badge
			scene.ringStart = nil
		}
		render()
	}

	/// Blinks the keys 3 times in `color` at full brightness, then shows the badge or the wave again.
	func pulse(_ color: NSColor) {
		scene.pulse = Scene.Pulse(color: color, start: CACurrentMediaTime())
		scene.ringStart = nil
		render()
	}

	/// Rings the keys once in bright red, together with the bubble. Only while the bubble shows.
	func ring() {
		let now = CACurrentMediaTime()
		guard scene.badge == .asksYou, !scene.isPulsing(at: now) else { return }
		scene.ringStart = now
		render()
	}

	/// Stops every animation and gives the keyboard its own light back, e.g. when the app quits.
	func turnOff() {
		timer?.invalidate()
		timer = nil
		scene = Scene()
		keyboard.restore()
	}

	static func breath(_ wave: Blink1.Wave) -> Blink1.Breath {
		switch wave {
		case .work: Blink1.Breath(color: Spinner.color, brightness: workBrightness)
		case .report: Blink1.Breath(color: Spinner.reportColor, brightness: reportBrightness)
		case .off: .off
		}
	}

	/// Sends the frame of now, and runs the timer while the light moves.
	private func render() {
		guard keyboard.isReady else {
			stopTimer()
			return
		}
		let now = CACurrentMediaTime()
		if let frame = scene.frame(at: now) {
			keyboard.show(frame.color, brightness: frame.brightness)
		} else {
			keyboard.restore()
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
		struct Pulse {
			var color: NSColor
			var start: Double
		}

		struct Frame: Equatable {
			var color: NSColor
			var brightness: Double
		}

		var wave = Blink1.Breath.off
		var waveStart = 0.0
		var badge: Blink1.Badge?
		var pulse: Pulse?
		var ringStart: Double?

		static let pulseLength = Double(Blink1.pulseCount) * 2 * Blink1.pulseStep
		static let ringLength = AttentionBubble.glowTimes.rest * AttentionBubble.ringLength

		func isPulsing(at now: Double) -> Bool {
			pulse.map { now - $0.start < Self.pulseLength } ?? false
		}

		func isRinging(at now: Double) -> Bool {
			badge == .asksYou && ringStart.map { now - $0 < Self.ringLength } ?? false
		}

		/// Whether the frames change after `now`.
		func isMoving(at now: Double) -> Bool {
			isPulsing(at: now) || isRinging(at: now) || badge == nil && wave.brightness.lowerBound != wave.brightness.upperBound
		}

		/// The color of the keys at `now`, `nil` for the own light of the keyboard.
		func frame(at now: Double) -> Frame? {
			if let pulse, isPulsing(at: now) {
				// Each blink: fade up and stay, then fade down and stay.
				let t = (now - pulse.start).truncatingRemainder(dividingBy: 2 * Blink1.pulseStep)
				let isOn = t < Blink1.pulseStep
				let fade = min((isOn ? t : t - Blink1.pulseStep) / Blink1.pulseFade, 1)
				return Frame(color: pulse.color, brightness: isOn ? fade : 1 - fade)
			}
			if let badge {
				let rest = Frame(color: badge.color, brightness: KeyboardLight.badgeBrightness)
				guard let ringStart, isRinging(at: now) else { return rest }
				return Self.ring(from: rest, at: (now - ringStart) / AttentionBubble.ringLength)
			}
			guard wave != .off else { return nil }
			let phase = ((now - waveStart) / Blink1.breathDuration).truncatingRemainder(dividingBy: 1)
			// From bright down to dim, then up to bright again.
			return Frame(color: wave.color, brightness: wave.brightness(at: abs(1 - 2 * phase)))
		}

		/// The ring at `x`, a share of ``AttentionBubble/ringLength``: up to red fast, a long hold, back to `rest`.
		static func ring(from rest: Frame, at x: Double) -> Frame {
			let times = AttentionBubble.glowTimes
			let red = x < times.up ? x / times.up : x < times.down ? 1 : max(1 - (x - times.down) / (times.rest - times.down), 0)
			return Frame(color: rest.color.blended(withFraction: red, of: Blink1.ringColor) ?? Blink1.ringColor,
				brightness: rest.brightness + (1 - rest.brightness) * red)
		}
	}
}
