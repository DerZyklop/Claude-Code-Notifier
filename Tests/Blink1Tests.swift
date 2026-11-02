import AppKit
import Testing
@testable import ClaudeCodeNotifier

@MainActor
struct Blink1Tests {
	let breath = Blink1.Breath(color: .systemGreen, brightness: 0.04...0.28)

	@Test func breathStartsDimAndEndsBright() {
		#expect(abs(breath.brightness(at: 0) - 0.04) < 1e-9)
		#expect(abs(breath.brightness(at: 1) - 0.28) < 1e-9)
	}

	@Test func breathRisesSlowlyAtBothEnds() {
		let points = stride(from: 0.0, through: 1.0, by: 0.125).map(breath.brightness(at:))
		let changes = zip(points.dropFirst(), points).map { $0 - $1 }
		#expect(changes.allSatisfy { $0 > 0 })
		#expect(changes.first! < changes[3])
		#expect(changes.last! < changes[4])
	}
}

@MainActor
struct Blink1StateTests {
	typealias Scene = LightScene

	@Test func bubbleIsOrangeOnTheLEDs() {
		#expect(Blink1.rgb(LightSignal.orange, brightness: 1) == [255, 48, 0])
	}

	@Test func ringIsPureRed() {
		#expect(Blink1.rgb(LightSignal.ringColor, brightness: 1) == [255, 0, 0])
	}

	@Test func areasMapToTheLEDsOfThePlan() {
		#expect(LightArea.allKeys.blink1LEDs == [1, 2])
		#expect(LightArea.firstRow.blink1LEDs == [1])
		#expect(LightArea.secondRow.blink1LEDs == [2])
		#expect(LightArea.leftSide.blink1LEDs == [1])
		#expect(LightArea.rightSide.blink1LEDs == [1])
		#expect(LightArea.topLeftFour.blink1LEDs == [1])
		#expect(LightArea.topRightCorner.blink1LEDs == [1])
		#expect(LightArea.rightColumn.blink1LEDs == [2])
	}

	@Test func bubbleUsesBothLEDsWithoutWork() {
		let frames = Blink1.frames(of: Scene(device: .blink1, isWaiting: true), pulse: nil, at: 3)
		let orange = Scene.Frame(color: LightSignal.orange, brightness: Blink1.badgeBrightness)
		#expect(frames == [orange, orange])
	}

	@Test func bubbleTakesLEDOneAndTheWaveBreathesOnLEDTwo() {
		let frames = Blink1.frames(of: Scene(device: .blink1, waveStarts: [.work: 0], isWaiting: true), pulse: nil, at: 0)
		#expect(frames[0]?.color == LightSignal.orange)
		#expect(frames[1]?.color == Spinner.color)
		#expect(abs(frames[1]!.brightness - Blink1.workBrightness.upperBound) < 1e-9)
	}

	@Test func waveBreathesDownAndUpAgain() {
		let range = Blink1.reportBrightness
		#expect(abs(Blink1.breath(of: .report, level: 1, at: 0) - range.upperBound) < 1e-9)
		#expect(abs(Blink1.breath(of: .report, level: 1, at: Blink1.breathDuration / 2) - range.lowerBound) < 1e-9)
		#expect(abs(Blink1.breath(of: .report, level: 1, at: Blink1.breathDuration) - range.upperBound) < 1e-9)
		#expect(abs(Blink1.breath(of: .report, level: 0.5, at: 0) - range.upperBound / 2) < 1e-9)
	}

	@Test func ringPeaksInFullRedAndRestsInOrange() {
		let scene = Scene(device: .blink1, waveStarts: [.work: 0], isWaiting: true, ringStart: 0)
		let peakTime = AttentionBubble.glowTimes.down * AttentionBubble.ringLength - 0.01
		let peak = Blink1.frames(of: scene, pulse: nil, at: peakTime)[0]!
		#expect(Blink1.rgb(peak.color, brightness: peak.brightness) == [255, 0, 0])
		#expect(Blink1.frames(of: scene, pulse: nil, at: Scene.ringLength + 0.01)[0]?.color == LightSignal.orange)
	}

	@Test func nothingShowsWithoutSignals() {
		#expect(Blink1.frames(of: Scene(device: .blink1), pulse: nil, at: 3) == [nil, nil])
	}

	@Test func blinksWinOverEverything() {
		let frames = Blink1.frames(of: Scene(device: .blink1, isWaiting: true), pulse: (Spinner.reportColor, 0), at: 0.15)
		#expect(frames == [Scene.Frame(color: Spinner.reportColor, brightness: 1), Scene.Frame(color: Spinner.reportColor, brightness: 1)])
	}

	@Test func blinksFadeUpHoldFadeDownAndPause() {
		#expect(Blink1.pulseBrightness(at: 0) == 0)
		#expect(Blink1.pulseBrightness(at: 0.2) == 1)
		#expect(abs(Blink1.pulseBrightness(at: 0.375) - 0.5) < 1e-9)
		#expect(Blink1.pulseBrightness(at: 0.5) == 0)
	}

	@Test func brightnessIsAShareOfTodaysLook() {
		let mapping = LightMapping(defaults: MemoryDefaults())
		mapping.setBrightness(0.3, of: .work)
		mapping.setBrightness(0.5, of: .waiting)
		let lights = mapping.lights(on: .blink1)
		#expect(lights[.work]?.level == 0.5)
		#expect(lights[.waiting]?.level == 0.5)
		let frames = Blink1.frames(of: Scene(device: .blink1, lights: lights, isWaiting: true), pulse: nil, at: 3)
		#expect(frames[0]?.brightness == Blink1.badgeBrightness / 2)
	}
}
