import Foundation
import SQLite3
import Testing
@testable import ClaudeCodeNotifier

private struct SQLiteError: Error {
	let message: String
}

/// Makes a new empty folder in the temporary directory.
private func makeFolder() throws -> URL {
	let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VSCodeArchiveTests-\(UUID().uuidString)")
	try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
	return folder
}

/// Makes a database in the folder, runs the SQL in it, and returns its path.
private func makeDatabase(in folder: URL, sql: String) throws -> String {
	let path = folder.appendingPathComponent("state.vscdb").path
	var connection: OpaquePointer?
	defer { sqlite3_close(connection) }
	guard sqlite3_open(path, &connection) == SQLITE_OK, sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
		throw SQLiteError(message: String(cString: sqlite3_errmsg(connection)))
	}
	return path
}

/// The table of VS Code, with the global state of the Claude Code extension as the value.
private func itemTable(value: String) -> String {
	"""
	CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
	INSERT INTO ItemTable VALUES ('Anthropic.claude-code', \(value));
	"""
}

@Suite struct VSCodeArchiveTests {
	@Test func missingFileGivesNilAndStaysMissing() throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(at: folder) }
		let path = folder.appendingPathComponent("state.vscdb").path
		#expect(VSCodeArchive.sessionIDs(database: path) == nil)
		#expect(!FileManager.default.fileExists(atPath: path))
	}

	@Test func fileThatIsNoDatabaseGivesNil() throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(at: folder) }
		let path = folder.appendingPathComponent("state.vscdb").path
		try Data(String(repeating: "not a database ", count: 100).utf8).write(to: URL(fileURLWithPath: path))
		#expect(VSCodeArchive.sessionIDs(database: path) == nil)
	}

	@Test func databaseWithoutItemTableGivesNil() throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(at: folder) }
		let path = try makeDatabase(in: folder, sql: "CREATE TABLE OtherTable (key TEXT, value BLOB);")
		#expect(VSCodeArchive.sessionIDs(database: path) == nil)
	}

	@Test func lockedDatabaseGivesNil() throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(at: folder) }
		let path = try makeDatabase(in: folder, sql: itemTable(value: #"'{"hiddenSessionIds":["a"]}'"#))
		var writer: OpaquePointer?
		defer { sqlite3_close(writer) }
		try #require(sqlite3_open(path, &writer) == SQLITE_OK)
		try #require(sqlite3_exec(writer, "BEGIN EXCLUSIVE;", nil, nil, nil) == SQLITE_OK)
		#expect(VSCodeArchive.sessionIDs(database: path) == nil)
		sqlite3_exec(writer, "ROLLBACK;", nil, nil, nil)
	}

	@Test func withoutRowNoSessionIsArchived() throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(at: folder) }
		let path = try makeDatabase(in: folder, sql: """
			CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
			INSERT INTO ItemTable VALUES ('other.extension', '{"hiddenSessionIds":["a"]}');
			""")
		#expect(VSCodeArchive.sessionIDs(database: path) == [])
	}

	/// VS Code stores the value as text, but a BLOB works too.
	@Test(arguments: [
		#"'{"hiddenSessionIds":["a","b","a"],"other":1}'"#,
		#"CAST('{"hiddenSessionIds":["a","b","a"],"other":1}' AS BLOB)"#,
	])
	func hiddenSessionsAreArchived(value: String) throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(at: folder) }
		let path = try makeDatabase(in: folder, sql: itemTable(value: value))
		#expect(VSCodeArchive.sessionIDs(database: path) == ["a", "b"])
	}

	@Test(arguments: [
		#"'{"other":["a"]}'"#,
		#"'{"hiddenSessionIds":"a"}'"#,
		#"'["a"]'"#,
		"'not json'",
		"''",
		"X''",
		"NULL",
	])
	func valueWithoutHiddenSessionsArchivesNone(value: String) throws {
		let folder = try makeFolder()
		defer { try? FileManager.default.removeItem(at: folder) }
		let path = try makeDatabase(in: folder, sql: itemTable(value: value))
		#expect(VSCodeArchive.sessionIDs(database: path) == [])
	}
}
