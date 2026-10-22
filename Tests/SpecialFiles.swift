import Foundation

/// Runs the body with the path of a new FIFO that nobody writes to, and deletes it at the end.
func withFIFO<T>(_ body: (String) throws -> T) throws -> T {
	let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeCodeNotifierTests-\(UUID().uuidString)")
	try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: folder) }
	let path = folder.appendingPathComponent("fifo").path
	guard mkfifo(path, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
	return try body(path)
}
