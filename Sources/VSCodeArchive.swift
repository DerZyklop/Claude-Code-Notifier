import Foundation
import SQLite3

/// The Claude Code sessions that the user archived in the VS Code extension. The extension keeps their IDs in its
/// global state, under `hiddenSessionIds`. VS Code stores the global state of all extensions in a SQLite database.
enum VSCodeArchive {
	private static let database = FileManager.default.homeDirectoryForCurrentUser
		.appendingPathComponent("Library/Application Support/Code/User/globalStorage/state.vscdb").path

	/// The IDs of the archived sessions, or `nil` if the database cannot be read right now, e.g. while VS Code writes it.
	static func sessionIDs() -> Set<String>? {
		var connection: OpaquePointer?
		defer { sqlite3_close(connection) }
		guard sqlite3_open_v2(database, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
		sqlite3_busy_timeout(connection, 200)

		var statement: OpaquePointer?
		defer { sqlite3_finalize(statement) }
		guard sqlite3_prepare_v2(connection, "SELECT value FROM ItemTable WHERE key = 'Anthropic.claude-code'", -1, &statement, nil) == SQLITE_OK else { return nil }
		switch sqlite3_step(statement) {
		case SQLITE_DONE:
			return []
		case SQLITE_ROW:
			guard let bytes = sqlite3_column_blob(statement, 0) else { return [] }
			let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
			let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
			return Set(state?["hiddenSessionIds"] as? [String] ?? [])
		default:
			return nil
		}
	}
}
