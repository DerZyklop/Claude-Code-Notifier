import Foundation

/// The signals that the setup window simulates on the blink(1) and the keyboard, so that you can see each one. They
/// stay in memory only. ``StatusMenu`` adds them to the real state.
@MainActor
final class LightSimulation: ObservableObject {
	static let shared = LightSimulation()

	/// Wins over the real wave, unless it is off.
	@Published var work = Blink1.Wave.off
	@Published var waiting = false
	@Published var unread = false
	/// Rings once every ``AttentionBubble/ringInterval`` seconds, like the bubble.
	@Published var ring = false {
		didSet {
			guard ring != oldValue else { return }
			ringTimer?.invalidate()
			ringTimer = nil
			if ring { startRing() }
		}
	}

	private var ringTimer: Timer?

	/// Whether any signal is on.
	var isActive: Bool { work != .off || waiting || unread || ring }

	/// Ends every simulation, e.g. when the setup window closes.
	func stopAll() {
		guard isActive else { return }
		work = .off
		waiting = false
		unread = false
		ring = false
	}

	/// The first ring waits a moment, because the blink(1) rings only after ``StatusMenu`` shows the bubble state.
	private func startRing() {
		let timer = Timer(fire: Date().addingTimeInterval(0.2), interval: AttentionBubble.ringInterval, repeats: true) { _ in
			MainActor.assumeIsolated {
				Blink1.shared.ring()
				KeyboardLight.shared.ring()
			}
		}
		// The `common` modes include the one the run loop uses while a menu is open.
		RunLoop.main.add(timer, forMode: .common)
		ringTimer = timer
	}
}
