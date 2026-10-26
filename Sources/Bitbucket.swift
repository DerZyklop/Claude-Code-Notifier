import Foundation

/// GET requests to the Bitbucket API of one repository, with the API token of the user.
struct Bitbucket {
	static let emailVariable = "BITBUCKET_API_EMAIL"
	static let tokenVariable = "BITBUCKET_API_TOKEN"
	static let host = "api.bitbucket.org"

	/// `workspace/repo`.
	let repository: String
	let authorization: String
	let get: (URLRequest) async throws -> (Data, Int)

	enum Failure: Error, CustomStringConvertible {
		case noBitbucketRemote, noCredentials, status(Int)

		var description: String {
			switch self {
			case .noBitbucketRemote: "The remote »origin« is not on Bitbucket."
			case .noCredentials: "\(Bitbucket.emailVariable) or \(Bitbucket.tokenVariable) is not set in the login shell."
			case .status(let code): "Bitbucket answered with HTTP \(code)."
			}
		}
	}

	/// - Parameters:
	///   - remote: The URL of the git remote.
	///   - environment: The variables of the login shell with the credentials.
	init(remote: String, environment: [String: String], get: @escaping (URLRequest) async throws -> (Data, Int)) throws {
		guard let repository = Self.repository(remote: remote) else { throw Failure.noBitbucketRemote }
		guard let email = environment[Self.emailVariable], let token = environment[Self.tokenVariable] else { throw Failure.noCredentials }
		self.repository = repository
		authorization = "Basic " + Data("\(email):\(token)".utf8).base64EncodedString()
		self.get = get
	}

	/// The values of all pages of a list, at most `maxPages` pages.
	/// - Parameters:
	///   - path: The path below the repository, e.g. `/pullrequests`.
	///   - fields: The fields of each value. Without `next` in the fields, Bitbucket leaves out the link to the next page.
	func values(_ path: String, query: [String: String], fields: [String], maxPages: Int = 10) async throws -> [[String: Any]] {
		var components = URLComponents(string: "https://\(Self.host)/2.0/repositories/\(repository)\(path)")!
		var query = query
		query["fields"] = (["next"] + fields.map { "values." + $0 }).joined(separator: ",")
		components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
		var url = components.url
		var values: [[String: Any]] = []
		for _ in 0..<maxPages {
			guard let page = url else { break }
			var request = URLRequest(url: page)
			request.setValue(authorization, forHTTPHeaderField: "Authorization")
			let (data, status) = try await getWithRetry(request)
			guard status == 200 else { throw Failure.status(status) }
			let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
			values += json?["values"] as? [[String: Any]] ?? []
			// The credentials go only to Bitbucket.
			url = (json?["next"] as? String).flatMap(URL.init).flatMap { $0.host == Self.host ? $0 : nil }
		}
		return values
	}

	/// A second try covers a short network error, e.g. a stale connection after the Mac woke up.
	private func getWithRetry(_ request: URLRequest) async throws -> (Data, Int) {
		do {
			return try await get(request)
		} catch is URLError {
			return try await get(request)
		}
	}

	/// A task or comment with its text cut to 300 characters.
	static func shortened(_ item: [String: Any]) -> [String: Any] {
		var item = item
		if var content = item["content"] as? [String: Any], let raw = content["raw"] as? String {
			content["raw"] = raw.cut(to: 300)
			item["content"] = content
		}
		return item
	}

	/// The user wrote the pull request. Bitbucket shows the git user name as the display name.
	static func isAuthor(of pullRequest: [String: Any], me: String) -> Bool {
		(pullRequest["author"] as? [String: Any])?["display_name"] as? String == me
	}

	/// `workspace/repo` from an SSH or HTTPS remote URL on Bitbucket, or `nil` for another host.
	static func repository(remote: String) -> String? {
		let remote = remote.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let range = remote.range(of: "bitbucket.org[:/]", options: .regularExpression) else { return nil }
		var path = String(remote[range.upperBound...])
		if path.hasSuffix(".git") { path.removeLast(4) }
		return path.split(separator: "/").count == 2 ? path : nil
	}
}

extension String {
	/// The text cut to `limit` characters.
	func cut(to limit: Int) -> String {
		count > limit ? prefix(limit) + "…" : self
	}
}
