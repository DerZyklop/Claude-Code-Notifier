import AppKit

/// The lights of the NuPhy keyboard show what the blink(1) shows, see ``Blink1``, in three areas:
///
/// - The first two key rows show the wave of the menu bar: a dim green while sessions work, or purple while a report
///   runs, and a brighter segment of 4 keys that runs from left to right.
/// - The last 3 keys of the first row show the badge of the icon, or the wave without a badge.
/// - Both side bars show the red ring of the bubble in each round. The left bar also shows a steady purple while a
///   report is unread.
///
/// Everything else shows the normal effect of the keyboard. A keyboard that you plug in later gets the current
/// colors too.
@MainActor
final class KeyboardLight {
	static let shared = KeyboardLight()
	/// The keyboard has no fades, so the app sends each step of a fade, at this rate.
	static let frameTime = 1.0 / 30
	/// The keys are less bright than the blink(1), so they get more of their light. The badge is on 3 keys only, so it
	/// uses the full power of the LEDs, like the ring.
	static let badgeBrightness = NuPhyKeyboard.fullBrightness
	/// The dim color of the wave, and its segment.
	static let waveBrightness = 0.12
	static let segmentBrightness = 0.6
	/// The width of the segment, in the units of ``NuPhyKeyboard/keyX``: 4 keys.
	static let segmentWidth = 4 * NuPhyKeyboard.keyWidth
	/// The ring uses the full power of the LEDs, above the limit of NuPhy. On 3 keys, this needs little current.
	static let ringBrightness = NuPhyKeyboard.fullBrightness
	/// The purple of the left side bar while a report is unread. It uses the full power of the LEDs, like the ring.
	static let markBrightness = NuPhyKeyboard.fullBrightness
	/// The green of the keys is much stronger than on the blink(1), so the ring is pure red.
	static let ringColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)

	/// The groups of LEDs that show one color each. They do not overlap.
	enum Zone: CaseIterable {
		/// Both side bars: the red ring of the bubble. The left bar shows a steady purple while a report is unread.
		case alert
		/// The last 3 keys of the first row, up to Del: the badge of the icon, else the wave.
		case icon
		/// The first two rows without ``icon``: the wave, and the 3 blinks.
		case wave

		@MainActor var leds: [Int] {
			let firstRow = NuPhyKeyboard.firstRow
			switch self {
			case .alert: return Array(NuPhyKeyboard.sideLights)
			case .icon: return Array(firstRow.upperBound - 3..<firstRow.upperBound)
			case .wave: return Array(firstRow.lowerBound..<firstRow.upperBound - 3) + NuPhyKeyboard.secondRow
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

	/// Lets the first two rows show `wave`, and the last 3 keys of the first row `badge`, or `wave` without a badge.
	func show(wave: Blink1.Wave, badge: Blink1.Badge?) {
		let now = CACurrentMediaTime()
		if wave != scene.wave {
			scene.wave = wave
			scene.waveStart = now
		}
		if badge != scene.badge {
			scene.badge = badge
			scene.ringStart = nil
		}
		render()
	}

	/// Rings both side bars once in bright red, together with the bubble. Only while the bubble shows.
	func ring() {
		let now = CACurrentMediaTime()
		guard scene.badge == .asksYou else { return }
		scene.ringStart = now
		render()
	}

	/// Stops every animation and gives the keyboard its normal effect back, e.g. when the app quits.
	func turnOff() {
		stopTimer()
		scene = Scene()
		keyboard.clear()
	}

	/// Sends the frames of now, and runs the timer while the light moves.
	private func render() {
		guard keyboard.isConnected else {
			stopTimer()
			return
		}
		let now = CACurrentMediaTime()
		let frames = Zone.allCases.flatMap { zone in zone.leds.map { ($0, scene.frame(of: zone, led: $0, at: now)) } }
		if frames.allSatisfy({ $0.1 == nil }) {
			keyboard.clear()
		} else {
			// An LED without a frame shows the normal effect of the keyboard.
			keyboard.show(Dictionary(uniqueKeysWithValues: frames.compactMap { led, frame in
				frame.map { (led, (color: $0.color, brightness: $0.brightness)) }
			}))
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

		var wave = Blink1.Wave.off
		var waveStart = 0.0
		var badge: Blink1.Badge?
		var ringStart: Double?

		static let ringLength = AttentionBubble.glowTimes.rest * AttentionBubble.ringLength

		func isRinging(at now: Double) -> Bool {
			badge == .asksYou && ringStart.map { now - $0 < Self.ringLength } ?? false
		}

		/// Whether the frames change after `now`. The segment runs also under a badge.
		func isMoving(at now: Double) -> Bool {
			isRinging(at: now) || wave != .off
		}

		/// The color of `led` in `zone` at `now`, `nil` while it has nothing to show.
		func frame(of zone: Zone, led: Int, at now: Double) -> Frame? {
			if zone == .alert {
				if badge == .unread, NuPhyKeyboard.leftBar.contains(led) {
					return Frame(color: Blink1.Badge.unread.color, brightness: KeyboardLight.markBrightness)
				}
				guard let ringStart, isRinging(at: now) else { return nil }
				let rest = Frame(color: KeyboardLight.ringColor, brightness: 0)
				return Self.ring(from: rest, at: (now - ringStart) / AttentionBubble.ringLength)
			}
			if zone == .icon, let badge {
				return Frame(color: badge.color, brightness: KeyboardLight.badgeBrightness)
			}
			guard let color = Self.color(of: wave) else { return nil }
			let share = Self.segmentShare(of: NuPhyKeyboard.keyX[led], at: (now - waveStart) / Spinner.runDuration)
			let dim = KeyboardLight.waveBrightness
			return Frame(color: color, brightness: dim + (KeyboardLight.segmentBrightness - dim) * share)
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
