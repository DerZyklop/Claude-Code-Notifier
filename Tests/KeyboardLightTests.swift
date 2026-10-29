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

	@Test func zonesCoverTheFirstTwoRowsAndTheSideLightsOnce() {
		let leds = KeyboardLight.Zone.allCases.flatMap(\.leds).sorted()
		#expect(leds == Array(0..<31) + Array(100..<112))
		#expect(KeyboardLight.Zone.icon.leds == [13, 14, 15])
		#expect(KeyboardLight.Zone.alert.leds == Array(100..<112))
	}

	@Test func anLEDThatLosesItsColorNeedsAClear() {
		var old = [[UInt8]?](repeating: nil, count: 20)
		old[3] = red
		var new = old
		#expect(!NuPhyKeyboard.releases(from: old, to: new))
		new[3] = nil
		#expect(NuPhyKeyboard.releases(from: old, to: new))
		new[5] = blue
		#expect(NuPhyKeyboard.releases(from: [[UInt8]?](repeating: nil, count: 20), to: new) == false)
	}

	@Test func sideLightsFitIntoOneRunOfTwelveInTwoReports() {
		var new = [[UInt8]?](repeating: nil, count: NuPhyKeyboard.ledCount)
		for led in NuPhyKeyboard.sideLights { new[led] = red }
		let reports = NuPhyKeyboard.reports(from: [[UInt8]?](repeating: nil, count: NuPhyKeyboard.ledCount), to: new)
		#expect(reports.map { Array($0.prefix(5)) } == [[0x07, 0x00, 0x01, 100, 9], [0x07, 0x00, 0x01, 109, 3]])
	}
}

@MainActor
struct KeyboardLightSceneTests {
	typealias Scene = KeyboardLight.Scene
	/// One LED of each zone: Del, a side light and the 1 key.
	let icon = 15, alert = 100, wave = 29

	@Test func showsTheNormalEffectWithoutAnything() {
		for zone in KeyboardLight.Zone.allCases {
			for led in zone.leds { #expect(Scene().frame(of: zone, led: led, at: 10) == nil) }
		}
		#expect(!Scene().isMoving(at: 10))
	}

	@Test func segmentStartsAtTheLeftAndRunsToTheRight() {
		let scene = Scene(wave: .work, waveStart: 0)
		let bright = KeyboardLight.segmentBrightness, dim = KeyboardLight.waveBrightness
		// LED 30 is the key at the left end of the second row, LED 16 the one at the right end.
		#expect(scene.frame(of: .wave, led: 30, at: 0)?.brightness == bright)
		#expect(scene.frame(of: .wave, led: 16, at: 0)?.brightness == dim)
		#expect(scene.frame(of: .wave, led: 30, at: Spinner.runDuration / 2)?.brightness == dim)
		#expect(scene.frame(of: .wave, led: 22, at: Spinner.runDuration / 2)?.brightness == bright)
		#expect(scene.frame(of: .wave, led: 30, at: 0)?.color == Spinner.color)
		#expect(scene.isMoving(at: 100))
	}

	@Test func segmentMovesInSmallStepsAndComesBackInAtTheLeft() {
		#expect(Scene.segmentShare(of: 10, at: 5.0 / 160) == 1)
		#expect(abs(Scene.segmentShare(of: 0, at: 5.0 / 160) - 0.5) < 1e-9)
		#expect(abs(Scene.segmentShare(of: 40, at: 5.0 / 160) - 0.5) < 1e-9)
		// Near the end of a run, the segment covers the right end and the left end.
		#expect(Scene.segmentShare(of: 150, at: 150.0 / 160) == 1)
		#expect(Scene.segmentShare(of: 0, at: 150.0 / 160) == 1)
		#expect(Scene.segmentShare(of: 30, at: 150.0 / 160) == 0)
		#expect(Scene.segmentShare(of: 0, at: 1) == Scene.segmentShare(of: 0, at: 0))
	}

	@Test func bothRowsShowTheSameSegment() {
		let scene = Scene(wave: .report, waveStart: 0)
		// LED 0 is Esc and LED 30 the 1 key: both are at the left end.
		#expect(scene.frame(of: .wave, led: 0, at: 0.3) == scene.frame(of: .wave, led: 30, at: 0.3))
		// Without a badge, the icon keys at the right end show the wave too.
		#expect(scene.frame(of: .icon, led: icon, at: 0.3) == scene.frame(of: .wave, led: 16, at: 0.3))
	}

	@Test func badgeShowsOnTheThreeKeysAndTheRowsKeepTheWave() {
		let scene = Scene(wave: .report, waveStart: 0, badge: .unread)
		let badge = Scene.Frame(color: Spinner.reportColor, brightness: KeyboardLight.badgeBrightness)
		#expect(scene.frame(of: .icon, led: icon, at: 3) == badge)
		#expect(scene.frame(of: .wave, led: wave, at: 3)?.color == Spinner.reportColor)
		#expect(scene.frame(of: .alert, led: 106, at: 3) == nil)
		#expect(scene.isMoving(at: 3))
	}

	@Test func badgeWithoutWaveLeavesTheRowsToTheNormalEffect() {
		let scene = Scene(badge: .asksYou)
		#expect(scene.frame(of: .wave, led: wave, at: 3) == nil)
		#expect(scene.frame(of: .icon, led: icon, at: 3) != nil)
		#expect(!scene.isMoving(at: 3))
	}

	@Test func ringPeaksInFullRedOnTheSideLightsOnly() {
		let scene = Scene(badge: .asksYou, ringStart: 0)
		let peakTime = AttentionBubble.glowTimes.down * AttentionBubble.ringLength - 0.01
		let peak = scene.frame(of: .alert, led: alert, at: peakTime)!
		#expect(NuPhyKeyboard.rgb(peak.color, brightness: peak.brightness) == [255, 0, 0])
		#expect(scene.frame(of: .icon, led: icon, at: peakTime)!.brightness == KeyboardLight.badgeBrightness)
		#expect(scene.frame(of: .wave, led: wave, at: peakTime) == nil)
		#expect(scene.isMoving(at: 0.5))
		// After the ring, the side lights show the normal effect again.
		#expect(scene.frame(of: .alert, led: alert, at: Scene.ringLength + 0.01) == nil)
		#expect(!scene.isMoving(at: Scene.ringLength + 0.01))
	}

	@Test func unreadReportColorsOnlyTheLeftSideBarPurple() {
		let scene = Scene(badge: .unread)
		let mark = scene.frame(of: .alert, led: 100, at: 3)!
		#expect(mark.color == Spinner.reportColor)
		#expect(mark.brightness == NuPhyKeyboard.fullBrightness)
		#expect(scene.frame(of: .alert, led: 105, at: 3) == mark)
		#expect(scene.frame(of: .alert, led: 106, at: 3) == nil)
		#expect(scene.frame(of: .alert, led: 111, at: 3) == nil)
		#expect(!scene.isMoving(at: 3))
	}

	@Test func leftSideBarIsNotPurpleWhileTheBubbleShows() {
		let scene = Scene(badge: .asksYou)
		#expect(scene.frame(of: .alert, led: 100, at: 3) == nil)
	}

	@Test func ringStartsAndEndsDark() {
		let scene = Scene(badge: .asksYou, ringStart: 0)
		#expect(scene.frame(of: .alert, led: alert, at: 0)!.brightness == 0)
		#expect(scene.frame(of: .alert, led: alert, at: Scene.ringLength - 0.001)!.brightness < 0.05)
	}
}
