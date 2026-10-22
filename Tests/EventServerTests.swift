import Foundation
import Testing
@testable import ClaudeCodeNotifier

private let noContent = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
private let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"

private func parse(_ text: String) -> (head: String, body: String)? {
	EventServer.parse(Data(text.utf8)).map { ($0.head, String(decoding: $0.body, as: UTF8.self)) }
}

/// A request that the server accepts.
private func event(_ body: String) -> String {
	"POST /event HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Claude-Hook: 1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
}

private struct Timeout: Error {}

/// Polls the condition every 10 ms, for at most 5 seconds.
private func waitFor(_ condition: () -> Bool) async throws {
	let deadline = Date().addingTimeInterval(5)
	while !condition() {
		guard Date() < deadline else { throw Timeout() }
		try await Task.sleep(nanoseconds: 10_000_000)
	}
}

private func loopback(port: UInt16) -> sockaddr_in {
	var address = sockaddr_in()
	address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
	address.sin_family = sa_family_t(AF_INET)
	address.sin_port = port.bigEndian
	address.sin_addr.s_addr = inet_addr("127.0.0.1")
	return address
}

/// A port on 127.0.0.1 that no socket uses now.
private func freePort() throws -> UInt16 {
	let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
	try #require(socket >= 0)
	defer { close(socket) }
	var address = loopback(port: 0)
	var length = socklen_t(MemoryLayout<sockaddr_in>.size)
	let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, length) } }
	try #require(bound == 0)
	let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) } }
	try #require(named == 0)
	return UInt16(bigEndian: address.sin_port)
}

/// An event server on its own port, with all that it reports.
private final class RunningServer: @unchecked Sendable {
	let port: UInt16
	private let server: EventServer
	private let lock = NSLock()
	private var reportedStates: [String?] = []
	private var reportedEvents: [Data] = []

	init(port: UInt16) {
		self.port = port
		server = EventServer(port: port)
		server.start(
			onEvent: { [weak self] body in self?.locked { self?.reportedEvents.append(body) } },
			onStateChange: { [weak self] state in self?.locked { self?.reportedStates.append(state) } }
		)
	}

	/// Starts a server on a free port and waits until it listens. A parallel test can take the same port between
	/// ``freePort()`` and the start, so the server then tries another port.
	static func ready() async throws -> RunningServer {
		for _ in 1..<3 {
			let server = RunningServer(port: try freePort())
			try await waitFor { !server.states.isEmpty }
			if server.states == [nil] { return server }
		}
		let server = RunningServer(port: try freePort())
		try await waitFor { !server.states.isEmpty }
		try #require(server.states == [nil])
		return server
	}

	var states: [String?] { locked { reportedStates } }
	var events: [String] { locked { reportedEvents.map { String(decoding: $0, as: UTF8.self) } } }

	private func locked<T>(_ body: () -> T) -> T {
		lock.lock()
		defer { lock.unlock() }
		return body()
	}

	/// A new connection to the server. The caller closes it. A receive waits at most 5 seconds.
	func connect() throws -> Int32 {
		let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
		try #require(socket >= 0)
		var timeout = timeval(tv_sec: 5, tv_usec: 0)
		setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
		var noSignal: Int32 = 1
		setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
		// Each chunk goes out at once, so that the server gets it alone.
		var noDelay: Int32 = 1
		setsockopt(socket, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
		var address = loopback(port: port)
		let connected = withUnsafePointer(to: &address) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
		}
		guard connected == 0 else {
			close(socket)
			throw Timeout()
		}
		return socket
	}

	/// Sends the chunks with a short pause between them and returns the answer. Throws when the server does not close
	/// the connection within 5 seconds.
	/// - Parameter closing: Closes the sending side after the last chunk.
	func send(_ chunks: String..., closing: Bool = false) throws -> String {
		let socket = try connect()
		defer { close(socket) }
		for (index, chunk) in chunks.enumerated() {
			if index > 0 { usleep(50_000) }
			let bytes = Array(chunk.utf8)
			try #require(Darwin.send(socket, bytes, bytes.count, 0) == bytes.count)
		}
		if closing { shutdown(socket, SHUT_WR) }

		var answer = Data()
		var buffer = [UInt8](repeating: 0, count: 4096)
		while true {
			let count = recv(socket, &buffer, buffer.count, 0)
			if count > 0 {
				answer.append(contentsOf: buffer[..<count])
				continue
			}
			// 0 is the end of the stream and ECONNRESET a reset: the server closed the connection.
			guard count == 0 || errno == ECONNRESET else { throw Timeout() }
			break
		}
		return String(decoding: answer, as: UTF8.self)
	}

