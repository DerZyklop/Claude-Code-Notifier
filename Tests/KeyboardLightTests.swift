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
struct KeyAreaTests {
	@Test func noAreaHasAnLEDTwiceOrOneThatDoesNotExist() {
		for area in KeyArea.allCases {
			#expect(Set(area.leds).count == area.leds.count)
			#expect(area.leds.allSatisfy { $0 < NuPhyKeyboard.keyCount || NuPhyKeyboard.sideLights.contains($0) })
		}
	}

	@Test func areasOfTodaysLook() {
		#expect(KeyArea.firstTwoRows.leds.sorted() == Array(0..<31))
		// F11, F12, Del, Backspace and =.
		#expect(KeyArea.topRightCorner.leds == [13, 14, 15, 16, 17])
		// Esc, F1, the 1 key and the key left of it.
		#expect(KeyArea.topLeftFour.leds == [0, 1, 29, 30])
		#expect(KeyArea.leftSide.leds + KeyArea.rightSide.leds == Array(NuPhyKeyboard.sideLights))
	}

	@Test func allKeysAreAllKeyLEDs() {
		#expect(KeyArea.allKeys.leds == Array(0..<NuPhyKeyboard.keyCount))
	}

	@Test func rightColumnHasTheRightEndOfEachRow() {
		let leds = KeyArea.rightColumn.leds
		#expect(leds == [15, 16, 45, 46, 73, 74])
		for (row, led) in zip(NuPhyKeyboard.rows, leds) {
			#expect(row.contains(led))
			#expect(row.allSatisfy { NuPhyKeyboard.keyX[$0] <= NuPhyKeyboard.keyX[led] })
		}
	}

	@Test func rowsCoverAllKeysOnce() {
		#expect(NuPhyKeyboard.rows.flatMap { $0 } == Array(0..<NuPhyKeyboard.keyCount))
		#expect(NuPhyKeyboard.layoutX.count == NuPhyKeyboard.keyCount)
	}

	@Test func sideBarsSitAtBothEnds() {
		#expect(NuPhyKeyboard.keyX[100] == 0)
		#expect(NuPhyKeyboard.keyX[111] == NuPhyKeyboard.rowWidth - NuPhyKeyboard.keyWidth)
	}
}

@MainActor
struct KeyboardMappingTests {
	@Test func defaultsGiveTodaysLook() {
		let mapping = KeyboardMapping(defaults: MemoryDefaults())
		#expect(mapping.areas(of: .work) == [.firstTwoRows])
		#expect(mapping.areas(of: .waiting) == [.topRightCorner])
		#expect(mapping.areas(of: .ring) == [.leftSide, .rightSide])
		#expect(mapping.areas(of: .unread) == [.topLeftFour, .leftSide])
		#expect(mapping.brightness(of: .work) == 0.6)
		#expect(mapping.brightness(of: .ring) == 1)
		#expect(mapping.lights == KeyboardMapping.defaultLights)
	}

	@Test func onlyChangedValuesAreStored() {
		let defaults = MemoryDefaults()
		let mapping = KeyboardMapping(defaults: defaults)
		mapping.setAreas([.rightSide, .leftSide], of: .ring)
		mapping.setBrightness(1, of: .waiting)
		#expect(defaults.dictionaryRepresentation().isEmpty)
		mapping.setAreas([.allKeys], of: .ring)
		mapping.setBrightness(0.3, of: .ring)
		#expect(defaults.dictionaryRepresentation().count == 2)
		mapping.setAreas(KeySignal.ring.defaultAreas, of: .ring)
		mapping.setBrightness(1, of: .ring)
		#expect(defaults.dictionaryRepresentation().isEmpty)
	}

	@Test func valuesComeBack() {
		let defaults = MemoryDefaults()
		KeyboardMapping(defaults: defaults).setAreas([.rightColumn, .leftSide], of: .waiting)
		KeyboardMapping(defaults: defaults).setBrightness(0.25, of: .waiting)
		KeyboardMapping(defaults: defaults).setAreas([], of: .unread)
		let mapping = KeyboardMapping(defaults: defaults)
		#expect(mapping.areas(of: .waiting) == [.leftSide, .rightColumn])
		#expect(mapping.brightness(of: .waiting) == 0.25)
		#expect(mapping.areas(of: .unread).isEmpty)
		#expect(mapping.lights[.unread]?.leds.isEmpty == true)
	}

	@Test func brightnessStaysBetweenZeroAndOne() {
		let mapping = KeyboardMapping(defaults: MemoryDefaults())
		mapping.setBrightness(3, of: .work)
		#expect(mapping.brightness(of: .work) == 1)
	}

	@Test func manyLEDsStayAtTheLimitOfNuPhy() {
		#expect(KeyboardMapping.light(areas: [.allKeys], brightness: 1).level == 1)
		#expect(KeyboardMapping.light(areas: [.firstTwoRows], brightness: 0.6).level == 0.6)
		#expect(KeyboardMapping.light(areas: [.leftSide, .rightSide], brightness: 1).level == NuPhyKeyboard.fullBrightness)
		#expect(KeyboardMapping.light(areas: [.topRightCorner], brightness: 0.5).level == 0.5 * NuPhyKeyboard.fullBrightness)
	}
}

@MainActor
struct KeyboardLightSceneTests {
	typealias Scene = KeyboardLight.Scene
	/// Del, a side light of the left bar and the 1 key.
	let topRight = 15, left = 100, wave = 29
	let full = NuPhyKeyboard.fullBrightness

	func isClose(_ a: Double?, _ b: Double) -> Bool {
		a.map { abs($0 - b) < 1e-9 } ?? false
	}

