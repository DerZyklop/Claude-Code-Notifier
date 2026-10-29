import Foundation

/// The signals that the setup window simulates in the menu bar, on the blink(1) and on the keyboard, so that you can see
/// each one. They stay in memory only. ``StatusMenu`` adds them to the real state. A simulated bubble rings like a real
/// one, but without the sound.
@MainActor
final class LightSimulation: ObservableObject {
	static let shared = LightSimulation()

	/// Wins over the real wave, unless it is off.
	@Published var work = Blink1.Wave.off
	@Published var waiting = false
	@Published var unread = false

	/// Whether any signal is on.
	var isActive: Bool { work != .off || waiting || unread }

	/// Ends every simulation, e.g. when the setup window closes.
	func stopAll() {
		guard isActive else { return }
		work = .off
		waiting = false
		unread = false
	}
}
