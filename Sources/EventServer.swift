import Foundation
import Network

/// A minimal HTTP server on the loopback interface. It accepts `POST /event` with the header `X-Claude-Hook`
/// and passes the body on. The custom header makes browsers send a CORS preflight, which this server never
/// answers. A page that uses DNS rebinding needs no preflight, but ``isFromHook(_:)`` refuses its requests.
final class EventServer {
	/// A hook sends its whole request at once, and its curl stops after 1 s.
	static let connectionTimeout = 3.0
	/// With more open connections, the oldest one closes, so that idle connections cannot block the hooks.
	static let maxConnections = 32

	private let port: UInt16
	private let queue = DispatchQueue(label: "EventServer")
	private var listener: NWListener?
	/// The open connections, the oldest first. Used only on ``queue``.
	private var connections: [NWConnection] = []

	init(port: UInt16) {
		self.port = port
	}

	/// - Parameters:
	///   - onEvent: Receives the body of each valid request, on a background queue.
	///   - onStateChange: Receives `nil` once the server listens, or the error that stops it.
	func start(onEvent: @escaping (Data) -> Void, onStateChange: @escaping (String?) -> Void) {
		let parameters = NWParameters.tcp
		parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
		parameters.allowLocalEndpointReuse = true

		do {
			listener = try NWListener(using: parameters)
		} catch {
			onStateChange(error.localizedDescription)
			return
		}
		listener?.stateUpdateHandler = { state in
			switch state {
			case .ready: onStateChange(nil)
			case .failed(let error): onStateChange(error.localizedDescription)
			default: break
			}
		}
		listener?.newConnectionHandler = { [weak self] connection in
			guard let self else { return }
			if self.connections.count >= Self.maxConnections { self.connections.removeFirst().cancel() }
			self.connections.append(connection)
			connection.stateUpdateHandler = { [weak self, weak connection] state in
				switch state {
				case .cancelled, .failed: self?.connections.removeAll { $0 === connection }
				default: break
				}
			}
			connection.start(queue: self.queue)
			self.queue.asyncAfter(deadline: .now() + Self.connectionTimeout) { connection.cancel() }
			self.receive(on: connection, buffer: Data(), onEvent: onEvent)
		}
		listener?.start(queue: queue)
	}

	private func receive(on connection: NWConnection, buffer: Data, onEvent: @escaping (Data) -> Void) {
		connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
			var buffer = buffer
			if let data { buffer.append(data) }

			if let request = Self.parse(buffer) {
				let isValid = request.head.hasPrefix("POST /event ") && request.head.lowercased().contains("\r\nx-claude-hook:")
					&& Self.isFromHook(request.head)
				let status = isValid ? "204 No Content" : "404 Not Found"
				let response = Data("HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
				connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
				if isValid { onEvent(request.body) }
				return
			}
			if isComplete || error != nil || buffer.count > 1_000_000 {
				connection.cancel()
				return
			}
			self?.receive(on: connection, buffer: buffer, onEvent: onEvent)
		}
	}

	/// Whether the head of a request comes from a hook and not from a web page. A page that uses DNS rebinding to reach
	/// this server is same-origin, so its browser sends the custom header without a preflight. But a browser sends
	/// `Origin` with every POST, and its `Host` is the name of the page. A hook uses `localhost` or an IP address.
	static func isFromHook(_ head: String) -> Bool {
		let lines = head.lowercased().components(separatedBy: "\r\n").dropFirst()
		if lines.contains(where: { $0.hasPrefix("origin:") }) { return false }
		guard let host = lines.first(where: { $0.hasPrefix("host:") })?.dropFirst("host:".count).trimmingCharacters(in: .whitespaces),
			!host.hasPrefix("[") else { return true }
		let name = host.prefix { $0 != ":" }
		return name == "localhost" || name.allSatisfy { ("0"..."9").contains($0) || $0 == "." }
	}

	/// The head and body of the request, or `nil` while it is not complete yet.
	static func parse(_ buffer: Data) -> (head: String, body: Data)? {
		guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
		let head = String(decoding: buffer[..<separator.lowerBound], as: UTF8.self)
		let contentLength = head
			.components(separatedBy: "\r\n")
			.first { $0.lowercased().hasPrefix("content-length:") }
			.flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) }
			// A negative length counts as 0: `prefix` stops the app for it.
			.map { max($0, 0) } ?? 0
		let body = buffer[separator.upperBound...]
		guard body.count >= contentLength else { return nil }
		return (head, Data(body.prefix(contentLength)))
	}
}
