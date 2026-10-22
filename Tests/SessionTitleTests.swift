import Foundation
import Testing
@testable import ClaudeCodeNotifier

/// Writes the data to a transcript file in a new folder, runs the body with the path of the file, and deletes the folder.
private func withTranscript<T>(_ data: Data, _ body: (String) throws -> T) throws -> T {
	let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeCodeNotifierTests-\(UUID().uuidString)")
	try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: folder) }
	let file = folder.appendingPathComponent("transcript.jsonl")
	try data.write(to: file)
	return try body(file.path)
}

/// The lines as a transcript file, each line ends with a line break.
private func jsonl(_ lines: [String]) -> Data {
	Data((lines.joined(separator: "\n") + "\n").utf8)
}

private func title(_ lines: [String]) throws -> String? {
	try withTranscript(jsonl(lines)) { SessionTitle.read(transcript: $0) }
}

private func start(_ lines: [String]) throws -> Date? {
	try withTranscript(jsonl(lines)) { SessionTitle.start(transcript: $0) }
}

private func firstPrompt(_ lines: [String]) throws -> String? {
	try withTranscript(jsonl(lines)) { path in
		let handle = try #require(FileHandle(forReadingAtPath: path))
		defer { try? handle.close() }
		return SessionTitle.firstPrompt(handle)
	}
}

private func userLine(_ content: String, isMeta: Bool = false) -> String {
	let json = try! JSONSerialization.data(withJSONObject: ["type": "user", "isMeta": isMeta, "message": ["role": "user", "content": content]])
	return String(decoding: json, as: UTF8.self)
}

/// A line that is no title, no prompt and has no time. It has `size` bytes together with its line break.
private func filler(_ size: Int) -> String {
	let head = #"{"type":"assistant","text":""#, tail = #""}"#
	return head + String(repeating: "x", count: size - head.utf8.count - tail.utf8.count - 1) + tail
}

private let a79 = String(repeating: "a", count: 79)

/// One Character of five Unicode scalars.
private let family = "👨‍👩‍👧"

/// The time 2026-10-21T08:30:15.250Z.
private let startDate = Date(timeIntervalSince1970: 1_792_571_415.25)

@Suite struct SessionTitleReadTests {
	@Test func missingFileHasNoTitle() {
		#expect(SessionTitle.read(transcript: "/nonexistent/transcript.jsonl") == nil)
	}

	@Test func emptyFileHasNoTitle() throws {
		#expect(try withTranscript(Data()) { SessionTitle.read(transcript: $0) } == nil)
	}

	@Test func agentNameWinsOverAllOtherKinds() throws {
		let lines = [
			#"{"type":"agent-name","agentName":"Agent"}"#,
			#"{"type":"custom-title","customTitle":"Custom"}"#,
			#"{"type":"ai-title","aiTitle":"AI"}"#,
			#"{"type":"summary","summary":"Summary"}"#,
		]
		#expect(try title(lines) == "Agent")
	}

	@Test func customTitleWinsOverAITitleAndSummary() throws {
		let lines = [
			#"{"type":"summary","summary":"Summary"}"#,
			#"{"type":"custom-title","customTitle":"Custom"}"#,
			#"{"type":"ai-title","aiTitle":"AI"}"#,
		]
		#expect(try title(lines) == "Custom")
	}

	@Test func aiTitleWinsOverSummary() throws {
		let lines = [
			#"{"type":"ai-title","aiTitle":"AI"}"#,
			#"{"type":"summary","summary":"Summary"}"#,
		]
		#expect(try title(lines) == "AI")
	}

	@Test func summaryIsATitle() throws {
		#expect(try title([userLine("Prompt"), #"{"type":"summary","summary":"Summary"}"#]) == "Summary")
	}

	@Test func lastLineOfAKindWins() throws {
		let lines = [
			#"{"type":"ai-title","aiTitle":"Old"}"#,
			userLine("Hello"),
			#"{"type":"ai-title","aiTitle":"New"}"#,
		]
		#expect(try title(lines) == "New")
	}

	@Test func emptyTitleIsIgnored() throws {
		let lines = [
			#"{"type":"ai-title","aiTitle":"AI"}"#,
			#"{"type":"custom-title","customTitle":""}"#,
		]
		#expect(try title(lines) == "AI")
	}

