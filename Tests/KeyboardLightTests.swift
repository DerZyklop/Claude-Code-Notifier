import AppKit
import Testing
@testable import ClaudeCodeNotifier

@MainActor
struct NuPhyKeyboardTests {
	let red: [UInt8] = [128, 0, 0]
	let blue: [UInt8] = [0, 0, 128]

	@Test func clearReportHas32Bytes() {
		let report = NuPhyKeyboard.report(.clear)
		#expect(report.count == 32)
		#expect(Array(report.prefix(3)) == [0x07, 0x00, 0x02])
		#expect(report.dropFirst(3).allSatisfy { $0 == 0 })
	}

	@Test func fullBrightnessStopsAtTheMaximumOfNuPhy() {
		#expect(NuPhyKeyboard.rgb(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), brightness: 1) == red)
		#expect(NuPhyKeyboard.rgb(NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), brightness: 0.5) == [64, 64, 64])
	}

	@Test func fullBrightnessGivesTheFullLEDValue() {
		#expect(NuPhyKeyboard.rgb(KeyboardLight.ringColor, brightness: NuPhyKeyboard.fullBrightness) == [255, 0, 0])
		#expect(NuPhyKeyboard.rgb(KeyboardLight.ringColor, brightness: 5) == [255, 0, 0])
	}

	@Test func sixteenLEDsNeedTwoReportsOfNineAndSeven() {
		let old = [[UInt8]?](repeating: nil, count: 20)
		var new = old
		for led in 0..<16 { new[led] = red }
		let reports = NuPhyKeyboard.reports(from: old, to: new)
		#expect(reports.count == 2)
		#expect(Array(reports[0].prefix(5)) == [0x07, 0x00, 0x01, 0, 9])
		#expect(Array(reports[0][5..<8]) == red)
		#expect(Array(reports[1].prefix(5)) == [0x07, 0x00, 0x01, 9, 7])
		#expect(reports.allSatisfy { $0.count == 32 })
	}

	@Test func onlyChangedLEDsGetAReport() {
		var old = [[UInt8]?](repeating: red, count: 20)
		old[19] = nil
		var new = old
		new[4] = blue
		new[5] = blue
		let reports = NuPhyKeyboard.reports(from: old, to: new)
		#expect(reports.count == 1)
		#expect(Array(reports[0].prefix(11)) == [0x07, 0x00, 0x01, 4, 2] + blue + blue)
		#expect(NuPhyKeyboard.reports(from: old, to: old).isEmpty)
	}

	@Test func zonesCoverTheFirstTwoRowsOnce() {
		let leds = KeyboardLight.Zone.allCases.flatMap { Array($0.leds) }.sorted()
		#expect(leds == Array(0..<31))
		#expect(KeyboardLight.Zone.alert.leds == 13..<16)
	}
}

@MainActor
struct KeyboardLightSceneTests {
	typealias Scene = KeyboardLight.Scene

	@Test func showsTheNormalEffectWithoutAnything() {
		for zone in KeyboardLight.Zone.allCases { #expect(Scene().frame(of: zone, at: 10) == nil) }
		#expect(!Scene().isMoving(at: 10))
	}

	@Test func breathStartsBrightAndIsDimInTheMiddle() {
		let scene = Scene(wave: KeyboardLight.breath(.work), waveStart: 0)
		let range = KeyboardLight.workBrightness
		#expect(abs(scene.frame(of: .wave, at: 0)!.brightness - range.upperBound) < 1e-9)
		#expect(abs(scene.frame(of: .wave, at: Blink1.breathDuration / 2)!.brightness - range.lowerBound) < 1e-9)
		#expect(scene.frame(of: .icon, at: 0) == scene.frame(of: .wave, at: 0))
		#expect(scene.frame(of: .alert, at: 0) == scene.frame(of: .wave, at: 0))
		#expect(scene.isMoving(at: 0))
	}

	@Test func badgeShowsOnTheFirstRowAndTheSecondRowKeepsTheWave() {
		let scene = Scene(wave: KeyboardLight.breath(.report), waveStart: 0, badge: .unread)
		let badge = Scene.Frame(color: Spinner.reportColor, brightness: KeyboardLight.badgeBrightness)
		#expect(scene.frame(of: .icon, at: 3) == badge)
		#expect(scene.frame(of: .alert, at: 3) == badge)
		#expect(abs(scene.frame(of: .wave, at: 0)!.brightness - KeyboardLight.reportBrightness.upperBound) < 1e-9)
		#expect(scene.isMoving(at: 3))
	}

	@Test func badgeWithoutWaveLeavesTheSecondRowOff() {
		let scene = Scene(badge: .asksYou)
		#expect(scene.frame(of: .wave, at: 3) == nil)
		#expect(scene.frame(of: .icon, at: 3) != nil)
		#expect(!scene.isMoving(at: 3))
	}

	@Test func ringPeaksInFullRedOnlyOnTheAlertKeys() {
		let scene = Scene(badge: .asksYou, ringStart: 0)
		let peakTime = AttentionBubble.glowTimes.down * AttentionBubble.ringLength - 0.01
		let peak = scene.frame(of: .alert, at: peakTime)!
		#expect(NuPhyKeyboard.rgb(peak.color, brightness: peak.brightness) == [255, 0, 0])
		#expect(scene.frame(of: .icon, at: peakTime)!.brightness == KeyboardLight.badgeBrightness)
		#expect(scene.frame(of: .wave, at: peakTime) == nil)
		#expect(scene.isMoving(at: 0.5))
		#expect(scene.frame(of: .alert, at: Scene.ringLength + 0.01)!.brightness == KeyboardLight.badgeBrightness)
		#expect(!scene.isMoving(at: Scene.ringLength + 0.01))
	}

	@Test func pulseBlinksBothRowsThenEnds() {
		let scene = Scene(badge: .asksYou, pulse: Scene.Pulse(color: Spinner.color, start: 0))
		for zone in KeyboardLight.Zone.allCases {
			#expect(scene.frame(of: zone, at: Blink1.pulseFade)!.brightness == 1)
			#expect(scene.frame(of: zone, at: Blink1.pulseStep + Blink1.pulseFade)!.brightness < 1e-9)
		}
		#expect(scene.isMoving(at: 0.1))
		#expect(scene.frame(of: .icon, at: Scene.pulseLength + 0.01)!.brightness == KeyboardLight.badgeBrightness)
		#expect(scene.frame(of: .wave, at: Scene.pulseLength + 0.01) == nil)
	}
}
