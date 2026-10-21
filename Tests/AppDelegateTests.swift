import Foundation
import Testing
@testable import ClaudeCodeNotifier

@MainActor @Suite struct MigrateSettingsTests {
	@Test func copiesAllSettings() {
		let old = MemoryDefaults(), current = MemoryDefaults()
		let event = Date(timeIntervalSince1970: 1_800_000_000)
		old.set(false, forKey: SettingsKey.notifyOnDone)
		old.set(false, forKey: SettingsKey.playsSound)
		old.set(true, forKey: SettingsKey.muted)
		old.set(event, forKey: HookSetup.lastClaudeEventKey)

		AppDelegate.migrateSettings(from: old, to: current)

		#expect(current.object(forKey: SettingsKey.notifyOnDone) as? Bool == false)
		#expect(current.object(forKey: SettingsKey.playsSound) as? Bool == false)
		#expect(current.object(forKey: SettingsKey.muted) as? Bool == true)
		#expect(current.object(forKey: HookSetup.lastClaudeEventKey) as? Date == event)
		#expect(current.object(forKey: "migratedSettings") as? Bool == true)
		// The old settings stay.
		#expect(old.object(forKey: SettingsKey.muted) as? Bool == true)
		#expect(old.object(forKey: "migratedSettings") == nil)
	}

	@Test func skipsMissingAndUnknownSettings() {
		let old = MemoryDefaults(), current = MemoryDefaults()
		old.set(true, forKey: SettingsKey.muted)
		old.set("value", forKey: "otherKey")
		current.set(false, forKey: SettingsKey.playsSound)

		AppDelegate.migrateSettings(from: old, to: current)

		#expect(current.object(forKey: SettingsKey.muted) as? Bool == true)
		#expect(current.object(forKey: SettingsKey.playsSound) as? Bool == false)
		#expect(current.object(forKey: SettingsKey.notifyOnDone) == nil)
		#expect(current.object(forKey: HookSetup.lastClaudeEventKey) == nil)
		#expect(current.object(forKey: "otherKey") == nil)
		#expect(current.object(forKey: "migratedSettings") as? Bool == true)
	}

	@Test func emptyOldSuiteOnlyMarksTheMigration() {
		let old = MemoryDefaults(), current = MemoryDefaults()

		AppDelegate.migrateSettings(from: old, to: current)

		#expect(current.object(forKey: "migratedSettings") as? Bool == true)
		for key in [SettingsKey.notifyOnDone, SettingsKey.playsSound, SettingsKey.muted, HookSetup.lastClaudeEventKey] {
			#expect(current.object(forKey: key) == nil)
		}
	}

	@Test func runsOnlyOnce() {
		let old = MemoryDefaults(), current = MemoryDefaults()
		old.set(false, forKey: SettingsKey.muted)
		AppDelegate.migrateSettings(from: old, to: current)

		old.set(true, forKey: SettingsKey.muted)
		old.set(false, forKey: SettingsKey.playsSound)
		AppDelegate.migrateSettings(from: old, to: current)

		#expect(current.object(forKey: SettingsKey.muted) as? Bool == false)
		#expect(current.object(forKey: SettingsKey.playsSound) == nil)
	}

	/// Any value counts, even `false`.
	@Test(arguments: [true, false])
	func doesNothingWhenMigratedBefore(migrated: Bool) {
		let old = MemoryDefaults(), current = MemoryDefaults()
		old.set(true, forKey: SettingsKey.muted)
		current.set(migrated, forKey: "migratedSettings")

		AppDelegate.migrateSettings(from: old, to: current)

		#expect(current.object(forKey: SettingsKey.muted) == nil)
		#expect(current.object(forKey: "migratedSettings") as? Bool == migrated)
	}

	@Test func withoutOldSettingsNothingIsMarked() {
		let current = MemoryDefaults()

		AppDelegate.migrateSettings(from: nil, to: current)

		#expect(current.object(forKey: "migratedSettings") == nil)
	}
}
