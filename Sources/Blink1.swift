import AppKit
import IOKit.hid

/// A blink(1) USB light with two LEDs. Both follow the wave in the menu bar: they breathe in green while sessions work,
/// in purple while a report runs, and are off without both. LED 1 shows the badge of the icon instead: steady orange
/// while the bubble shows, steady purple while the dot of an unread report shows. With each round of the bubble, LED 1
/// rings once in bright red, together with the bubble and its sound. When a session ends while it works or asks you, both LEDs blink 3 times in
/// bright green, and when a report is ready, in bright purple. A light that you plug in later gets the current colors too.
@MainActor
final class Blink1 {
	static let shared = Blink1()
	static let vendorID = 0x27B8
	static let productID = 0x01ED
	/// The fade to a new color, in units of 10 ms.
	static let fadeTime = 30
	/// The fade of one blink step, in seconds.
	static let pulseFade = 0.15
	/// The time of one blink step: the fade, then the color stays a moment.
	static let pulseStep = 0.3
	static let pulseCount = 3
	/// The color at the peak of a ring: only the red LED. The red of the screen has green and blue, so it looks pink on the LEDs.
	static let ringColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
	/// The orange of the badge on the LEDs. The orange of the screen looks yellow on them, so this one has less green.
	static let orange = NSColor(srgbRed: 1, green: 48 / 255, blue: 0, alpha: 1)
	/// One breath, from bright to dim and back, takes as long as one run of the wave segment.
	static let breathDuration = Spinner.runDuration
	/// The steps of one half breath. The light fades in a straight line between two steps, so the steps make the curve.
	static let breathSteps = 24
	/// The eye sees the brightness of the LED about with this gamma. The breath is even in the seen brightness.
	static let gamma = 2.2

	/// A color that breathes between two brightness levels. Both are the same for a light that stays.
	struct Breath: Equatable {
		var color: NSColor
		var brightness: ClosedRange<Double>

		static let off = Breath(color: .black, brightness: 0...0)

		/// The brightness at `t` of a half breath, from dim at 0 to bright at 1: a cubic ease in and out of the seen brightness.
		func brightness(at t: Double) -> Double {
			let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(2 - 2 * t, 3) / 2
			let dim = pow(brightness.lowerBound, 1 / Blink1.gamma), bright = pow(brightness.upperBound, 1 / Blink1.gamma)
			return pow(dim + (bright - dim) * eased, Blink1.gamma)
		}
	}

	private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
	/// The breath of the wave.
	private var wave = Breath.off
	private var badge: Badge?
	/// The breath that runs, `nil` while the wave stays or the LEDs blink.
	private var breathTask: Task<Void, Never>?
	/// The rings of LED 1 that run.
	private var ringTask: Task<Void, Never>?
	/// The blinks of both LEDs that run. Then the LEDs show the wave and the badge again.
	private var pulseTask: Task<Void, Never>?

