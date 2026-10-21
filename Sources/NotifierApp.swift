import AppKit
import SwiftUI
import UserNotifications

@main
struct NotifierApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

	/// The menu bar item is ``StatusMenu``, and the setup window is ``SetupWindow``. A SwiftUI app needs a scene anyway.
	var body: some Scene {
		Settings { EmptyView() }
	}
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
	private let server = EventServer(port: eventPort)
	private var settingsTimer: Timer?
	private var statusMenu: StatusMenu?

	func applicationDidFinishLaunching(_ notification: Notification) {
		Self.migrateSettings()
		statusMenu = MainActor.assumeIsolated { StatusMenu() }
		let center = UNUserNotificationCenter.current()
		center.delegate = self
		center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

		server.start(
			onEvent: { data in Task { @MainActor in SessionStore.shared.handle(data) } },
			onStateChange: { error in Task { @MainActor in self.listenerStateChanged(error: error) } }
		)

		// Notices when the hooks are removed or changed later. The test reruns only when the hook commands change.
		settingsTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
			Task { @MainActor in HookSetup.shared.refresh() }
		}
	}

	/// Copies the settings from the first bundle ID, `local.claude-code-notifier`, once. The app got a new ID because
	/// Notification Center kept showing a placeholder icon for the old one.
	static func migrateSettings(from old: UserDefaults? = UserDefaults(suiteName: "local.claude-code-notifier"), to current: UserDefaults = .standard) {
		guard current.object(forKey: "migratedSettings") == nil, let old else { return }
		for key in [SettingsKey.notifyOnDone, SettingsKey.playsSound, SettingsKey.muted, "lastClaudeEvent"] {
			if let value = old.object(forKey: key) { current.set(value, forKey: key) }
		}
		current.set(true, forKey: "migratedSettings")
	}

	/// Checks the setup once the server knows whether it listens, and shows the setup window if anything is missing.
	@MainActor
	private func listenerStateChanged(error: String?) {
		let setup = HookSetup.shared
		let isFirstState = setup.listenerError == nil
		setup.listenerError = .some(error)
		guard isFirstState else { return }

		setup.refresh()
		// Waits for the command test and the notification permission.
		Task {
			try? await Task.sleep(nanoseconds: 3_500_000_000)
			if !setup.isComplete || setup.lastClaudeEvent == nil { SetupWindow.show() }
		}
	}

	/// Show the banner even while this app counts as active, e.g. while its menu is open.
	func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
		completionHandler([.banner, .sound])
	}

	/// A click on a notification brings VS Code to the front.
	func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
		Task { @MainActor in activateVSCode() }
		completionHandler()
	}
}

/// Brings VS Code to the front, if it runs. It does not ask VS Code to open anything: VS Code would open a new window for
/// a folder that a window shows only as part of a workspace, and there is no way to name a window from outside.
@MainActor
func activateVSCode() {
	NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.VSCode").first?.activate()
}

extension HookSetup {
	/// Something keeps the notifications from working. A missing first event from Claude Code does not count.
	var hasProblem: Bool { problem != nil }

	/// The problem that keeps the notifications from working, for the menu, or `nil` if there is none.
	var problem: String? {
		if !isListening { return "Not Listening" }
		if notificationsAllowed == false { return "Notifications Blocked" }
		if case .failed = commandTest { return "Hooks Not Working" }
		if !hooksConfigured { return "Hooks Not Working" }
		return nil
	}
}
