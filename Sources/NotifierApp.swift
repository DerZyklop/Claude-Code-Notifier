import AppKit
import SwiftUI
import UserNotifications

@main
struct NotifierApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

	/// The menu bar item is ``StatusMenu``, and the setup window is ``SetupWindow``. A SwiftUI app needs a scene anyway.
	var body: some Scene {
		// No »Settings…« item: its window would be empty and would store its frame in the settings file.
		Settings { EmptyView() }
			.commands { CommandGroup(replacing: .appSettings) {} }
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

	/// The settings file of the first bundle ID, `local.claude-code-notifier`. The app got a new ID because Notification
	/// Center kept showing a placeholder icon for the old one.
	static let oldSettingsFile = FileManager.default.homeDirectoryForCurrentUser
		.appendingPathComponent("Library/Preferences/local.claude-code-notifier.plist")

	/// Copies the changed settings from the old settings file and deletes that file. Also removes the values that older
	/// versions stored but the app does not need.
	static func migrateSettings(from oldFile: URL = oldSettingsFile, to current: UserDefaults = .standard) {
		// Only existing keys: removing a missing key creates an empty settings file.
		for key in ["lastClaudeEvent", "migratedSettings"] where current.object(forKey: key) != nil {
			current.removeObject(forKey: key)
		}
		for (key, value) in SettingsKey.defaultValues where current.object(forKey: key) as? Bool == value {
			current.removeObject(forKey: key)
		}

		guard let data = try? Data(contentsOf: oldFile) else { return }
		let old = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] ?? [:]
		for (key, defaultValue) in SettingsKey.defaultValues where current.object(forKey: key) == nil {
			if let value = old[key] as? Bool, value != defaultValue { current.set(value, forKey: key) }
		}
		// Only the file: `removePersistentDomain(forName:)` leaves an empty file.
		try? FileManager.default.removeItem(at: oldFile)
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
			if !setup.isComplete { SetupWindow.show() }
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
