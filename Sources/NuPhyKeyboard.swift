import AppKit
import IOKit.hid

/// The backlight of a NuPhy Air75 V2 on the USB cable. The app talks to its QMK firmware over the VIA protocol, the same
/// one that the VIA app uses. The app sends only the »get value« and the »set value« commands of the RGB matrix. It
/// never sends the save command, so every change stays in the working memory of the keyboard: when you unplug it, the
/// keyboard has its own light again. Over Bluetooth and 2.4 GHz, the keyboard has no VIA channel.
@MainActor
final class NuPhyKeyboard {
	static let vendorID = 0x19F5
	static let productID = 0x3246
	/// The VIA channel of QMK: a raw HID interface with this usage page and usage.
	static let usagePage = 0xFF60
	static let usage = 0x61
	static let reportSize = 32

	/// The light of the keyboard in the values of VIA, each from 0 to 255.
	struct Lighting: Equatable {
		var brightness: UInt8
		var effect: UInt8
		var speed: UInt8
		var hue: UInt8
		var saturation: UInt8
	}

	/// The only VIA commands that the app sends.
	enum Command: UInt8 {
		case setValue = 0x07, getValue = 0x08
	}

	/// The values of the RGB matrix channel.
	enum Value: UInt8, CaseIterable {
		case brightness = 1, effect = 2, speed = 3, color = 4
	}

	static let rgbMatrixChannel: UInt8 = 3
	/// The effect with one steady color on all keys.
	static let solidColor: UInt8 = 1

	/// Called when a keyboard is ready, after the app read its own light.
	var onReady: (() -> Void)?
	/// The own light of the keyboard from when it connected, `nil` until the app read it.
	private(set) var ownLighting: Lighting?
	var isReady: Bool { device != nil && ownLighting != nil }

	private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
	private var device: IOHIDDevice?
	/// The light that the app sent last, to send only the values that change.
	private var sent: Lighting?
	/// The values of the own light that came back so far.
	private var readValues: [Value: [UInt8]] = [:]
	private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: reportSize)

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

	/// Shows `color` steady on all keys, at `brightness` from 0 to 1. Does nothing until the keyboard is ready.
	func show(_ color: NSColor, brightness: Double) {
		guard let own = ownLighting else { return }
		let (hue, saturation) = Self.hueAndSaturation(color)
		let level = UInt8((min(max(brightness, 0), 1) * 255).rounded())
		apply(Lighting(brightness: level, effect: Self.solidColor, speed: own.speed, hue: hue, saturation: saturation))
	}

	/// Gives the keyboard its own light back.
	func restore() {
		guard let own = ownLighting else { return }
		apply(own)
	}

	/// The hue and the saturation of `color` in the values of VIA: 256 hue steps make the full circle, so 256 is 0 again.
	static func hueAndSaturation(_ color: NSColor) -> (UInt8, UInt8) {
		guard let srgb = color.usingColorSpace(.sRGB) else { return (0, 0) }
		return (UInt8(Int((srgb.hueComponent * 256).rounded()) % 256), UInt8((srgb.saturationComponent * 255).rounded()))
	}

	/// A report of 32 bytes for `command` on `value`.
	static func report(_ command: Command, _ value: Value, _ data: [UInt8] = []) -> [UInt8] {
		let bytes = [command.rawValue, rgbMatrixChannel, value.rawValue] + data
		return bytes + [UInt8](repeating: 0, count: reportSize - bytes.count)
	}

	/// The value and its data in a reply to »get value«, `nil` for other replies.
	static func readReply(_ bytes: [UInt8]) -> (Value, [UInt8])? {
		guard bytes.count >= 5, bytes[0] == Command.getValue.rawValue, bytes[1] == rgbMatrixChannel,
			let value = Value(rawValue: bytes[2]) else { return nil }
		return (value, Array(bytes[3...4]))
	}

	/// The own light from the replies, `nil` until all values came back.
	static func lighting(from values: [Value: [UInt8]]) -> Lighting? {
		guard let brightness = values[.brightness], let effect = values[.effect], let speed = values[.speed],
			let color = values[.color] else { return nil }
		return Lighting(brightness: brightness[0], effect: effect[0], speed: speed[0], hue: color[0], saturation: color[1])
	}

	/// The color first and the brightness last, so that no key shows the old color in the new brightness.
	private func apply(_ lighting: Lighting) {
		let old = sent
		if old?.hue != lighting.hue || old?.saturation != lighting.saturation {
			send(.setValue, .color, [lighting.hue, lighting.saturation])
		}
		if old?.effect != lighting.effect { send(.setValue, .effect, [lighting.effect]) }
		if old?.speed != lighting.speed { send(.setValue, .speed, [lighting.speed]) }
		if old?.brightness != lighting.brightness { send(.setValue, .brightness, [lighting.brightness]) }
		sent = lighting
	}

	/// Reads the own light. The replies come to ``receive(_:)``.
	private func connect(_ device: IOHIDDevice) {
		self.device = device
		ownLighting = nil
		sent = nil
		readValues = [:]
		IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, Self.reportSize, { context, _, _, _, _, report, length in
			let keyboard = Unmanaged<NuPhyKeyboard>.fromOpaque(context!).takeUnretainedValue()
			let bytes = Array(UnsafeBufferPointer(start: report, count: length))
			MainActor.assumeIsolated { keyboard.receive(bytes) }
		}, Unmanaged.passUnretained(self).toOpaque())
		for value in Value.allCases { send(.getValue, value) }
	}

	private func receive(_ bytes: [UInt8]) {
		guard ownLighting == nil, let (value, data) = Self.readReply(bytes) else { return }
		readValues[value] = data
		guard let own = Self.lighting(from: readValues) else { return }
		ownLighting = own
		sent = own
		onReady?()
	}

	private func disconnect(_ device: IOHIDDevice) {
		guard device == self.device else { return }
		self.device = nil
		ownLighting = nil
		sent = nil
	}

	private func send(_ command: Command, _ value: Value, _ data: [UInt8] = []) {
		guard let device else { return }
		let report = Self.report(command, value, data)
		IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, report, report.count)
	}
}