	/// Sends one more event, waits for it, and returns the events before it.
	/// The server handles one connection after the other, so these include the events of all earlier requests.
	func eventsAfterOneMore() async throws -> [String] {
		#expect(try send(event("next")) == noContent)
		try await waitFor { events.last == "next" }
		return Array(events.dropLast())
	}
}

@Suite struct EventServerParseTests {
	@Test func emptyDataIsNotComplete() {
		#expect(EventServer.parse(Data()) == nil)
	}

	@Test func requestWithoutEmptyLineIsNotComplete() {
		#expect(parse("POST /event HTTP/1.1\r\nContent-Length: 0\r\n") == nil)
	}

	@Test func bareLineFeedsAreNoEmptyLine() {
		#expect(parse("POST /event HTTP/1.1\n\nhello") == nil)
	}

	@Test func bodyShorterThanContentLengthIsNotComplete() {
		#expect(parse("POST /event HTTP/1.1\r\nContent-Length: 5\r\n\r\nhell") == nil)
	}

	@Test func headAndExactBody() throws {
		let request = try #require(parse("POST /event HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello"))
		#expect(request.head == "POST /event HTTP/1.1\r\nContent-Length: 5")
		#expect(request.body == "hello")
	}

	@Test func bytesAfterTheBodyAreCut() throws {
		let request = try #require(parse("POST /event HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello world"))
		#expect(request.body == "hello")
	}

	@Test func onlyTheFirstEmptyLineEndsTheHead() throws {
		let request = try #require(parse("POST /event HTTP/1.1\r\nContent-Length: 6\r\n\r\na\r\n\r\nb"))
		#expect(request.head == "POST /event HTTP/1.1\r\nContent-Length: 6")
		#expect(request.body == "a\r\n\r\nb")
	}

	@Test(arguments: ["Content-Length: 5", "content-length: 5", "CONTENT-LENGTH: 5", "Content-Length:5", "Content-Length: \t5 "])
	func contentLengthHeader(line: String) throws {
		let request = try #require(parse("POST /event HTTP/1.1\r\nHost: 127.0.0.1\r\n\(line)\r\n\r\nhello world"))
		#expect(request.body == "hello")
	}

	@Test func withoutContentLengthTheBodyIsEmpty() throws {
		let request = try #require(parse("POST /event HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\nhello"))
		#expect(request.head == "POST /event HTTP/1.1\r\nHost: 127.0.0.1")
		#expect(request.body == "")
	}

	@Test(arguments: ["five", "5x", "", "-", "99999999999999999999", "-1", "-99999999999999999999"])
	func invalidContentLengthCountsAsZero(value: String) throws {
		let request = try #require(parse("POST /event HTTP/1.1\r\nContent-Length: \(value)\r\n\r\nhello"))
		#expect(request.body == "")
	}

	@Test func firstContentLengthCounts() throws {
		let request = try #require(parse("POST /event HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 11\r\n\r\nhello world"))
		#expect(request.body == "hello")
	}

	@Test func otherHeaderThatEndsInContentLengthDoesNotCount() throws {
		let request = try #require(parse("POST /event HTTP/1.1\r\nX-Content-Length: 11\r\nContent-Length: 5\r\n\r\nhello world"))
		#expect(request.body == "hello")
	}

	/// "ä" has two bytes in UTF-8.
	@Test func contentLengthCountsBytes() throws {
		#expect(parse("POST /event HTTP/1.1\r\nContent-Length: 3\r\n\r\nä") == nil)
		let request = try #require(parse("POST /event HTTP/1.1\r\nContent-Length: 2\r\n\r\näb"))
		#expect(request.body == "ä")
	}

	@Test func bodyKeepsItsBytes() throws {
		let bytes: [UInt8] = [0xFF, 0x00, 0x80]
		let request = try #require(EventServer.parse(Data("POST /event HTTP/1.1\r\nContent-Length: 3\r\n\r\n".utf8) + bytes))
		#expect(request.body == Data(bytes))
	}
}

