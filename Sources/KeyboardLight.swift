import AppKit

/// The first two key rows of the NuPhy keyboard show what the blink(1) shows, see ``Blink1``. The second row breathes
/// in green while sessions work and in purple while a report runs. The first row shows the badge of the icon, or the
/// wave without a badge. Only Esc, F1 and F2 ring in bright red with each round of the bubble. The 3 blinks of an
/// ended session or a ready report show on both rows. The other rows, and both rows without anything to show, keep
/// the normal effect of the keyboard. A keyboard that you plug in later gets the current colors too.
@MainActor
final class KeyboardLight {
	static let shared = KeyboardLight()
	/// The keyboard has no fades, so the app sends each step of a fade, at this rate.
	static let frameTime = 1.0 / 30
	/// The keys are less bright than the blink(1), so they get more of their light.
	static let badgeBrightness = 0.5
	static let reportBrightness = 0.15...0.6
	static let workBrightness = 0.15...0.35
	/// The ring uses the full power of the LEDs, above the limit of NuPhy. On 3 keys, this needs little current.
	static let ringBrightness = NuPhyKeyboard.fullBrightness
	/// The green of the keys is much stronger than on the blink(1), so the ring is pure red.
	static let ringColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)

	/// The groups of keys that show one color each. A smaller group lies on top of a larger one.
	enum Zone: CaseIterable {
		/// Esc, F1 and F2: the ring, else like ``icon``.
		case alert
		/// The rest of the first row, like LED 1 of the blink(1): the badge, else the wave.
		case icon
		/// The second row, like LED 2 of the blink(1): the wave.
		case wave

		@MainActor var leds: Range<Int> {
			let firstRow = NuPhyKeyboard.firstRow
			switch self {
			case .alert: return firstRow.lowerBound..<firstRow.lowerBound + 3
			case .icon: return firstRow.lowerBound + 3..<firstRow.upperBound
			case .wave: return NuPhyKeyboard.secondRow
			}
		}
	}

	private let keyboard = NuPhyKeyboard()
	private var scene = Scene()
	/// Sends the frames while the light moves.
	private var timer: Timer?

	private init() {
		keyboard.onConnect = { [weak self] in self?.render() }
	}

	/// Lets the second row show `wave`, and the first row `badge`, or `wave` without a badge.
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

	/// Blinks the first two rows 3 times in `color` at full brightness, then shows the wave and the badge again.
	func pulse(_ color: NSColor) {
		scene.pulse = Scene.Pulse(color: color, start: CACurrentMediaTime())
		scene.ringStart = nil
		render()
	}

	/// Rings Esc, F1 and F2 once in bright red, together with the bubble. Only while the bubble shows.
	func ring() {
		let now = CACurrentMediaTime()
		guard scene.badge == .asksYou, !scene.isPulsing(at: now) else { return }
		scene.ringStart = now
		render()
	}

	/// Stops every animation and gives the keyboard its normal effect back, e.g. when the app quits.
	func turnOff() {
		stopTimer()
		scene = Scene()
		keyboard.clear()
	}

	static func breath(_ wave: Blink1.Wave) -> Blink1.Breath {
		switch wave {
		case .work: Blink1.Breath(color: Spinner.color, brightness: workBrightness)
		case .report: Blink1.Breath(color: Spinner.reportColor, brightness: reportBrightness)
		case .off: .off
		}
	}

	/// Sends the frames of now, and runs the timer while the light moves.
	private func render() {
		guard keyboard.isConnected else {
			stopTimer()
			return
		}
		let now = CACurrentMediaTime()
		let frames = Zone.allCases.map { ($0, scene.frame(of: $0, at: now)) }
		if frames.allSatisfy({ $0.1 == nil }) {
			keyboard.clear()
		} else {
			// A zone without a frame is off, like an LED of the blink(1).
			for (zone, frame) in frames {
				keyboard.show(frame?.color ?? .black, brightness: frame?.brightness ?? 0, on: zone.leds)
			}
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

		/// Whether the frames change after `now`. The second row breathes also under a badge.
		func isMoving(at now: Double) -> Bool {
			isPulsing(at: now) || isRinging(at: now) || wave.brightness.lowerBound != wave.brightness.upperBound
		}

		/// The color of `zone` at `now`, `nil` while it has nothing to show.
		func frame(of zone: Zone, at now: Double) -> Frame? {
			if let pulse, isPulsing(at: now) {
				// Each blink: fade up and stay, then fade down and stay.
				let t = (now - pulse.start).truncatingRemainder(dividingBy: 2 * Blink1.pulseStep)
				let isOn = t < Blink1.pulseStep
				let fade = min((isOn ? t : t - Blink1.pulseStep) / Blink1.pulseFade, 1)
				return Frame(color: pulse.color, brightness: isOn ? fade : 1 - fade)
			}
			if zone != .wave, let badge {
				let rest = Frame(color: badge.color, brightness: KeyboardLight.badgeBrightness)
				guard zone == .alert, let ringStart, isRinging(at: now) else { return rest }
				return Self.ring(from: rest, at: (now - ringStart) / AttentionBubble.ringLength)
			}
			guard wave != .off else { return nil }
			let phase = ((now - waveStart) / Blink1.breathDuration).truncatingRemainder(dividingBy: 1)
			// From bright down to dim, then up to bright again.
			return Frame(color: wave.color, brightness: wave.brightness(at: abs(1 - 2 * phase)))
		}

		/// The ring at `x`, a share of ``AttentionBubble/ringLength``: up to the full red fast, a long hold, back to `rest`.
		static func ring(from rest: Frame, at x: Double) -> Frame {
			let times = AttentionBubble.glowTimes
			let red = x < times.up ? x / times.up : x < times.down ? 1 : max(1 - (x - times.down) / (times.rest - times.down), 0)
			return Frame(color: mix(rest.color, KeyboardLight.ringColor, red),
				brightness: rest.brightness + (KeyboardLight.ringBrightness - rest.brightness) * red)
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
