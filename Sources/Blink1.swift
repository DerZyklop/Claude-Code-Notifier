import AppKit
import IOKit.hid

/// A blink(1) USB light with two LEDs. It shows the signals of ``LightScene`` in the areas of the setup window, see
/// ``LightArea/blink1LEDs``. Today's look is the default: both LEDs breathe in green while sessions work, and in purple
/// while a report runs. LED 1 shows steady orange while the bubble shows, steady purple while a report is unread, and
/// rings once in bright red with each round of the bubble. An LED without a signal shows the color of the other LED, so
/// that a signal uses both LEDs while nothing else shows.
///
/// When a session ends while it works or asks you, both LEDs blink 3 times in bright green, and when a report is ready,
/// in bright purple, see ``SettingsKey/blinksAtEnd``. A light that you plug in later gets the current colors too. The
/// switch in the setup window turns the light off, see ``SettingsKey/usesBlink1``.
@MainActor
final class Blink1 {
	static let shared = Blink1()
	static let vendorID = 0x27B8
	static let productID = 0x01ED
	/// The app sends a frame at this rate while the light moves. The light fades to each frame in this time.
	static let frameTime = 1.0 / 25
	/// The fade to a new steady color, in units of 10 ms.
	static let fadeTime = 30
	/// The fade of one blink step, in seconds.
	static let pulseFade = 0.15
	/// The time of one blink step: the fade, then the color stays a moment.
	static let pulseStep = 0.3
	static let pulseCount = 3
	/// One breath, from bright to dim and back, takes as long as one run of the wave segment.
	static let breathDuration = Spinner.runDuration
	/// The eye sees the brightness of the LED about with this gamma. The breath is even in the seen brightness.
	nonisolated static let gamma = 2.2

	/// A color that breathes between two brightness levels.
	struct Breath: Equatable {
		var color: NSColor
		var brightness: ClosedRange<Double>

		/// The brightness at `t` of a half breath, from dim at 0 to bright at 1: a cubic ease in and out of the seen brightness.
		func brightness(at t: Double) -> Double {
			let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(2 - 2 * t, 3) / 2
			let dim = pow(brightness.lowerBound, 1 / Blink1.gamma), bright = pow(brightness.upperBound, 1 / Blink1.gamma)
			return pow(dim + (bright - dim) * eased, Blink1.gamma)
		}
	}

	private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
	private let mapping = LightMapping()
	private var isEnabled = SettingsKey.isOn(SettingsKey.usesBlink1)
	private var scene = LightScene(device: .blink1)
	/// The color and the start of the blinks that run.
	private var pulse: (color: NSColor, start: Double)?
	/// The values that the app sent last to LED 1 and LED 2, `nil` before the first one. The app sends only changes.
	private var sent: [[UInt8]?] = [nil, nil]
	/// Sends the frames while the light moves.
	private var timer: Timer?

	private var devices: Set<IOHIDDevice> { IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? [] }

	/// Whether a light is connected and shows the state.
	var isShowing: Bool { isEnabled && !devices.isEmpty }