@Suite struct EventServerStartTests {
	@Test func reportsReadyOnce() async throws {
		let server = RunningServer(port: try freePort())
		try await waitFor { !server.states.isEmpty }
		#expect(server.states == [nil])
		#expect(try await server.eventsAfterOneMore() == [])
		#expect(server.states == [nil])
	}

	@Test func eventGets204AndPassesItsBody() async throws {
		let server = try await RunningServer.ready()
		#expect(try server.send(event(#"{"hook_event_name":"Stop"}"#)) == noContent)
		try await waitFor { !server.events.isEmpty }
		#expect(server.events == [#"{"hook_event_name":"Stop"}"#])
	}

	@Test func hookHeaderNameInAnyCase() async throws {
		let server = try await RunningServer.ready()
		#expect(try server.send("POST /event HTTP/1.1\r\nx-claude-hook: 1\r\nContent-Length: 2\r\n\r\n{}") == noContent)
		#expect(try await server.eventsAfterOneMore() == ["{}"])
	}

	@Test(arguments: [
		"POST /event HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}",
		"POST /other HTTP/1.1\r\nX-Claude-Hook: 1\r\nContent-Length: 2\r\n\r\n{}",
		"POST /events HTTP/1.1\r\nX-Claude-Hook: 1\r\nContent-Length: 2\r\n\r\n{}",
		"GET /event HTTP/1.1\r\nX-Claude-Hook: 1\r\n\r\n",
		"POST /event HTTP/1.1\r\nUser-Agent: X-Claude-Hook: 1\r\nContent-Length: 2\r\n\r\n{}",
		"post /event HTTP/1.1\r\nX-Claude-Hook: 1\r\nContent-Length: 2\r\n\r\n{}",
		"POST /event HTTP/1.1\r\nContent-Length: 18\r\n\r\n\r\nX-Claude-Hook: 1",
		// A web page after DNS rebinding: its browser sends the name of the page and an Origin.
		"POST /event HTTP/1.1\r\nHost: evil.example:47823\r\nOrigin: http://evil.example:47823\r\nX-Claude-Hook: 1\r\nContent-Length: 2\r\n\r\n{}",
		"POST /event HTTP/1.1\r\nHost: evil.example:47823\r\nX-Claude-Hook: 1\r\nContent-Length: 2\r\n\r\n{}",
		"POST /event HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: null\r\nX-Claude-Hook: 1\r\nContent-Length: 2\r\n\r\n{}",
	])
	func otherRequestGets404AndNoEvent(request: String) async throws {
		let server = try await RunningServer.ready()
		#expect(try server.send(request) == notFound)
		#expect(try await server.eventsAfterOneMore() == [])
	}

	@Test func requestInChunks() async throws {
		let server = try await RunningServer.ready()
		let answer = try server.send(
			"POST /event HTTP/1.1\r\nX-Claude",
			"-Hook: 1\r\nContent-Length: 11\r\n",
			"\r\nhello",
			" world"
		)
		#expect(answer == noContent)
		#expect(try await server.eventsAfterOneMore() == ["hello world"])
	}

	@Test func secondRequestOnTheSameConnectionIsIgnored() async throws {
		let server = try await RunningServer.ready()
		#expect(try server.send(event("one") + event("two")) == noContent)
		#expect(try await server.eventsAfterOneMore() == ["one"])
	}

	@Test func requestThatEndsTooEarlyGetsNoAnswer() async throws {
		let server = try await RunningServer.ready()
		#expect(try server.send("POST /event HTTP/1.1\r\nX-Claude-Hook: 1\r\nContent-Length: 5\r\n\r\nhel", closing: true) == "")
		#expect(try await server.eventsAfterOneMore() == [])
	}

	@Test func incompleteRequestOfMoreThanOneMegabyteIsDropped() async throws {
		let server = try await RunningServer.ready()
		let head = "POST /event HTTP/1.1\r\nX-Claude-Hook: 1\r\nContent-Length: 2000000\r\n\r\n"
		// The last byte goes over the limit, so the server reads all bytes before it closes.
		#expect(try server.send(head + String(repeating: "a", count: 1_000_001 - head.utf8.count)) == "")
		#expect(try await server.eventsAfterOneMore() == [])
	}

	@Test func requestOfOneMegabyteCanStillGrow() async throws {
		let server = try await RunningServer.ready()
		let request = "POST /event HTTP/1.1\r\nX-Claude-Hook: 1\r\nContent-Length: 999935\r\n\r\n" + String(repeating: "a", count: 999_935)
		try #require(request.utf8.count == 1_000_001)
		#expect(try server.send(String(request.dropLast()), String(request.suffix(1))) == noContent)
		#expect(try await server.eventsAfterOneMore().map(\.utf8.count) == [999_935])
	}

