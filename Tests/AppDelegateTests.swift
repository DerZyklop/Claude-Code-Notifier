import Foundation
import Testing
@testable import ClaudeCodeNotifier

/// An old settings file with the values, in a new temp folder. The test deletes the folder at the end.
private func oldSettingsFile(_ values: [String: Any]) throws -> URL {
	let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeCodeNotifierTests-\(UUID().uuidString)")
	try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
	let file = folder.appendingPathComponent("local.claude-code-notifier.plist")
	try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0).write(to: file)
	return file
}

private func exists(_ file: URL) -> Bool {
	FileManager.default.fileExists(atPath: file.path)
}

@MainActor @Suite struct MigrateSettingsTests {
	@Test func oldFileIsInTheOldPreferences() {
		#expect(AppDelegate.oldSettingsFile.path.hasSuffix("/Library/Preferences/local.claude-code-notifier.plist"))
	}

	@Test func copiesChangedSettingsAndDeletesTheOldFile() throws {
		let file = try oldSettingsFile([SettingsKey.notifyOnDone: false, SettingsKey.playsSound: false, SettingsKey.muted: true,
			"lastClaudeEvent": Date(timeIntervalSince1970: 1_800_000_000)])
		defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
		let current = MemoryDefaults()

		AppDelegate.migrateSettings(from: file, to: current)

		#expect(current.dictionaryRepresentation() as NSDictionary == [SettingsKey.notifyOnDone: false, SettingsKey.playsSound: false, SettingsKey.muted: true] as NSDictionary)
		#expect(!exists(file))
	}

	@Test func defaultValuesAndOtherTypesAreNotCopied() throws {
		let file = try oldSettingsFile([SettingsKey.notifyOnDone: true, SettingsKey.playsSound: "no", SettingsKey.muted: false, "otherKey": "value"])
		defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
		let current = MemoryDefaults()

		AppDelegate.migrateSettings(from: file, to: current)

		#expect(current.dictionaryRepresentation().isEmpty)
		#expect(!exists(file))
	}

	@Test func settingsOfTheNewAppWin() throws {
		let file = try oldSettingsFile([SettingsKey.muted: true, SettingsKey.playsSound: false])
		defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
		let current = MemoryDefaults()
		current.set(false, forKey: SettingsKey.playsSound)

		AppDelegate.migrateSettings(from: file, to: current)

		#expect(current.object(forKey: SettingsKey.muted) as? Bool == true)
		#expect(current.object(forKey: SettingsKey.playsSound) as? Bool == false)
	}

	@Test func invalidOldFileIsDeleted() throws {
		let file = try oldSettingsFile([:])
		defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
		try Data("no property list".utf8).write(to: file)
		let current = MemoryDefaults()

		AppDelegate.migrateSettings(from: file, to: current)

		#expect(current.dictionaryRepresentation().isEmpty)
		#expect(!exists(file))
	}

	/// Each write creates the settings file of the app, so nothing to do must write nothing.
	@Test func withoutOldFileNothingIsWritten() {
		let current = MemoryDefaults()

		AppDelegate.migrateSettings(from: URL(fileURLWithPath: "/nonexistent/local.claude-code-notifier.plist"), to: current)

		#expect(current.dictionaryRepresentation().isEmpty)
	}

	@Test func removesValuesThatTheAppNoLongerNeeds() {
		let current = MemoryDefaults()
		current.set(Date(), forKey: "lastClaudeEvent")
		current.set(true, forKey: "migratedSettings")
		current.set(false, forKey: SettingsKey.muted)
		current.set(true, forKey: SettingsKey.notifyOnDone)
		current.set(false, forKey: SettingsKey.playsSound)
		current.set(225.0, forKey: "NSStatusItem Preferred Position Item-0")

		AppDelegate.migrateSettings(from: URL(fileURLWithPath: "/nonexistent/local.claude-code-notifier.plist"), to: current)

		#expect(current.dictionaryRepresentation() as NSDictionary == [SettingsKey.playsSound: false, "NSStatusItem Preferred Position Item-0": 225.0] as NSDictionary)
	}
}