	private init() {
		scene.lights = mapping.lights(on: .blink1)
		IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: Self.vendorID, kIOHIDProductIDKey: Self.productID] as CFDictionary)
		IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, _ in
			let blink1 = Unmanaged<Blink1>.fromOpaque(context!).takeUnretainedValue()
			MainActor.assumeIsolated {
				// The new light gets all colors, and the others the same again.
				blink1.sent = [nil, nil]
				blink1.render()
			}
		}, Unmanaged.passUnretained(self).toOpaque())
		IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
		IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
		NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated { self?.settingsChanged() }
		}
	}

	/// Lets the LEDs show `wave`, the bubble while `isWaiting`, and the mark of an unread report.
	func show(wave: LightWave, isWaiting: Bool, hasUnread: Bool) {
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

	/// Rings the LEDs of the red ring once, together with the bubble.
	func ring() {
		scene.ringStart = CACurrentMediaTime()
		render()
	}

	/// Blinks both LEDs 3 times in `color` at full brightness, then shows the signals again. A new blink starts again.
	func pulse(_ color: NSColor) {
		guard isEnabled, SettingsKey.isOn(SettingsKey.blinksAtEnd) else { return }
		pulse = (color, CACurrentMediaTime())
		render()
	}

	/// Stops every animation and turns both LEDs off, e.g. when the app quits.
	func turnOff() {
		stopTimer()
		scene = LightScene(device: .blink1, lights: scene.lights)
		pulse = nil
		send([0, 0, 0], fadeTime: 0, led: 0)
		sent = [[0, 0, 0], [0, 0, 0]]
	}

	/// Follows the switch and the mapping of the setup window at once.
	private func settingsChanged() {
		let isEnabled = SettingsKey.isOn(SettingsKey.usesBlink1), lights = mapping.lights(on: .blink1)
		guard isEnabled != self.isEnabled || lights != scene.lights else { return }
		self.isEnabled = isEnabled
		scene.lights = lights
		render()
	}

	/// Sends the frames of now, and runs the timer while the light moves.
	private func render() {
		guard isEnabled, !devices.isEmpty else {
			stopTimer()
			if !isEnabled, sent != [[0, 0, 0], [0, 0, 0]] {
				send([0, 0, 0], fadeTime: 0, led: 0)
				sent = [[0, 0, 0], [0, 0, 0]]
			}
			return
		}
		let now = CACurrentMediaTime()
		if let pulse, now - pulse.start >= Self.pulseStep * Double(2 * Self.pulseCount) { self.pulse = nil }
		let isMoving = scene.isMoving(at: now) || pulse != nil
		let rgbs = Self.frames(of: scene, pulse: pulse, at: now).map { frame in
			frame.map { Self.rgb($0.color, brightness: $0.brightness) } ?? [0, 0, 0]
		}
		let fadeTime = isMoving ? Int((Self.frameTime * 100).rounded()) : Self.fadeTime
		if rgbs[0] == rgbs[1] {
			if sent[0] != rgbs[0] || sent[1] != rgbs[1] { send(rgbs[0], fadeTime: fadeTime, led: 0) }
		} else {
			for index in 0..<2 where sent[index] != rgbs[index] { send(rgbs[index], fadeTime: fadeTime, led: UInt8(index + 1)) }
		}
		sent = rgbs.map { $0 }

		if !isMoving {
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

	/// The frames of LED 1 and LED 2 at `now`. An LED without a signal shows the frame of the other one. The blinks
	/// win over everything.
	static func frames(of scene: LightScene, pulse: (color: NSColor, start: Double)?, at now: Double) -> [LightScene.Frame?] {
		if let pulse {
			let frame = LightScene.Frame(color: pulse.color, brightness: pulseBrightness(at: now - pulse.start))
			return [frame, frame]
		}
		let one = scene.frame(point: 1, at: now), two = scene.frame(point: 2, at: now)
		return [one ?? two, two ?? one]
	}

	/// The brightness of the blinks at `elapsed` seconds: a fade up, a hold, a fade down and a dark pause, 3 times.
	static func pulseBrightness(at elapsed: Double) -> Double {
		let step = Int(elapsed / pulseStep), inStep = elapsed - Double(step) * pulseStep
		let fade = min(inStep / pulseFade, 1)
		return step.isMultiple(of: 2) ? fade : 1 - fade
	}

	/// The brightness of the wave at `elapsed` seconds after it started: from bright down to dim and up again, at
	/// `level` of its normal brightness.
	static func breath(of wave: LightWave, level: Double, at elapsed: Double) -> Double {
		let range = wave == .report ? reportBrightness : workBrightness
		let breath = Breath(color: .black, brightness: range.lowerBound * level...range.upperBound * level)
		let phase = (elapsed / breathDuration).truncatingRemainder(dividingBy: 1)
		return breath.brightness(at: abs(1 - 2 * phase))
	}

	/// The LED is much brighter than the screen, so it gets the screen color at a share of it. The rings and the blinks
	/// get the full light.
	static let badgeBrightness = 0.10
	static let ringBrightness = 1.0
	nonisolated static let reportBrightness = 0.04...0.28
	nonisolated static let workBrightness = 0.02...0.04
	/// The blue LED is stronger than the red and the green one, so blue gets this share.
	static let blueShare = 0.6

	/// The sRGB values without a gamma correction keep the soft mix of the screen color.
	static func rgb(_ color: NSColor, brightness: Double) -> [UInt8] {
		guard let srgb = color.usingColorSpace(.sRGB) else { return [0, 0, 0] }
		let level = min(max(brightness, 0), 1)
		return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent * blueShare].map { UInt8(($0 * level * 255).rounded()) }
	}

	/// The »fade to RGB« command for `led` on each light: 0 for both LEDs, else 1 or 2. `fadeTime` is in units of 10 ms.
	private func send(_ rgb: [UInt8], fadeTime: Int, led: UInt8) {
		let report: [UInt8] = [1, UInt8(ascii: "c")] + rgb + [UInt8(fadeTime >> 8), UInt8(fadeTime & 0xFF), led, 0]
		for device in devices { IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 1, report, report.count) }
	}
}
