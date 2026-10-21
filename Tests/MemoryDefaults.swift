import Foundation

/// Defaults that keep their values in memory, for one test. A real suite that gets a write leaves an empty plist file
/// in ~/Library/Preferences, also after `removePersistentDomain(forName:)`.
final class MemoryDefaults: UserDefaults {
	private var values: [String: Any] = [:]

	convenience init() {
		self.init(suiteName: "ClaudeCodeNotifierTests-\(UUID().uuidString)")!
	}

	override func object(forKey defaultName: String) -> Any? { values[defaultName] }
	override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
	override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
	override func dictionaryRepresentation() -> [String: Any] { values }
}
