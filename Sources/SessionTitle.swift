import Foundation

/// The title of a session as the Claude Code extension shows it, read from the transcript. Claude Code appends the
/// title lines again and again, so the end of the file has the current ones.
enum SessionTitle {
	/// The title kinds by priority, like the extension: an agent name, then a title from a rename, then the title that
	/// Claude made, then a summary. Each entry is the start of a title line of the kind, and the field of the title.
	private static let kinds = [("agent-name", "agentName"), ("custom-title", "customTitle"), ("ai-title", "aiTitle"), ("summary", "summary")]
		.map { (prefix: Data(#"{"type":"\#($0.0)""#.utf8), field: $0.1) }

	static func read(transcript path: String) -> String? {
		guard let handle = FileHandle.regularFile(atPath: path) else { return nil }
		defer { try? handle.close() }
		return latestTitle(handle) ?? firstPrompt(handle)
	}

	/// The title of the first kind that has a line in the last 512 KiB of the transcript.
	private static func latestTitle(_ handle: FileHandle) -> String? {
		guard let end = try? handle.seekToEnd() else { return nil }
		try? handle.seek(toOffset: end > 524_288 ? end - 524_288 : 0)
		guard let data = try? handle.read(upToCount: 524_288) else { return nil }
		// A title line starts with its type, so only these few lines need parsing.
		var latest: [String: String] = [:]
		for line in data.split(separator: UInt8(ascii: "\n")) {
			guard let kind = kinds.first(where: { line.starts(with: $0.prefix) }),
				let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
				let value = json[kind.field] as? String, !value.isEmpty else { continue }
			latest[kind.field] = value
		}
		return kinds.lazy.compactMap { latest[$0.field] }.first
	}

	/// When the session started: the time of the first entry in the transcript. `nil` while there is none.
	static func start(transcript path: String) -> Date? {
		guard let handle = FileHandle.regularFile(atPath: path) else { return nil }
		defer { try? handle.close() }
		guard let data = try? handle.read(upToCount: 65_536) else { return nil }
		for line in data.split(separator: UInt8(ascii: "\n")) {
			guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
				let timestamp = json["timestamp"] as? String,
				let date = timestampFormat.date(from: timestamp) else { continue }
			return date
		}
		return nil
	}

	private static let timestampFormat: ISO8601DateFormatter = {
		let format = ISO8601DateFormatter()
		format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return format
	}()

	/// The first line of the first prompt, like the extension shows a new session before Claude names it.
	static func firstPrompt(_ handle: FileHandle) -> String? {
		try? handle.seek(toOffset: 0)
		// The first lines can be large, e.g. attachments. Only user lines need parsing.
		guard let data = try? handle.read(upToCount: 4_194_304) else { return nil }
		let userLine = Data(#""type":"user""#.utf8)
		for line in data.split(separator: UInt8(ascii: "\n")) where line.range(of: userLine) != nil {
			guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any], json["type"] as? String == "user",
				json["isMeta"] as? Bool != true, let message = json["message"] as? [String: Any] else { continue }
			let text: String? = if let content = message["content"] as? String {
				content
			} else {
				(message["content"] as? [[String: Any]])?.first { $0["type"] as? String == "text" }?["text"] as? String
			}
			guard let text, let prompt = promptLine(text) else { continue }
			return prompt.count > 80 ? prompt.prefix(80) + "…" : prompt
		}
		return nil
	}

	/// The first line of a prompt. A slash command comes wrapped in tags and becomes »/name args«, like the extension
	/// shows it. Other tagged text, e.g. a tool result, is no prompt.
	static func promptLine(_ text: String) -> String? {
		if let name = tagContent("command-name", in: text) {
			let arguments = tagContent("command-args", in: text) ?? ""
			let command = "\(name) \(arguments)".trimmingCharacters(in: .whitespacesAndNewlines)
			return command.split(whereSeparator: \.isNewline).first.map(String.init)
		}
		guard !text.hasPrefix("<"), let first = text.split(whereSeparator: \.isNewline).first else { return nil }
		let line = first.trimmingCharacters(in: .whitespaces)
		return line.isEmpty ? nil : line
	}

	static func tagContent(_ tag: String, in text: String) -> String? {
		guard let open = text.range(of: "<\(tag)>"), let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex) else { return nil }
		return String(text[open.upperBound..<close.lowerBound])
	}

}

extension FileHandle {
	/// A handle to read a regular file, or `nil`. A transcript path can come from any process that reaches the event
	/// server: a FIFO would block the open, and a device such as /dev/zero would never end.
	static func regularFile(atPath path: String) -> FileHandle? {
		let descriptor = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
		guard descriptor >= 0 else { return nil }
		var info = stat()
		guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
			Darwin.close(descriptor)
			return nil
		}
		return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
	}
}
