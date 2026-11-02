import Foundation

/// The backlight of the internal MacBook keyboard. It has one white area and no colors, so it only shows that sessions
/// work or a report runs: it fades off and on with ease. A few steps are enough, because macOS fades each change by
/// itself. At all other times the app does not touch the backlight, and macOS controls it.
@MainActor
final class MacBookBacklight {
	static let shared = MacBookBacklight(backlight: .live)
	/// The time of one fade: off, then on.
	static let fadeTime: TimeInterval = 1
	static let stepsPerFade = 4

	/// The access to the backlight. `nil` values mean that the Mac has no backlight.
	struct Backlight {
		var brightness: () -> Float?
		var setBrightness: (Float) -> Void
	}

	private let backlight: Backlight
	private let defaults: UserDefaults
	private var isEnabled: Bool
	private var isWorking = false
	/// The brightness of macOS before the blink, to give back at its end.
	private var brightnessBefore: Float?
	private var step = 0
	private var timer: Timer?

	init(backlight: Backlight, defaults: UserDefaults = .standard) {
		self.backlight = backlight
		self.defaults = defaults
		isEnabled = SettingsKey.isOn(SettingsKey.usesMacBookBacklight, in: defaults)
		NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated { self?.settingsChanged() }
		}
	}

	var isBlinking: Bool { brightnessBefore != nil }

	/// Blinks while `waves` shows work or a report.
	func show(waves: Set<LightWave>) {
		isWorking = !waves.isEmpty
		update()
	}

	/// Gives macOS the backlight back, e.g. when the app quits.
	func turnOff() {
		isWorking = false
		update()
	}

	func settingsChanged() {
		let isEnabled = SettingsKey.isOn(SettingsKey.usesMacBookBacklight, in: defaults)
		guard isEnabled != self.isEnabled else { return }
		self.isEnabled = isEnabled
		update()
	}

	private func update() {
		if isEnabled && isWorking { start() } else { stop() }
	}

	private func start() {
		guard !isBlinking, let brightness = backlight.brightness() else { return }
		brightnessBefore = brightness
		nextStep()
		timer = Timer.scheduledTimer(withTimeInterval: Self.fadeTime / Double(Self.stepsPerFade), repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.nextStep() }
		}
	}

	private func stop() {
		guard let brightnessBefore else { return }
		timer?.invalidate()
		timer = nil
		self.brightnessBefore = nil
		step = 0
		backlight.setBrightness(brightnessBefore)
	}

	/// The brightness at `step` of the blink. It starts at 1 and follows a cosine, which eases each fade.
	static func brightness(atStep step: Int) -> Float {
		Float((1 + cos(.pi * Double(step) / Double(stepsPerFade))) / 2)
	}

	/// Goes down first, so that the start shows at once.
	private func nextStep() {
		step = (step + 1) % (2 * Self.stepsPerFade)
		backlight.setBrightness(Self.brightness(atStep: step))
	}
}

extension MacBookBacklight.Backlight {
	/// The private `KeyboardBrightnessClient` of `CoreBrightness`. Apple has no public API for the backlight.
	static var live: Self {
		guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW) != nil,
			let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return .missing }
		let client = type.init()
		let ids = client.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue() as? [NSNumber]
		guard let id = ids?.first?.uint64Value else { return .missing }
		typealias Get = @convention(c) (AnyObject, Selector, UInt64) -> Float
		typealias Set = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
		let getSelector = NSSelectorFromString("brightnessForKeyboard:")
		let setSelector = NSSelectorFromString("setBrightness:forKeyboard:")
		guard client.responds(to: getSelector), client.responds(to: setSelector) else { return .missing }
		let get = unsafeBitCast(client.method(for: getSelector), to: Get.self)
		let set = unsafeBitCast(client.method(for: setSelector), to: Set.self)
		return Self(brightness: { get(client, getSelector, id) }, setBrightness: { _ = set(client, setSelector, $0, id) })
	}

	/// A Mac without a backlight.
	static let missing = Self(brightness: { nil }, setBrightness: { _ in })
}
