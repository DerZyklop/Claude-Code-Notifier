import Foundation

/// The title of a session as the Claude Code extension shows it, read from the transcript. Claude Code appends the
/// title lines again and again, so the end of the file has the current ones.
enum SessionTitle {
	/// The title kinds by priority, like the extension: an agent name, then a title from a rename, then the title that
	/// Claude made, then a summary. Each entry is the line type and its field.
	private static let kinds = [("agent-name", "agentName"), ("custom-title", "customTitle"), ("ai-title", "aiTitle"), ("summary", "summary")]
	private static let prefixes = Dictionary(uniqueKeysWithValues: kinds.map { ($0.0, Data(#"{"type":"\#($0.0)""#.utf8)) })

	static func read(transcript path: String) -> String? {
		guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
		defer { try? handle.close() }

		if let end = try? handle.seekToEnd() {
			try? handle.seek(toOffset: end > 524_288 ? end - 524_288 : 0)
			if let data = try? handle.readToEnd() {
				// A title line starts with its type, so only these few lines need parsing.
				var latest: [String: String] = [:]
				for line in data.split(separator: UInt8(ascii: "\n")) {
					guard let (type, field) = kinds.first(where: { line.starts(with: prefixes[$0.0]!) }),
						let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
						let value = json[field] as? String, !value.isEmpty else { continue }
					latest[type] = value
				}
				if let title = kinds.lazy.compactMap({ latest[$0.0] }).first { return title }
			}
		}
		return firstPrompt(handle)
	}

	/// The first line of the first prompt, like the extension shows a new session before Claude names it.
	private static func firstPrompt(_ handle: FileHandle) -> String? {
		try? handle.seek(toOffset: 0)
		guard let data = try? handle.read(upToCount: 262_144) else { return nil }
		for line in data.split(separator: UInt8(ascii: "\n")) {
			guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any], json["type"] as? String == "user",
				json["isMeta"] as? Bool != true, let message = json["message"] as? [String: Any] else { continue }
			let text: String? = if let content = message["content"] as? String {
				content
			} else {
				(message["content"] as? [[String: Any]])?.first { $0["type"] as? String == "text" }?["text"] as? String
			}
			// Commands and tool results also come as user messages, wrapped in tags.
			guard let text, !text.hasPrefix("<"), let first = text.split(whereSeparator: \.isNewline).first else { continue }
			let line = first.trimmingCharacters(in: .whitespaces)
			if !line.isEmpty { return line.count > 80 ? line.prefix(80) + "…" : line }
		}
		return nil
	}
}