	private init() {
		IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: Self.vendorID, kIOHIDProductIDKey: Self.productID] as CFDictionary)
		IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
			let blink1 = Unmanaged<Blink1>.fromOpaque(context!).takeUnretainedValue()
			MainActor.assumeIsolated {
				let wave = blink1.wave
				blink1.send(Blink1.rgb(wave.color, brightness: wave.brightness.upperBound), fadeTime: Blink1.fadeTime, led: .both, to: device)
				if let badge = blink1.badge { blink1.send(Blink1.rgb(badge), fadeTime: Blink1.fadeTime, led: .one, to: device) }
			}
		}, Unmanaged.passUnretained(self).toOpaque())
		IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
		IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
	}

	/// The state of the wave in the menu bar.
	enum Wave {
		case work, report, off

		/// Purple while a report runs, also when sessions work too, like the wave.
		init(isReporting: Bool, working: Int) {
			self = isReporting ? .report : working > 0 ? .work : .off
		}

		var breath: Breath {
			switch self {
			case .work: Breath(color: Spinner.color, brightness: Blink1.workBrightness)
			case .report: Breath(color: Spinner.reportColor, brightness: Blink1.reportBrightness)
			case .off: Breath.off
			}
		}
	}

	/// The badge of the icon that LED 1 shows.
	enum Badge {
		case asksYou, unread

		/// The bubble wins over the dot.
		init?(waiting: Int, hasUnread: Bool) {
			guard let badge = waiting > 0 ? Badge.asksYou : hasUnread ? .unread : nil else { return nil }
			self = badge
		}

		var color: NSColor { self == .asksYou ? Blink1.orange : Spinner.reportColor }
	}

	/// The LEDs that a command changes. LED 1 shows the badge.
	enum LED: UInt8 {
		case both = 0, one = 1, two = 2
	}

	/// Lets both LEDs show `wave`, and LED 1 `badge` instead if there is one.
	func show(wave: Wave, badge: Badge?) {
		let breath = wave.breath
		let waveChanged = breath != self.wave, badgeChanged = badge != self.badge
		self.wave = breath
		self.badge = badge
		guard pulseTask == nil else { return }
		if badgeChanged {
			ringTask?.cancel()
			ringTask = nil
			showBadge()
		}
		if waveChanged { breathe() }
	}

	/// Stops every animation and turns both LEDs off, e.g. when the app quits.
	func turnOff() {
		for task in [breathTask, ringTask, pulseTask] { task?.cancel() }
		breathTask = nil
		ringTask = nil
		pulseTask = nil
		wave = .off
		badge = nil
		sendToAll([0, 0, 0], fadeTime: 0, led: .both)
	}

	/// Blinks both LEDs 3 times in `color` at full brightness, then shows the wave and the badge again. A new blink
	/// starts again.
	func pulse(_ color: NSColor) {
		breathTask?.cancel()
		breathTask = nil
		ringTask?.cancel()
		ringTask = nil
		pulseTask?.cancel()
		let blink = [Step(rgb: Self.rgb(color, brightness: 1), fade: Self.pulseFade, hold: Self.pulseStep),
			Step(rgb: [0, 0, 0], fade: Self.pulseFade, hold: Self.pulseStep)]
		pulseTask = play(Array([[Step]](repeating: blink, count: Self.pulseCount).joined()), on: .both) { blink1 in
			blink1.pulseTask = nil
			blink1.breathe()
			blink1.showBadge()
		}
	}

	/// Rings LED 1 once in bright red at the times of the bubble's glow, see ``AttentionBubble/glowTimes``: up fast, a
	/// long hold, back to the steady orange. Only while the bubble shows.
	func ring() {
		guard badge == .asksYou, pulseTask == nil else { return }
		let length = AttentionBubble.ringLength
		let red = Self.rgb(Self.ringColor, brightness: 1)
		let rest = Self.rgb(.asksYou)
		let times = AttentionBubble.glowTimes
		let steps = [Step(rgb: red, fade: times.up * length, hold: times.down * length),
			Step(rgb: rest, fade: (times.rest - times.down) * length, hold: (times.rest - times.down) * length)]
		ringTask?.cancel()
		ringTask = play(steps, on: .one) { $0.ringTask = nil }
	}

	/// One color of a blink or a ring: the fade to it, and the time until the next step. Both in seconds.
	private struct Step {
		var rgb: [UInt8]
		var fade: Double
		var hold: Double
	}

	/// Plays the steps on `led`, then calls `done`, unless a cancel stops them.
	private func play(_ steps: [Step], on led: LED, done: @escaping (Blink1) -> Void) -> Task<Void, Never> {
		Task {
			for step in steps {
				sendToAll(step.rgb, fadeTime: Int((step.fade * 100).rounded()), led: led)
				try? await Task.sleep(nanoseconds: UInt64(step.hold * 1e9))
				if Task.isCancelled { return }
			}
			done(self)
		}
	}

	/// LED 1 in the badge color, or in the wave without a badge.
	private func showBadge() {
		let rgb = badge.map(Self.rgb) ?? Self.rgb(wave.color, brightness: wave.brightness.upperBound)
		sendToAll(rgb, fadeTime: Self.fadeTime, led: .one)
	}

	/// The LEDs of the wave: both without a badge, else LED 2.
	private var waveLED: LED { badge == nil ? .both : .two }

	/// Fades to the bright level, then breathes down to the dim level and back until the wave changes.
	private func breathe() {
		breathTask?.cancel()
		breathTask = nil
		let breath = wave
		sendToAll(Self.rgb(breath.color, brightness: breath.brightness.upperBound), fadeTime: Self.fadeTime, led: waveLED)
		guard breath.brightness.lowerBound != breath.brightness.upperBound else { return }
		let steps = Self.breathSteps
		// From bright down to dim, then up to bright again.
		let frames = (1...(2 * steps)).map { Self.rgb(breath.color, brightness: breath.brightness(at: Double(abs(steps - $0)) / Double(steps))) }
		let step = Self.breathDuration / 2 / Double(steps)
		breathTask = Task {
			try? await Task.sleep(nanoseconds: UInt64(Double(Self.fadeTime) / 100 * 1e9))
			while !Task.isCancelled {
				for rgb in frames {
					if Task.isCancelled { return }
					sendToAll(rgb, fadeTime: Int((step * 100).rounded()), led: waveLED)
					try? await Task.sleep(nanoseconds: UInt64(step * 1e9))
				}
			}
		}
	}

	/// The LED is much brighter than the screen, so it gets the screen color at a share of it. The rings and the blinks
	/// get the full light.
	static let badgeBrightness = 0.10
	static let reportBrightness = 0.04...0.28
	static let workBrightness = 0.02...0.04
	/// The blue LED is stronger than the red and the green one, so blue gets this share.
	static let blueShare = 0.6

	/// The sRGB values without a gamma correction keep the soft mix of the screen color.
	static func rgb(_ color: NSColor, brightness: Double) -> [UInt8] {
		guard let srgb = color.usingColorSpace(.sRGB) else { return [0, 0, 0] }
		return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent * blueShare].map { UInt8(($0 * brightness * 255).rounded()) }
	}

	static func rgb(_ badge: Badge) -> [UInt8] {
		rgb(badge.color, brightness: badgeBrightness)
	}

	private func sendToAll(_ rgb: [UInt8], fadeTime: Int, led: LED) {
		for device in IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? [] { send(rgb, fadeTime: fadeTime, led: led, to: device) }
	}

	/// The »fade to RGB« command for `led`. `fadeTime` is in units of 10 ms.
	private func send(_ rgb: [UInt8], fadeTime: Int, led: LED, to device: IOHIDDevice) {
		let report: [UInt8] = [1, UInt8(ascii: "c")] + rgb + [UInt8(fadeTime >> 8), UInt8(fadeTime & 0xFF), led.rawValue, 0]
		IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 1, report, report.count)
	}
}