	@Test func showsTheNormalEffectWithoutAnything() {
		for led in 0..<NuPhyKeyboard.ledCount { #expect(Scene().frame(led: led, at: 10) == nil) }
		#expect(!Scene().isMoving(at: 10))
	}

	@Test func segmentStartsAtTheLeftAndRunsToTheRight() {
		let scene = Scene(wave: .work, waveStart: 0)
		let bright = 0.6, dim = KeyboardLight.dimShare * 0.6
		// LED 30 is the key at the left end of the second row, LED 16 the one at the right end.
		#expect(isClose(scene.frame(led: 30, at: 0)?.brightness, bright))
		#expect(isClose(scene.frame(led: 16, at: 0)?.brightness, dim))
		#expect(isClose(scene.frame(led: 30, at: Spinner.runDuration / 2)?.brightness, dim))
		#expect(isClose(scene.frame(led: 22, at: Spinner.runDuration / 2)?.brightness, bright))
		#expect(scene.frame(led: 30, at: 0)?.color == Spinner.color)
		#expect(scene.frame(led: 40, at: 0) == nil)
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
		#expect(scene.frame(led: 0, at: 0.3) == scene.frame(led: 30, at: 0.3))
		// Without other signals, the keys at the right end show the wave too.
		#expect(scene.frame(led: topRight, at: 0.3) == scene.frame(led: 16, at: 0.3))
	}

	@Test func waitingShowsOnTheThreeKeysAndTheRowsKeepTheWave() {
		let scene = Scene(wave: .report, waveStart: 0, isWaiting: true)
		#expect(scene.frame(led: topRight, at: 3) == Scene.Frame(color: Blink1.orange, brightness: full))
		#expect(scene.frame(led: 16, at: 3) == Scene.Frame(color: Blink1.orange, brightness: full))
		#expect(scene.frame(led: 17, at: 3)?.color == Blink1.orange)
		#expect(scene.frame(led: 18, at: 3)?.color == Spinner.reportColor)
		#expect(scene.frame(led: wave, at: 3)?.color == Spinner.reportColor)
		#expect(scene.frame(led: left, at: 3) == nil)
		#expect(scene.isMoving(at: 3))
	}

	@Test func waitingWithoutWaveLeavesTheRowsToTheNormalEffect() {
		let scene = Scene(isWaiting: true)
		#expect(scene.frame(led: wave, at: 3) == nil)
		#expect(scene.frame(led: topRight, at: 3) != nil)
		#expect(!scene.isMoving(at: 3))
	}

	@Test func unreadReportColorsTheLeftBarAndTheFourKeysAtTheLeftPurple() {
		let scene = Scene(hasUnread: true)
		let mark = Scene.Frame(color: Spinner.reportColor, brightness: full)
		for led in [0, 1, 29, 30, 100, 105] { #expect(scene.frame(led: led, at: 3) == mark) }
		#expect(scene.frame(led: topRight, at: 3) == nil)
		#expect(scene.frame(led: 106, at: 3) == nil)
		#expect(!scene.isMoving(at: 3))
	}

	@Test func unreadWinsOverTheWaveAndLeavesTheThreeKeysToTheBubble() {
		let scene = Scene(wave: .work, waveStart: 0, isWaiting: true, hasUnread: true)
		#expect(scene.frame(led: 0, at: 3)?.color == Spinner.reportColor)
		#expect(scene.frame(led: 2, at: 3)?.color == Spinner.color)
		#expect(scene.frame(led: topRight, at: 3)?.color == Blink1.orange)
	}

	@Test func ringPeaksInFullRedOnTheSideLightsOnly() {
		let scene = Scene(isWaiting: true, ringStart: 0)
		let peakTime = AttentionBubble.glowTimes.down * AttentionBubble.ringLength - 0.01
		let peak = scene.frame(led: left, at: peakTime)!
		#expect(NuPhyKeyboard.rgb(peak.color, brightness: peak.brightness) == [255, 0, 0])
		#expect(scene.frame(led: topRight, at: peakTime)!.brightness == full)
		#expect(scene.frame(led: wave, at: peakTime) == nil)
		#expect(scene.isMoving(at: 0.5))
		// After the ring, the side lights show the normal effect again.
		#expect(scene.frame(led: left, at: Scene.ringLength + 0.01) == nil)
		#expect(!scene.isMoving(at: Scene.ringLength + 0.01))
	}

	@Test func ringRisesFromTheSignalBelowAndGivesItBack() {
		let scene = Scene(hasUnread: true, ringStart: 0)
		let mark = Scene.Frame(color: Spinner.reportColor, brightness: full)
		#expect(scene.frame(led: left, at: 0)?.brightness == full)
		#expect(scene.frame(led: left, at: Scene.ringLength + 0.01) == mark)
		// The right bar has no signal below the ring.
		#expect(scene.frame(led: 106, at: Scene.ringLength + 0.01) == nil)
	}

	@Test func ringStartsAndEndsDark() {
		let scene = Scene(isWaiting: true, ringStart: 0)
		#expect(scene.frame(led: left, at: 0)!.brightness == 0)
		#expect(scene.frame(led: left, at: Scene.ringLength - 0.001)!.brightness < 0.05)
	}

	@Test func chosenAreasAndBrightnessShow() {
		let defaults = MemoryDefaults()
		let mapping = KeyboardMapping(defaults: defaults)
		mapping.setAreas([.allKeys], of: .waiting)
		mapping.setBrightness(0.5, of: .waiting)
		let scene = Scene(lights: mapping.lights, isWaiting: true)
		#expect(scene.frame(led: 50, at: 3) == Scene.Frame(color: Blink1.orange, brightness: 0.5))
		#expect(scene.frame(led: left, at: 3) == nil)
	}
}