	@Test func titleThatIsNoStringIsIgnored() throws {
		let lines = [
			#"{"type":"ai-title","aiTitle":"AI"}"#,
			#"{"type":"custom-title","customTitle":42}"#,
			#"{"type":"agent-name","agentName":"#,
		]
		#expect(try title(lines) == "AI")
	}

	@Test func titleKindInAnotherFieldIsNoTitle() throws {
		// Only lines that start with the type are title lines.
		let lines = [
			#"{"uuid":"1","type":"ai-title","aiTitle":"AI"}"#,
			userLine("The prompt"),
		]
		#expect(try title(lines) == "The prompt")
	}

	@Test func withoutTitleTheFirstPromptIsTheTitle() throws {
		let lines = [
			#"{"type":"system","content":"Start"}"#,
			userLine("First prompt"),
			userLine("Second prompt"),
		]
		#expect(try title(lines) == "First prompt")
	}

	@Test(arguments: [(524_288, "Title"), (524_289, "First prompt")])
	func onlyTheLast512KiBHaveTitles(bytesFromTitleToEnd: Int, expected: String) throws {
		let titleLine = #"{"type":"ai-title","aiTitle":"Title"}"#
		let lines = [userLine("First prompt"), titleLine, filler(bytesFromTitleToEnd - titleLine.utf8.count - 1)]
		#expect(try title(lines) == expected)
	}

	@Test func titleBefore512KiBDoesNotWinOverANewerKind() throws {
		let lines = [
			userLine("First prompt"),
			#"{"type":"custom-title","customTitle":"Old rename"}"#,
			filler(600_000),
			#"{"type":"ai-title","aiTitle":"AI"}"#,
		]
		#expect(try title(lines) == "AI")
	}

	@Test func promptWithTextBlocks() throws {
		let line = #"{"type":"user","message":{"role":"user","content":[{"type":"image","source":{}},{"type":"text","text":"Look at this"}]}}"#
		#expect(try title([line]) == "Look at this")
	}

	@Test func metaPromptIsSkipped() throws {
		#expect(try title([userLine("Caveat", isMeta: true), userLine("Real prompt")]) == "Real prompt")
	}

	@Test func taggedTextIsSkipped() throws {
		#expect(try title([userLine("<tool_result>output</tool_result>"), userLine("Real prompt")]) == "Real prompt")
	}

	@Test func emptyPromptIsSkipped() throws {
		#expect(try title([userLine("   \n"), userLine("Real prompt")]) == "Real prompt")
	}

	@Test func onlyTheFirstLineOfAPrompt() throws {
		#expect(try title([userLine("  First line  \nSecond line")]) == "First line")
	}

	@Test func slashCommandWithArguments() throws {
		let text = "<command-message>review</command-message>\n<command-name>/review</command-name>\n<command-args>42 --fast</command-args>"
		#expect(try title([userLine(text)]) == "/review 42 --fast")
	}

	@Test func slashCommandWithoutArguments() throws {
		let text = "<command-name>/simplify</command-name>\n<command-args></command-args>"
		#expect(try title([userLine(text)]) == "/simplify")
	}

	@Test func slashCommandShowsOnlyTheFirstLineOfItsArguments() throws {
		let text = "<command-name>/fix</command-name><command-args>first\nsecond</command-args>"
		#expect(try title([userLine(text)]) == "/fix first")
	}

	@Test func longPromptIsCutAfter80Characters() throws {
		#expect(try title([userLine(String(repeating: "a", count: 81))]) == String(repeating: "a", count: 80) + "…")
	}

	@Test func promptOf80CharactersStaysWhole() throws {
		let prompt = String(repeating: "a", count: 80)
		#expect(try title([userLine(prompt)]) == prompt)
	}
}

@Suite struct SessionTitleFirstPromptTests {
	@Test func emptyFileHasNoPrompt() throws {
		let prompt = try withTranscript(Data()) { path in
			let handle = try #require(FileHandle(forReadingAtPath: path))
			defer { try? handle.close() }
			return SessionTitle.firstPrompt(handle)
		}
		#expect(prompt == nil)
	}

