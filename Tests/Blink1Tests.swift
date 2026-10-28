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
	@Test func waveIsPurpleWhileAReportRuns() {
		#expect(Blink1.Wave(isReporting: true, working: 2) == .report)
		#expect(Blink1.Wave(isReporting: false, working: 1) == .work)
		#expect(Blink1.Wave(isReporting: false, working: 0) == .off)
	}

	@Test func bubbleWinsOverTheDot() {
		#expect(Blink1.Badge(waiting: 1, hasUnread: true) == .asksYou)
		#expect(Blink1.Badge(waiting: 0, hasUnread: true) == .unread)
		#expect(Blink1.Badge(waiting: 0, hasUnread: false) == nil)
	}
}
