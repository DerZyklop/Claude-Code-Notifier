import AppKit
import IOKit.hid

/// A blink(1) USB light: orange while a session asks you, purple while a report runs or waits to be opened, green
/// while sessions work, and off without all of them. Each color breathes between a dim and a bright level, at the pace of
/// the wave in the menu bar. With each round of the bubble, the light rings twice in bright red, together with the
/// bubble and its sound. When a session ends, the light blinks 3 times in bright green, and when a report is ready, in
/// bright purple. Then it breathes in the current color again. A light that you plug in later gets the current color too.
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
	/// The color at the peak of a ring.
	static let ringColor = NSColor.systemRed
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
	private var breath = Breath.off
	/// The breath that runs, `nil` while the light stays, blinks or rings.
	private var breathTask: Task<Void, Never>?
	/// The blinks or the rings that run. The light breathes in the current color again when they are done.
	private var effectTask: Task<Void, Never>?

	private init() {
		IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: Self.vendorID, kIOHIDProductIDKey: Self.productID] as CFDictionary)
		IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
			let blink1 = Unmanaged<Blink1>.fromOpaque(context!).takeUnretainedValue()
			MainActor.assumeIsolated {
				let breath = blink1.breath
				blink1.send(Blink1.rgb(breath.color, brightness: breath.brightness.upperBound), fadeTime: Blink1.fadeTime, to: device)
			}
		}, Unmanaged.passUnretained(self).toOpaque())
		IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
		IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
	}

	/// What the light shows, from the most urgent to the calmest.
	enum State {
		case asksYou, report, working, off
	}

	/// Lets all lights breathe in the color of `state`.
	func show(_ state: State) {
		let breath = switch state {
		case .asksYou: Breath(color: AttentionBubble.color, brightness: Self.askBrightness)
		case .report: Breath(color: Spinner.reportColor, brightness: Self.reportBrightness)
		case .working: Breath(color: Spinner.color, brightness: Self.workBrightness)
		case .off: Breath.off
		}
		guard breath != self.breath else { return }
		self.breath = breath
		if effectTask == nil { breathe() }
	}

	/// Blinks all lights 3 times in `color` at full brightness, then lets them breathe in the color of the current state.
	/// A new blink starts again.
	func pulse(_ color: NSColor) {
		let blink = [Step(rgb: Self.rgb(color, brightness: 1), fade: Self.pulseFade, hold: Self.pulseStep),
			Step(rgb: [0, 0, 0], fade: Self.pulseFade, hold: Self.pulseStep)]
		play(Array([[Step]](repeating: blink, count: Self.pulseCount).joined()))
	}

	/// Rings twice in bright red at the times of the bubble's glow, see ``AttentionBubble``: up fast, hold, back to the
	/// bright level of the current breath, twice in one ``AttentionBubble/ringLength``.
	func ring() {
		let length = AttentionBubble.ringLength
		let red = Self.rgb(Self.ringColor, brightness: 1)
		let rest = Self.rgb(breath.color, brightness: breath.brightness.upperBound)
		// The glow starts at 0, holds its peak until 0.3 and starts again at 0.5. Each change takes 0.06.
		let fade = 0.06 * length, down = 0.3 * length, next = 0.5 * length
		let once = [Step(rgb: red, fade: fade, hold: down), Step(rgb: rest, fade: fade, hold: next - down)]
		play(once + once)
	}

	/// One color of a blink or a ring: the fade to it, and the time until the next step. Both in seconds.
	private struct Step {
		var rgb: [UInt8]
		var fade: Double
		var hold: Double
	}

	/// Stops the breath and plays the steps, then breathes again. New steps stop the old ones.
	private func play(_ steps: [Step]) {
		breathTask?.cancel()
		breathTask = nil
		effectTask?.cancel()
		effectTask = Task {
			for step in steps {
				sendToAll(step.rgb, fadeTime: Int((step.fade * 100).rounded()))
				try? await Task.sleep(nanoseconds: UInt64(step.hold * 1e9))
				if Task.isCancelled { return }
			}
			effectTask = nil
			breathe()
		}
	}

	/// Fades to the bright level, then breathes down to the dim level and back until the breath changes.
	private func breathe() {
		breathTask?.cancel()
		breathTask = nil
		let breath = breath
		sendToAll(Self.rgb(breath.color, brightness: breath.brightness.upperBound), fadeTime: Self.fadeTime)
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
					sendToAll(rgb, fadeTime: Int((step * 100).rounded()))
					try? await Task.sleep(nanoseconds: UInt64(step * 1e9))
				}
			}
		}
	}

	/// The LED is much brighter than the screen, so it gets the screen color at a share of it. The rings and the blinks
	/// get the full light.
	static let askBrightness = 0.04...0.10
	static let reportBrightness = 0.04...0.28
	static let workBrightness = 0.04...0.10
	/// The blue LED is stronger than the red and the green one, so blue gets this share.
	static let blueShare = 0.6

	/// The sRGB values without a gamma correction keep the soft mix of the screen color.
	static func rgb(_ color: NSColor, brightness: Double) -> [UInt8] {
		guard let srgb = color.usingColorSpace(.sRGB) else { return [0, 0, 0] }
		return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent * blueShare].map { UInt8(($0 * brightness * 255).rounded()) }
	}

	private func sendToAll(_ rgb: [UInt8], fadeTime: Int) {
		for device in IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? [] { send(rgb, fadeTime: fadeTime, to: device) }
	}

	/// The »fade to RGB« command for both LEDs. `fadeTime` is in units of 10 ms.
	private func send(_ rgb: [UInt8], fadeTime: Int, to device: IOHIDDevice) {
		let report: [UInt8] = [1, UInt8(ascii: "c")] + rgb + [UInt8(fadeTime >> 8), UInt8(fadeTime & 0xFF), 0, 0]
		IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 1, report, report.count)
	}
}
