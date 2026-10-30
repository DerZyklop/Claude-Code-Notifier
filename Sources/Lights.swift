import AppKit

/// The lights that show the state: the blink(1) and the NuPhy keyboard. Each signal is defined once here, see
/// ``LightSignal`` and ``LightScene``. Each light only maps the areas to its LEDs and sends the colors.
@MainActor
enum Lights {
	/// Lets the lights show `wave`, the bubble while `isWaiting`, and the mark of an unread report.
	static func show(wave: LightWave, isWaiting: Bool, hasUnread: Bool) {
		Blink1.shared.show(wave: wave, isWaiting: isWaiting, hasUnread: hasUnread)
		KeyboardLight.shared.show(wave: wave, isWaiting: isWaiting, hasUnread: hasUnread)
	}

	/// Rings once in red, together with the bubble.
	static func ring() {
		Blink1.shared.ring()
		KeyboardLight.shared.ring()
	}

	/// Stops every animation and turns the lights off, e.g. when the app quits.
	static func turnOff() {
		Blink1.shared.turnOff()
		KeyboardLight.shared.turnOff()
	}

	/// Whether a light is connected and shows the state.
	static var isShowing: Bool { Blink1.shared.isShowing || KeyboardLight.shared.isShowing }
}

/// The state of the wave in the menu bar.
enum LightWave {
	case work, report, off

	/// Purple while a report runs, also when sessions work too, like the wave.
	init(isReporting: Bool, working: Int) {
		self = isReporting ? .report : working > 0 ? .work : .off
	}

	/// The color of the wave in the menu bar, `nil` without a wave.
	var color: NSColor? {
		switch self {
		case .work: Spinner.color
		case .report: Spinner.reportColor
		case .off: nil
		}
	}
}

/// A light with its own LEDs.
enum LightDevice {
	case keyboard, blink1

	/// The LEDs of `area`. The blink(1) has LED 1 and LED 2.
	@MainActor func points(of area: LightArea) -> [Int] {
		switch self {
		case .keyboard: area.keyboardLEDs
		case .blink1: area.blink1LEDs
		}
	}

	/// The level of a signal at `brightness` on `count` LEDs. On the keyboard, it is the brightness of
	/// ``NuPhyKeyboard/show(_:)``: up to ``NuPhyKeyboard/fullBrightness`` on a few LEDs, else up to the limit of NuPhy. On
	/// the blink(1), it is a share of today's look of the signal, see ``Blink1/breath(of:level:at:)``.
	@MainActor func level(of signal: LightSignal, brightness: Double, count: Int) -> Double {
		switch self {
		case .keyboard: brightness * (count > LightMapping.fullPowerLimit ? 1 : NuPhyKeyboard.fullBrightness)
		case .blink1: brightness / signal.defaultBrightness
		}
	}
}

/// A group of LEDs that a signal can show on, with its LEDs on each light.
enum LightArea: String, CaseIterable {
	case firstTwoRows, topRightCorner, topLeftFour, leftSide, rightSide, allKeys, rightColumn

	var title: String {
		switch self {
		case .firstTwoRows: "First Two Rows"
		case .topRightCorner: "Right End of the First Two Rows"
		case .topLeftFour: "First 2 Keys of the First Two Rows"
		case .leftSide: "Left Side Bar"
		case .rightSide: "Right Side Bar"
		case .allKeys: "All Keys"
		case .rightColumn: "Right Column"
		}
	}

	@MainActor var keyboardLEDs: [Int] {
		switch self {
		case .firstTwoRows: return Array(NuPhyKeyboard.firstRow) + Array(NuPhyKeyboard.secondRow)
		// The last 3 keys of the first row, and below them the last 2 of the second row, because Backspace is two keys
		// wide. The second row runs from right to left, so these are its first 2 LEDs.
		case .topRightCorner: return Array(NuPhyKeyboard.firstRow.upperBound - 3..<NuPhyKeyboard.firstRow.upperBound)
			+ Array(NuPhyKeyboard.secondRow.lowerBound..<NuPhyKeyboard.secondRow.lowerBound + 2)
		// The second row runs from right to left, so its first 2 keys are its last 2 LEDs.
		case .topLeftFour: return [NuPhyKeyboard.firstRow.lowerBound, NuPhyKeyboard.firstRow.lowerBound + 1,
			NuPhyKeyboard.secondRow.upperBound - 2, NuPhyKeyboard.secondRow.upperBound - 1]
		case .leftSide: return Array(NuPhyKeyboard.leftBar)
		case .rightSide: return Array(NuPhyKeyboard.rightBar)
		case .allKeys: return Array(0..<NuPhyKeyboard.keyCount)
		case .rightColumn: return NuPhyKeyboard.rightEnds
		}
	}

