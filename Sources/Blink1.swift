import AppKit
import IOKit.hid

/// A blink(1) USB light: bright orange while a session asks you, bright purple while a report runs or waits to be
/// opened, dim green while sessions work, and off without all of them. A light that you plug in later gets the current color too.
@MainActor
final class Blink1 {
	static let shared = Blink1()
	static let vendorID = 0x27B8
	static let productID = 0x01ED
	/// The fade to a new color, in units of 10 ms.
	static let fadeTime = 30

	private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
	/// Red, green and blue for the light. Black turns it off.
	private var rgb: [UInt8] = [0, 0, 0]

	private init() {
		IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: Self.vendorID, kIOHIDProductIDKey: Self.productID] as CFDictionary)
		IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
			let blink1 = Unmanaged<Blink1>.fromOpaque(context!).takeUnretainedValue()
			MainActor.assumeIsolated { blink1.send(to: device) }
		}, Unmanaged.passUnretained(self).toOpaque())
		IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
		IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
	}

	/// What the light shows, from the most urgent to the calmest.
	enum State {
		case asksYou, report, working, off
	}

	/// Fades all lights to the color of `state`.
	func show(_ state: State) {
		let rgb = switch state {
		case .asksYou: Self.rgb(AttentionBubble.color, brightness: 1)
		case .report: Self.rgb(Spinner.reportColor, brightness: 1)
		case .working: Self.rgb(Spinner.color, brightness: Self.workBrightness)
		case .off: [UInt8](repeating: 0, count: 3)
		}
		guard rgb != self.rgb else { return }
		self.rgb = rgb
		for device in IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? [] { send(to: device) }
	}

	/// The LED is much brighter than the screen, so it gets the screen color at this share. Work is a calm state and
	/// gets a dim light. A waiting session or a report asks for your attention and gets the full light.
	static let workBrightness = 0.2
	/// The blue LED is stronger than the red and the green one, so blue gets this share.
	static let blueShare = 0.6

	/// The sRGB values without a gamma correction keep the soft mix of the screen color.
	static func rgb(_ color: NSColor, brightness: Double) -> [UInt8] {
		guard let srgb = color.usingColorSpace(.sRGB) else { return [0, 0, 0] }
		return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent * blueShare].map { UInt8(($0 * brightness * 255).rounded()) }
	}

	/// The »fade to RGB« command for both LEDs.
	private func send(to device: IOHIDDevice) {
		let report: [UInt8] = [1, UInt8(ascii: "c")] + rgb + [UInt8(Self.fadeTime >> 8), UInt8(Self.fadeTime & 0xFF), 0, 0]
		IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 1, report, report.count)
	}
}
