import AppKit
import Testing
@testable import ClaudeCodeNotifier

@MainActor
struct NuPhyKeyboardTests {
	@Test func reportHas32BytesWithCommandChannelAndValue() {
		let report = NuPhyKeyboard.report(.setValue, .color, [0, 255])
		#expect(report.count == 32)
		#expect(Array(report.prefix(5)) == [0x07, 0x03, 0x04, 0x00, 0xFF])
		#expect(report.dropFirst(5).allSatisfy { $0 == 0 })
	}

	@Test func readsTheOwnLightFromAllReplies() {
		var values: [NuPhyKeyboard.Value: [UInt8]] = [:]
		for reply: [UInt8] in [[0x08, 0x03, 0x01, 0x00, 0], [0x08, 0x03, 0x02, 0x02, 0], [0x08, 0x03, 0x03, 0x7F, 0]] {
			let (value, data) = NuPhyKeyboard.readReply(reply)!
			values[value] = data
		}
		#expect(NuPhyKeyboard.lighting(from: values) == nil)
		let (value, data) = NuPhyKeyboard.readReply([0x08, 0x03, 0x04, 0x9F, 0xFF])!
		values[value] = data
		#expect(NuPhyKeyboard.lighting(from: values) == NuPhyKeyboard.Lighting(brightness: 0, effect: 2, speed: 0x7F, hue: 0x9F, saturation: 0xFF))
	}

	@Test func ignoresOtherReplies() {
		#expect(NuPhyKeyboard.readReply([0x07, 0x03, 0x01, 0xC8, 0]) == nil)
		#expect(NuPhyKeyboard.readReply([0xFF, 0x03, 0x01, 0, 0]) == nil)
		#expect(NuPhyKeyboard.readReply([0x08, 0x02, 0x01, 0, 0]) == nil)
	}

	@Test func redIsHueZeroAtFullSaturation() {
		let (hue, saturation) = NuPhyKeyboard.hueAndSaturation(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
		#expect(hue == 0)
		#expect(saturation == 255)
	}
}

@MainActor
struct KeyboardLightSceneTests {
	typealias Scene = KeyboardLight.Scene

	@Test func showsTheOwnLightWithoutAnything() {
		#expect(Scene().frame(at: 10) == nil)
		#expect(!Scene().isMoving(at: 10))
	}

	@Test func breathStartsBrightAndIsDimInTheMiddle() {
		let scene = Scene(wave: KeyboardLight.breath(.work), waveStart: 0)
		let range = KeyboardLight.workBrightness
		#expect(abs(scene.frame(at: 0)!.brightness - range.upperBound) < 1e-9)
		#expect(abs(scene.frame(at: Blink1.breathDuration / 2)!.brightness - range.lowerBound) < 1e-9)
		#expect(scene.isMoving(at: 0))
	}

	@Test func badgeWinsOverTheWaveAndStays() {
		let scene = Scene(wave: KeyboardLight.breath(.report), badge: .unread)
		#expect(scene.frame(at: 3) == Scene.Frame(color: Spinner.reportColor, brightness: KeyboardLight.badgeBrightness))
		#expect(!scene.isMoving(at: 3))
	}

	@Test func ringPeaksInFullRedAndGoesBackToTheBadge() {
		let scene = Scene(badge: .asksYou, ringStart: 0)
		let peak = scene.frame(at: AttentionBubble.glowTimes.down * AttentionBubble.ringLength - 0.01)!
		#expect(peak.brightness == 1)
		#expect(scene.isMoving(at: 0.5))
		let after = scene.frame(at: Scene.ringLength + 0.01)!
		#expect(after.brightness == KeyboardLight.badgeBrightness)
		#expect(!scene.isMoving(at: Scene.ringLength + 0.01))
	}

	@Test func pulseBlinksOnAndOffThenEnds() {
		let scene = Scene(badge: .asksYou, pulse: Scene.Pulse(color: Spinner.color, start: 0))
		#expect(scene.frame(at: Blink1.pulseFade)!.brightness == 1)
		#expect(scene.frame(at: Blink1.pulseStep + Blink1.pulseFade)!.brightness < 1e-9)
		#expect(scene.isMoving(at: 0.1))
		#expect(scene.frame(at: Scene.pulseLength + 0.01)!.brightness == KeyboardLight.badgeBrightness)
	}
}