	/// The large areas use both LEDs of the blink(1), the small ones LED 1, and the right column LED 2.
	var blink1LEDs: [Int] {
		switch self {
		case .firstTwoRows, .allKeys: [1, 2]
		case .topRightCorner, .topLeftFour, .leftSide, .rightSide: [1]
		case .rightColumn: [2]
		}
	}

	var blink1Title: String {
		switch blink1LEDs {
		case [1]: "LED 1"
		case [2]: "LED 2"
		default: "Both LEDs"
		}
	}
}

/// A state that the lights show. The cases are in the order of their priority: where the areas of two signals
/// overlap, an LED shows the first signal that has a color at the moment.
enum LightSignal: String, CaseIterable {
	case ring, waiting, unread, work

	/// The red of the ring: only the red LEDs. The red of the screen has green and blue, so it looks pink on the LEDs.
	static let ringColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
	/// The orange of the bubble on the LEDs. The orange of the screen looks yellow on them, so this one has less green.
	static let orange = NSColor(srgbRed: 1, green: 48 / 255, blue: 0, alpha: 1)

	var title: String {
		switch self {
		case .ring: "Red Ring"
		case .waiting: "Waiting"
		case .unread: "Summary Not Opened"
		case .work: "Work State"
		}
	}

	/// The areas and the brightness of today's look.
	var defaultAreas: [LightArea] {
		switch self {
		case .ring: [.leftSide, .rightSide]
		case .waiting: [.topRightCorner]
		case .unread: [.topLeftFour, .leftSide]
		case .work: [.firstTwoRows]
		}
	}

	/// A share of the brightest level, see ``LightDevice/level(of:brightness:count:)``.
	var defaultBrightness: Double { self == .work ? 0.6 : 1 }

	/// The keys keep the names from the time when only the keyboard had areas, so that the stored values stay.
	var areasKey: String { "keyboard.\(rawValue).areas" }
	var brightnessKey: String { "keyboard.\(rawValue).brightness" }
}

/// The LEDs and the level of a signal on one light.
struct Light: Equatable {
	var points: Set<Int>
	var level: Double
}

/// The areas and the brightness of each ``LightSignal``, as the user chose them in the setup window. Both lights use
/// them. Only values that differ from the defaults are stored.
struct LightMapping {
	/// A signal on more keyboard LEDs than this stays at the limit of NuPhy, because all keys at full power need more
	/// current than many USB ports give.
	static let fullPowerLimit = 12

	var defaults: UserDefaults = .standard

	func areas(of signal: LightSignal) -> [LightArea] {
		guard let names = defaults.object(forKey: signal.areasKey) as? [String] else { return signal.defaultAreas }
		return LightArea.allCases.filter { names.contains($0.rawValue) }
	}

	func setAreas(_ areas: [LightArea], of signal: LightSignal) {
		let sorted = LightArea.allCases.filter(areas.contains)
		if sorted == LightArea.allCases.filter(signal.defaultAreas.contains) {
			defaults.removeObject(forKey: signal.areasKey)
		} else {
			defaults.set(sorted.map(\.rawValue), forKey: signal.areasKey)
		}
	}

	/// From 0 to 1.
	func brightness(of signal: LightSignal) -> Double {
		defaults.object(forKey: signal.brightnessKey) as? Double ?? signal.defaultBrightness
	}

	func setBrightness(_ brightness: Double, of signal: LightSignal) {
		let value = min(max(brightness, 0), 1)
		if value == signal.defaultBrightness {
			defaults.removeObject(forKey: signal.brightnessKey)
		} else {
			defaults.set(value, forKey: signal.brightnessKey)
		}
	}

	@MainActor func lights(on device: LightDevice) -> [LightSignal: Light] {
		Dictionary(uniqueKeysWithValues: LightSignal.allCases.map {
			($0, Self.light(of: $0, areas: areas(of: $0), brightness: brightness(of: $0), on: device))
		})
	}

	@MainActor static func defaultLights(on device: LightDevice) -> [LightSignal: Light] {
		Dictionary(uniqueKeysWithValues: LightSignal.allCases.map {
			($0, light(of: $0, areas: $0.defaultAreas, brightness: $0.defaultBrightness, on: device))
		})
	}

