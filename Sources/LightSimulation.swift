import Foundation

/// The signals that the setup window simulates in the menu bar, on the blink(1) and on the keyboard, so that you can see
/// each one. They stay in memory only. ``StatusMenu`` adds them to the real state. A simulated bubble rings like a real
/// one, but without the sound.
@MainActor
final class LightSimulation: ObservableObject {
	static let shared = LightSimulation()

	@Published var work = false
	@Published var report = false
	@Published var waiting = false
	@Published var unread = false

	/// Whether any signal is on.
	var isActive: Bool { work || report || waiting || unread }

	/// Turns on every signal for `duration`, e.g. at the start of the app, so that you see all lights of the current
	/// mapping. A change of the simulation in this time keeps it on.
	func showAll(for duration: Duration = .seconds(3)) {
		work = true
		report = true
		waiting = true
		unread = true
		Task { @MainActor [weak self] in
			try? await Task.sleep(for: duration)
			guard let self, work, report, waiting, unread else { return }
			stopAll()
		}
	}

	/// Ends every simulation, e.g. when the setup window closes.
	func stopAll() {
		guard isActive else { return }
		work = false
		report = false
		waiting = false
		unread = false
	}
}
