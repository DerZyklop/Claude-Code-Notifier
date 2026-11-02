import Testing
@testable import ClaudeCodeNotifier

@MainActor
struct MacBookBacklightTests {
	let firstStep = MacBookBacklight.brightness(atStep: 1)

	/// A backlight that records each brightness the app sets.
	final class Recorder {
		var brightness: Float = 0.4
		var sets: [Float] = []

		var backlight: MacBookBacklight.Backlight {
			MacBookBacklight.Backlight(brightness: { self.brightness }, setBrightness: { self.sets.append($0) })
		}
	}

	@Test func workFadesTheBacklightDownFirstAndTheEndGivesBackTheBrightnessOfMacOS() {
		let recorder = Recorder()
		let light = MacBookBacklight(backlight: recorder.backlight, defaults: MemoryDefaults())
		light.show(waves: [.work])
		#expect(light.isBlinking)
		#expect(recorder.sets == [firstStep])
		light.show(waves: [])
		#expect(!light.isBlinking)
		#expect(recorder.sets == [firstStep, 0.4])
	}

	@Test func eachFadeTakesOneSecondAndEasesBetweenOnAndOff() {
		#expect(MacBookBacklight.fadeTime == 1)
		let steps = MacBookBacklight.stepsPerFade
		#expect(MacBookBacklight.brightness(atStep: 0) == 1)
		#expect(abs(MacBookBacklight.brightness(atStep: steps)) < 0.001)
		#expect(abs(MacBookBacklight.brightness(atStep: steps / 2) - 0.5) < 0.001)
		#expect(MacBookBacklight.brightness(atStep: 1) > 0.75)
		#expect(MacBookBacklight.brightness(atStep: steps + 1) == MacBookBacklight.brightness(atStep: steps - 1))
	}

	@Test func aReportBlinksToo() {
		let recorder = Recorder()
		let light = MacBookBacklight(backlight: recorder.backlight, defaults: MemoryDefaults())
		light.show(waves: [.report])
		#expect(light.isBlinking)
		light.turnOff()
	}

	@Test func withoutWorkTheAppNeverTouchesTheBacklight() {
		let recorder = Recorder()
		let light = MacBookBacklight(backlight: recorder.backlight, defaults: MemoryDefaults())
		light.show(waves: [])
		light.turnOff()
		#expect(recorder.sets.isEmpty)
	}

	@Test func theSwitchStopsTheBlinkAndStartsItAgain() {
		let recorder = Recorder()
		let defaults = MemoryDefaults()
		let light = MacBookBacklight(backlight: recorder.backlight, defaults: defaults)
		light.show(waves: [.work])
		SettingsKey.set(SettingsKey.usesMacBookBacklight, to: false, in: defaults)
		light.settingsChanged()
		#expect(!light.isBlinking)
		#expect(recorder.sets == [firstStep, 0.4])
		light.show(waves: [.work])
		#expect(recorder.sets == [firstStep, 0.4])
		SettingsKey.set(SettingsKey.usesMacBookBacklight, to: true, in: defaults)
		light.settingsChanged()
		#expect(light.isBlinking)
		light.turnOff()
	}

	@Test func aMacWithoutBacklightDoesNotBlink() {
		let light = MacBookBacklight(backlight: .missing, defaults: MemoryDefaults())
		light.show(waves: [.work])
		#expect(!light.isBlinking)
	}
}