	@MainActor static func light(of signal: LightSignal, areas: [LightArea], brightness: Double, on device: LightDevice) -> Light {
		let points = Set(areas.flatMap(device.points(of:)))
		return Light(points: points, level: device.level(of: signal, brightness: brightness, count: points.count))
	}
}

/// What the LEDs of one light show, as a function of the time. The signals and their order are the same on each
/// light. Only the wave looks different: a running segment on the keyboard, a breath on the blink(1).
@MainActor
struct LightScene {
	struct Frame: Equatable {
		var color: NSColor
		var brightness: Double
	}

	var device: LightDevice
	var lights: [LightSignal: Light]
	var wave: LightWave
	var waveStart: Double
	var isWaiting: Bool
	var hasUnread: Bool
	var ringStart: Double?

	init(device: LightDevice, lights: [LightSignal: Light]? = nil, wave: LightWave = .off, waveStart: Double = 0,
		isWaiting: Bool = false, hasUnread: Bool = false, ringStart: Double? = nil) {
		self.device = device
		self.lights = lights ?? LightMapping.defaultLights(on: device)
		self.wave = wave
		self.waveStart = waveStart
		self.isWaiting = isWaiting
		self.hasUnread = hasUnread
		self.ringStart = ringStart
	}

	static let ringLength = AttentionBubble.glowTimes.rest * AttentionBubble.ringLength

	/// All LEDs that a signal uses.
	var points: Set<Int> { lights.values.reduce(Set<Int>()) { $0.union($1.points) } }

	func isRinging(at now: Double) -> Bool {
		ringStart.map { now - $0 < Self.ringLength } ?? false
	}

	/// Whether the frames change after `now`. The wave moves also under other signals.
	func isMoving(at now: Double) -> Bool {
		isRinging(at: now) || wave != .off
	}

	/// The color of `point` at `now`: the first signal that covers it and has a color, after `signal`. `nil` while it
	/// has nothing to show.
	func frame(point: Int, at now: Double, after signal: LightSignal? = nil) -> Frame? {
		let signals = LightSignal.allCases
		let start = signal.flatMap { signals.firstIndex(of: $0).map { $0 + 1 } } ?? 0
		for signal in signals[start...] {
			guard let light = lights[signal], light.points.contains(point) else { continue }
			if let frame = frame(of: signal, level: light.level, point: point, at: now) { return frame }
		}
		return nil
	}

	/// The color of `signal` on `point` at `now`, `nil` while the signal is off.
	private func frame(of signal: LightSignal, level: Double, point: Int, at now: Double) -> Frame? {
		switch signal {
		case .ring:
			guard let ringStart, isRinging(at: now) else { return nil }
			// The ring rises from the color below it.
			let rest = frame(point: point, at: now, after: .ring) ?? Frame(color: LightSignal.ringColor, brightness: 0)
			let peak = device == .blink1 ? Blink1.ringBrightness * level : level
			return Self.ring(from: rest, to: peak, at: (now - ringStart) / AttentionBubble.ringLength)
		case .waiting, .unread:
			guard signal == .waiting ? isWaiting : hasUnread else { return nil }
			let color = signal == .waiting ? LightSignal.orange : Spinner.reportColor
			return Frame(color: color, brightness: device == .blink1 ? Blink1.badgeBrightness * level : level)
		case .work:
			guard let color = wave.color else { return nil }
			switch device {
			case .keyboard:
				let share = Self.segmentShare(of: NuPhyKeyboard.keyX[point], at: (now - waveStart) / Spinner.runDuration)
				let dim = KeyboardLight.dimShare * level
				return Frame(color: color, brightness: dim + (level - dim) * share)
			case .blink1:
				return Frame(color: color, brightness: Blink1.breath(of: wave, level: level, at: now - waveStart))
			}
		}
	}

	/// The share of the key at `x` that the segment covers after `runs` runs from left to right. The segment leaves at
	/// the right end while it comes back in at the left, so it runs without a jump.
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
		return Frame(color: mix(rest.color, LightSignal.ringColor, red), brightness: rest.brightness + (peak - rest.brightness) * red)
	}

	/// `a` and `b` mixed in sRGB, at `fraction` of `b`. `NSColor.blended` mixes in another color space, so pure red gets
	/// green.
	static func mix(_ a: NSColor, _ b: NSColor, _ fraction: Double) -> NSColor {
		guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return b }
		func lerp(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * fraction }
		return NSColor(srgbRed: lerp(a.redComponent, b.redComponent), green: lerp(a.greenComponent, b.greenComponent),
			blue: lerp(a.blueComponent, b.blueComponent), alpha: 1)
	}
}