	@Test func negativeContentLengthGets404AndTheServerRuns() async throws {
		let server = try await RunningServer.ready()
		#expect(try server.send("GET / HTTP/1.1\r\nContent-Length: -1\r\n\r\n") == notFound)
		#expect(try server.send("POST /event HTTP/1.1\r\nX-Claude-Hook: 1\r\nContent-Length: -1\r\n\r\n{}") == noContent)
		#expect(try await server.eventsAfterOneMore() == [""])
	}

	@Test func idleConnectionClosesAfterTheTimeout() async throws {
		let server = try await RunningServer.ready()
		let start = Date()
		#expect(try server.send() == "")
		let elapsed = Date().timeIntervalSince(start)
		#expect(elapsed > EventServer.connectionTimeout - 0.5 && elapsed < EventServer.connectionTimeout + 1.5)
	}

	@Test func idleConnectionsCannotBlockAHook() async throws {
		let server = try await RunningServer.ready()
		var idle: [Int32] = []
		defer { idle.forEach { close($0) } }
		for _ in 0..<EventServer.maxConnections {
			idle.append(try server.connect())
			// The server takes the connections in this order.
			try await Task.sleep(nanoseconds: 5_000_000)
		}
		#expect(try server.send(event("hook")) == noContent)
		try await waitFor { server.events == ["hook"] }
		// The server closed the oldest connection for the hook. The timeout would close it only seconds later.
		var timeout = timeval(tv_sec: 1, tv_usec: 0)
		setsockopt(idle[0], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
		var byte: UInt8 = 0
		let count = recv(idle[0], &byte, 1, 0)
		#expect(count == 0 || (count < 0 && errno == ECONNRESET))
	}

	@Test func secondServerOnAUsedPortReportsAnError() async throws {
		let first = try await RunningServer.ready()
		let second = RunningServer(port: first.port)
		try await waitFor { !second.states.isEmpty }
		#expect(second.states.count == 1)
		let error = try #require(second.states.first ?? nil)
		#expect(error.contains("Address already in use"))
		#expect(try await first.eventsAfterOneMore() == [])
	}
}

@Suite struct EventServerHookOriginTests {
	@Test(arguments: [
		"POST /event HTTP/1.1\r\nHost: 127.0.0.1:47823\r\nUser-Agent: curl/8.7.1\r\nX-Claude-Hook: 1",
		"POST /event HTTP/1.1\r\nHost: localhost:47823\r\nX-Claude-Hook: 1",
		"POST /event HTTP/1.1\r\nhost: LOCALHOST\r\nX-Claude-Hook: 1",
		"POST /event HTTP/1.1\r\nHost: 0.0.0.0:47823\r\nX-Claude-Hook: 1",
		"POST /event HTTP/1.1\r\nHost: 127.1\r\nX-Claude-Hook: 1",
		"POST /event HTTP/1.1\r\nHost: [::1]:47823\r\nX-Claude-Hook: 1",
		"POST /event HTTP/1.1\r\nX-Claude-Hook: 1",
	])
	func hookRequest(head: String) {
		#expect(EventServer.isFromHook(head))
	}

	@Test(arguments: [
		"POST /event HTTP/1.1\r\nHost: evil.example:47823\r\nX-Claude-Hook: 1",
		"POST /event HTTP/1.1\r\nHost: localhost.evil.example:47823\r\nX-Claude-Hook: 1",
		"POST /event HTTP/1.1\r\nHost: 127.0.0.1.nip.io:47823\r\nX-Claude-Hook: 1",
		"POST /event HTTP/1.1\r\nHost: 127.0.0.1:47823\r\nOrigin: http://127.0.0.1:47823\r\nX-Claude-Hook: 1",
		"POST /event HTTP/1.1\r\nORIGIN: null\r\nX-Claude-Hook: 1",
	])
	func browserRequest(head: String) {
		#expect(!EventServer.isFromHook(head))
	}

	/// The request line is no header, even when its path looks like one.
	@Test func requestLineIsNoHeader() {
		#expect(EventServer.isFromHook("origin: /event HTTP/1.1\r\nHost: 127.0.0.1"))
	}
}