	@Test func readsFromTheStartOfTheFile() throws {
		let prompt = try withTranscript(jsonl([userLine("Hello")])) { path in
			let handle = try #require(FileHandle(forReadingAtPath: path))
			defer { try? handle.close() }
			try handle.seekToEnd()
			return SessionTitle.firstPrompt(handle)
		}
		#expect(prompt == "Hello")
	}

	@Test func stringContent() throws {
		#expect(try firstPrompt([userLine("Hello")]) == "Hello")
	}

	@Test func firstTextBlockOfTheContent() throws {
		let line = #"{"type":"user","message":{"content":[{"type":"image","source":{}},{"type":"text","text":"First"},{"type":"text","text":"Second"}]}}"#
		#expect(try firstPrompt([line]) == "First")
	}

	@Test func contentWithoutTextIsSkipped() throws {
		let lines = [
			#"{"type":"user","message":{"content":[{"type":"image","source":{}}]}}"#,
			#"{"type":"user","message":{"content":42}}"#,
			userLine("Prompt"),
		]
		#expect(try firstPrompt(lines) == "Prompt")
	}

	@Test func metaLineIsSkipped() throws {
		#expect(try firstPrompt([userLine("Caveat", isMeta: true), userLine("Prompt")]) == "Prompt")
	}

	@Test func otherLinesAreSkipped() throws {
		let lines = [
			#"{"type":"assistant","message":{"role":"assistant","content":"Answer"}}"#,
			#"{"type":"system","message":{"content":"System"}}"#,
			userLine("Prompt"),
		]
		#expect(try firstPrompt(lines) == "Prompt")
	}

	@Test func userTypeInAnotherFieldIsNoUserLine() throws {
		let lines = [
			#"{"type":"progress","data":{"type":"user"},"message":{"role":"user","content":"Not a prompt"}}"#,
			userLine("Prompt"),
		]
		#expect(try firstPrompt(lines) == "Prompt")
	}

	@Test func brokenLinesAreSkipped() throws {
		let lines = [
			#"{"type":"user","message":"#,
			#"{"type":"user","content":"No message"}"#,
			userLine("Prompt"),
		]
		#expect(try firstPrompt(lines) == "Prompt")
	}

	@Test func noPromptInTheFile() throws {
		#expect(try firstPrompt([userLine("Caveat", isMeta: true), userLine("<tool_result>output</tool_result>")]) == nil)
	}

	@Test(arguments: [(4_194_304, "Prompt"), (4_194_305, nil)] as [(Int, String?)])
	func onlyTheFirst4MiBAreRead(bytesToEndOfPromptLine: Int, expected: String?) throws {
		let line = userLine("Prompt")
		#expect(try firstPrompt([filler(bytesToEndOfPromptLine - line.utf8.count), line]) == expected)
	}

	@Test(arguments: [
		(a79 + "a", a79 + "a"),
		(a79 + "aa", a79 + "a…"),
		(a79 + family, a79 + family),
		(a79 + family + "b", a79 + family + "…"),
		(String(repeating: family, count: 81), String(repeating: family, count: 80) + "…"),
	] as [(String, String)])
	func cutAfter80Characters(prompt: String, expected: String) throws {
		#expect(try firstPrompt([userLine(prompt)]) == expected)
	}
}

@Suite struct SessionTitlePromptLineTests {
	@Test(arguments: [
		("<command-name>/review</command-name><command-args>42 --fast</command-args>", "/review 42 --fast"),
		("<command-name>/clear</command-name>", "/clear"),
		("<command-name>/clear</command-name><command-args></command-args>", "/clear"),
		("<command-name>/fix</command-name><command-args>first\nsecond</command-args>", "/fix first"),
		("<command-name>\n  /review  \n</command-name>", "/review"),
		("  First line  \nSecond line", "First line"),
		("\n\nFirst line", "First line"),
		("First line\r\nSecond line", "First line"),
	])
	func firstLineOfThePrompt(text: String, expected: String) {
		#expect(SessionTitle.promptLine(text) == expected)
	}

	@Test(arguments: ["", "   ", " \t ", "\n\n", "<tool_result>output</tool_result>", "<b>Bold</b> text", "<command-name> </command-name>"])
	func noPromptLine(text: String) {
		#expect(SessionTitle.promptLine(text) == nil)
	}
}

