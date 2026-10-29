import AppKit
import IOKit.hid

/// The key lights of a NuPhy Air75 V2 with the `notifier` firmware, on the USB cable. The firmware is a QMK keymap in
/// the folder `nuphy-qmk-notifier` next to this app. It lets the app color each LED over the VIA custom channel. The
/// colors stay in the working memory of the keyboard, so they are gone when you unplug it. Over Bluetooth and
/// 2.4 GHz, the keyboard has no VIA channel. The stock firmware of NuPhy ignores the commands.
@MainActor
final class NuPhyKeyboard {
	static let vendorID = 0x19F5
	static let productID = 0x3246
	/// The VIA channel of QMK: a raw HID interface with this usage page and usage.
	static let usagePage = 0xFF60
	static let usage = 0x61
	static let reportSize = 32

	/// The LEDs in the order of `rgb_matrix.layout` of NuPhy: the first row from left to right, the second row from
	/// right to left, then the other keys. LED 84 is always off.
	static let firstRow = 0..<16
	static let secondRow = 16..<31
	/// The left edge of each key of the first two rows, by LED, from `rgb_matrix.layout`. Backspace is two keys wide.
	static let keyX: [Double] = Array(stride(from: 0.0, through: 150, by: 10))
		+ [150, 130, 120, 110, 100, 90, 80, 70, 60, 50, 40, 30, 20, 10, 0]
	static let keyWidth = 10.0
	static let rowWidth = 160.0
	/// The side lights, from the bottom of the left bar to the top, then from the top of the right bar to the bottom.
	/// LED 84 to 99 do not exist.
	static let sideLights = 100..<112
	static let leftBar = 100..<106
	static let ledCount = 112
	/// The keyboard of NuPhy allows LED values up to 128, see `max_brightness` in its `keyboard.json`. All keys at full
	/// power need more current than many USB ports give.
	static let maxValue = 128.0
	/// The brightness of the LED value 255. Only for a few keys.
	static let fullBrightness = 255 / maxValue

	/// The VIA command »set value« on the custom channel 0, then one of these values.
	static let setValue: UInt8 = 0x07
	static let customChannel: UInt8 = 0x00
	enum Value: UInt8 {
		/// The first LED, the count of LEDs, then red, green and blue of each.
		case setColors = 1
		/// The normal effect of the keyboard shows again on all keys.
		case clear = 2
	}

	static let ledsPerReport = 9

	/// Called when a keyboard connects.
	var onConnect: (() -> Void)?
	var isConnected: Bool { device != nil }

	private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
	private var device: IOHIDDevice?
	/// The color that the app sent last for each LED, `nil` for the normal effect. The app sends only changes.
	private var sent = [[UInt8]?](repeating: nil, count: ledCount)

	init() {
		IOHIDManagerSetDeviceMatching(manager, [
			kIOHIDVendorIDKey: Self.vendorID,
			kIOHIDProductIDKey: Self.productID,
			kIOHIDPrimaryUsagePageKey: Self.usagePage,
			kIOHIDPrimaryUsageKey: Self.usage,
		] as CFDictionary)
		let context = Unmanaged.passUnretained(self).toOpaque()
		IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
			let keyboard = Unmanaged<NuPhyKeyboard>.fromOpaque(context!).takeUnretainedValue()
			MainActor.assumeIsolated { keyboard.connect(device) }
		}, context)
		IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
			let keyboard = Unmanaged<NuPhyKeyboard>.fromOpaque(context!).takeUnretainedValue()
			MainActor.assumeIsolated { keyboard.disconnect(device) }
		}, context)
		IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
		IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
	}

	/// Shows each LED of `lights` in its color, at its brightness from 0 to 1, or up to ``fullBrightness``. The LEDs
	/// that are not in `lights` show the normal effect of the keyboard.
	func show(_ lights: [Int: (color: NSColor, brightness: Double)]) {
		var colors = [[UInt8]?](repeating: nil, count: Self.ledCount)
		for (led, light) in lights { colors[led] = Self.rgb(light.color, brightness: light.brightness) }
		if Self.releases(from: sent, to: colors) {
			send(Self.report(.clear))
			sent = sent.map { _ in nil }
		}
		for report in Self.reports(from: sent, to: colors) { send(report) }
		sent = colors
	}

	/// Whether an LED goes back to the normal effect. The only way is the clear command, which clears all LEDs.
	static func releases(from old: [[UInt8]?], to new: [[UInt8]?]) -> Bool {
		zip(old, new).contains { $0 != nil && $1 == nil }
	}

	/// Gives all keys the normal effect of the keyboard back.
	func clear() {
		guard sent.contains(where: { $0 != nil }) else { return }
		send(Self.report(.clear))
		sent = sent.map { _ in nil }
	}

	/// The LED values of `color` at `brightness`: ``maxValue`` at 1, and 255 at ``fullBrightness``.
	static func rgb(_ color: NSColor, brightness: Double) -> [UInt8] {
		guard let srgb = color.usingColorSpace(.sRGB) else { return [0, 0, 0] }
		let level = min(max(brightness, 0), fullBrightness) * maxValue
		return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent].map { UInt8(min(max($0 * level, 0), 255).rounded()) }
	}

	/// A report of 32 bytes for `value`.
	static func report(_ value: Value, _ data: [UInt8] = []) -> [UInt8] {
		let bytes = [setValue, customChannel, value.rawValue] + data
		return bytes + [UInt8](repeating: 0, count: reportSize - bytes.count)
	}

	/// The reports that change the LEDs from `old` to `new`. One report sets a run of at most ``ledsPerReport`` changed
	/// LEDs in a row.
	static func reports(from old: [[UInt8]?], to new: [[UInt8]?]) -> [[UInt8]] {
		var runs: [ClosedRange<Int>] = []
		var start: Int?
		for led in 0...new.count {
			let isChanged = led < new.count && new[led] != nil && new[led] != old[led]
			let fits = start.map { led - $0 < ledsPerReport } ?? true
			if isChanged, fits, start == nil { start = led }
			if let first = start, !isChanged || !fits {
				runs.append(first...(led - 1))
				start = isChanged ? led : nil
			}
		}
		return runs.map { run in report(.setColors, [UInt8(run.lowerBound), UInt8(run.count)] + run.flatMap { new[$0]! }) }
	}

	/// Clears all keys first, also the colors of an app that crashed, because ``clear()`` skips keys without a color.
	private func connect(_ device: IOHIDDevice) {
		self.device = device
		send(Self.report(.clear))
		sent = sent.map { _ in nil }
		onConnect?()
	}

	private func disconnect(_ device: IOHIDDevice) {
		guard device == self.device else { return }
		self.device = nil
	}

	private func send(_ report: [UInt8]) {
		guard let device else { return }
		IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, report, report.count)
	}
}
