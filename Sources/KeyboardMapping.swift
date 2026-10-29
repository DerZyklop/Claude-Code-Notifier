import Foundation

/// A group of LEDs of the NuPhy keyboard that a signal can show on, see ``KeySignal``.
enum KeyArea: String, CaseIterable {
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

	@MainActor var leds: [Int] {
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
}

/// A state that the keyboard shows. The cases are in the order of their priority: where the areas of two signals
/// overlap, an LED shows the first signal that has a color at the moment.
enum KeySignal: String, CaseIterable {
	case ring, waiting, unread, work

	var title: String {
		switch self {
		case .ring: "Red Ring"
		case .waiting: "Waiting"
		case .unread: "Summary Not Opened"
		case .work: "Work State"
		}
	}

	/// The areas and the brightness of today's look.
	var defaultAreas: [KeyArea] {
		switch self {
		case .ring: [.leftSide, .rightSide]
		case .waiting: [.topRightCorner]
		case .unread: [.topLeftFour, .leftSide]
		case .work: [.firstTwoRows]
		}
	}

	/// A share of the brightest level, see ``KeyboardMapping/light(areas:brightness:)``.
	var defaultBrightness: Double { self == .work ? 0.6 : 1 }

	var areasKey: String { "keyboard.\(rawValue).areas" }
	var brightnessKey: String { "keyboard.\(rawValue).brightness" }
}

/// The LEDs and the brightness of a signal.
struct KeyLight: Equatable {
	var leds: Set<Int>
	/// The brightness for ``NuPhyKeyboard/show(_:)``.
	var level: Double
}

/// The areas and the brightness of each ``KeySignal``, as the user chose them in the setup window. Only values that
/// differ from the defaults are stored.
struct KeyboardMapping {
	/// A signal on more LEDs than this stays at the limit of NuPhy, because all keys at full power need more current than
	/// many USB ports give.
	static let fullPowerLimit = 12

	var defaults: UserDefaults = .standard

	func areas(of signal: KeySignal) -> [KeyArea] {
		guard let names = defaults.object(forKey: signal.areasKey) as? [String] else { return signal.defaultAreas }
		return KeyArea.allCases.filter { names.contains($0.rawValue) }
	}

	func setAreas(_ areas: [KeyArea], of signal: KeySignal) {
		let sorted = KeyArea.allCases.filter(areas.contains)
		if sorted == KeyArea.allCases.filter(signal.defaultAreas.contains) {
			defaults.removeObject(forKey: signal.areasKey)
		} else {
			defaults.set(sorted.map(\.rawValue), forKey: signal.areasKey)
		}
	}

	/// From 0 to 1.
	func brightness(of signal: KeySignal) -> Double {
		defaults.object(forKey: signal.brightnessKey) as? Double ?? signal.defaultBrightness
	}

	func setBrightness(_ brightness: Double, of signal: KeySignal) {
		let value = min(max(brightness, 0), 1)
		if value == signal.defaultBrightness {
			defaults.removeObject(forKey: signal.brightnessKey)
		} else {
			defaults.set(value, forKey: signal.brightnessKey)
		}
	}

	@MainActor var lights: [KeySignal: KeyLight] {
		Dictionary(uniqueKeysWithValues: KeySignal.allCases.map { ($0, Self.light(areas: areas(of: $0), brightness: brightness(of: $0))) })
	}

	@MainActor static var defaultLights: [KeySignal: KeyLight] {
		Dictionary(uniqueKeysWithValues: KeySignal.allCases.map { ($0, light(areas: $0.defaultAreas, brightness: $0.defaultBrightness)) })
	}

	/// The level goes up to ``NuPhyKeyboard/fullBrightness`` on a few LEDs, else up to the limit of NuPhy.
	@MainActor static func light(areas: [KeyArea], brightness: Double) -> KeyLight {
		let leds = Set(areas.flatMap(\.leds))
		let top = leds.count > fullPowerLimit ? 1 : NuPhyKeyboard.fullBrightness
		return KeyLight(leds: leds, level: brightness * top)
	}
}