@Suite struct SessionTitleTagContentTests {
	@Test(arguments: [
		("<name>/review</name>", "/review"),
		("<name></name>", ""),
		("<name>one</name><name>two</name>", "one"),
		("before<name>one\ntwo</name>after", "one\ntwo"),
		("</name>early<name>late</name>", "late"),
	])
	func contentBetweenTheTags(text: String, expected: String) {
		#expect(SessionTitle.tagContent("name", in: text) == expected)
	}

	@Test(arguments: ["no tags", "/review</name>", "<name>/review", "</name>/review<name>", "<other>/review</other>", "<name/>"])
	func noContentWithoutBothTags(text: String) {
		#expect(SessionTitle.tagContent("name", in: text) == nil)
	}
}

@Suite struct SessionTitleStartTests {
	@Test func missingFileHasNoStart() {
		#expect(SessionTitle.start(transcript: "/nonexistent/transcript.jsonl") == nil)
	}

	@Test func emptyFileHasNoStart() throws {
		#expect(try withTranscript(Data()) { SessionTitle.start(transcript: $0) } == nil)
	}

	@Test func firstTimestampIsTheStart() throws {
		let lines = [
			#"{"type":"summary","summary":"No time"}"#,
			#"{"type":"user","timestamp":"2026-10-21T08:30:15.250Z"}"#,
			#"{"type":"user","timestamp":"2026-10-21T09:00:00.000Z"}"#,
		]
		#expect(try start(lines) == startDate)
	}

	@Test func unreadableTimestampIsSkipped() throws {
		let lines = [
			#"{"type":"user","timestamp":"yesterday"}"#,
			#"{"type":"user","timestamp":42}"#,
			#"{"type":"user","timestamp":"#,
			#"{"type":"user","timestamp":"2026-10-21T08:30:15.250Z"}"#,
		]
		#expect(try start(lines) == startDate)
	}

	@Test func timestampWithoutFractionalSecondsIsIgnored() throws {
		#expect(try start([#"{"type":"user","timestamp":"2026-10-21T08:30:15Z"}"#]) == nil)
	}

	@Test func fileWithoutTimestampHasNoStart() throws {
		#expect(try start([userLine("Hello")]) == nil)
	}

	@Test(arguments: [(65_536, startDate), (65_537, nil)])
	func onlyTheFirst64KiBAreRead(bytesToEndOfTimestampLine: Int, expected: Date?) throws {
		let line = #"{"type":"user","timestamp":"2026-10-21T08:30:15.250Z"}"#
		#expect(try start([filler(bytesToEndOfTimestampLine - line.utf8.count), line]) == expected)
	}
}

/// An event can name any path as its transcript. Only a regular file opens, so that a read neither blocks nor runs
/// without end.
@Suite(.timeLimit(.minutes(1))) struct RegularFileTests {
	@Test func regularFileOpens() throws {
		try withTranscript(Data("line\n".utf8)) { path in
			let handle = try #require(FileHandle.regularFile(atPath: path))
			defer { try? handle.close() }
			#expect(try handle.readToEnd() == Data("line\n".utf8))
		}
	}

	@Test func linkToARegularFileOpens() throws {
		try withTranscript(Data("line\n".utf8)) { path in
			let link = path + ".link"
			try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
			#expect(FileHandle.regularFile(atPath: link) != nil)
		}
	}

	@Test(arguments: ["/dev/zero", "/dev/urandom", "/dev/null", "/private/tmp", "/nonexistent/transcript.jsonl"])
	func otherPathDoesNotOpen(path: String) {
		#expect(FileHandle.regularFile(atPath: path) == nil)
	}

	@Test func fifoDoesNotOpen() throws {
		try withFIFO { #expect(FileHandle.regularFile(atPath: $0) == nil) }
	}

	@Test(arguments: ["/dev/zero", "/dev/urandom"])
	func deviceHasNoTitleAndNoStart(path: String) {
		#expect(SessionTitle.read(transcript: path) == nil)
		#expect(SessionTitle.start(transcript: path) == nil)
	}

	@Test func fifoHasNoTitleAndNoStart() throws {
		try withFIFO { path in
			#expect(SessionTitle.read(transcript: path) == nil)
			#expect(SessionTitle.start(transcript: path) == nil)
		}
	}
}
