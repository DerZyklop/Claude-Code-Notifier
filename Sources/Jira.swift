import Foundation

/// Read requests to the Jira Cloud API of one site, with a scoped API token of the user. The requests go through the
/// API gateway of Atlassian, because a scoped token works only there.
struct Jira {
	static let tokenVariable = "JIRA_API_TOKEN"
	/// The email of the Atlassian account. Without it, the app uses ``Bitbucket/emailVariable``.
	static let emailVariable = "JIRA_API_EMAIL"
	/// The site, e.g. `drplano.atlassian.net`. Without it, the app uses the site of a ticket link in the old overview.
	static let siteVariable = "JIRA_SITE"
	/// The variables of the login shell that ``connect(environment:old:get:)`` reads.
	static let variables = [tokenVariable, emailVariable, Bitbucket.emailVariable, siteVariable]
	static let gatewayHost = "api.atlassian.com"
	/// The fields of each ticket.
	static let fields = ["summary", "status", "issuelinks"]
	/// The most tickets in one answer.
	static let pageSize = 100

	/// The base URL of the API, e.g. `https://api.atlassian.com/ex/jira/<cloud ID>/rest/api/3`.
	let api: URL
	/// The start of each ticket link, e.g. `https://drplano.atlassian.net/browse/`.
	let browseURL: String
	let authorization: String
	let get: (URLRequest) async throws -> (Data, Int)

	enum Failure: Error, CustomStringConvertible {
		case noCredentials, noSite, noCloudID, status(Int)

		var description: String {
			switch self {
			case .noCredentials: "\(Jira.tokenVariable) or \(Jira.emailVariable) is not set in the login shell."
			case .noSite: "\(Jira.siteVariable) is not set in the login shell, and the old overview has no ticket link."
			case .noCloudID: "The Jira site gave no cloud ID."
			case .status(401): "Jira answered with HTTP 401: \(Jira.tokenVariable) is wrong or expired. Make a new token."
			case .status(403): "Jira answered with HTTP 403: \(Jira.tokenVariable) has no access. Give it the scope read:jira-work."
			case .status(let code): "Jira answered with HTTP \(code)."
			}
		}
	}

	/// The Jira of the site in ``site(environment:old:)``. The site gives its cloud ID without
	/// credentials. The credentials go only to the API gateway.
	/// - Parameter environment: The variables of the login shell with the credentials.
	static func connect(environment: [String: String], old: String?, get: @escaping (URLRequest) async throws -> (Data, Int)) async throws -> Jira {
		guard let token = environment[tokenVariable], let email = environment[emailVariable] ?? environment[Bitbucket.emailVariable] else {
			throw Failure.noCredentials
		}
		guard let site = site(environment: environment, old: old) else { throw Failure.noSite }
		let (data, status) = try await get(URLRequest(url: site.appendingPathComponent("_edge/tenant_info")))
		guard status == 200 else { throw Failure.status(status) }
		// The ID becomes a part of the path, so that it may have only these characters. An old site has its name after the
		// UUID, e.g. `fff89a1a-52c8-11e5-91b2-3c15c2bd8caa-ecosystem`.
		guard let cloudID = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["cloudId"] as? String,
			cloudID.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil else { throw Failure.noCloudID }
		return Jira(api: URL(string: "https://\(gatewayHost)/ex/jira/\(cloudID)/rest/api/3")!, browseURL: browseURL(of: site),
			authorization: "Basic " + Data("\(email):\(token)".utf8).base64EncodedString(), get: get)
	}

	/// The site in `JIRA_SITE`, else the site of the first ticket link in the sections of Claude in `old`, e.g.
	/// `https://drplano.atlassian.net`. A link in the notes of the user, e.g. to the Jira of a vendor, does not count.
	static func site(environment: [String: String], old: String?) -> URL? {
		site(of: environment[siteVariable] ?? old.map(MorningOverview.withoutAppSections).flatMap(DiDi.jiraBrowseURL) ?? "")
	}

	/// The root URL of a site, from a host or a URL, e.g. `https://drplano.atlassian.net` for `drplano.atlassian.net` or
	/// for `https://drplano.atlassian.net/browse/`. `nil` for a text that is no host.
	static func site(of text: String) -> URL? {
		var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
		if !text.contains("://") { text = "https://" + text }
		guard let url = URL(string: text), url.scheme == "https", let host = url.host, !host.isEmpty else { return nil }
		return URL(string: "https://\(host)")
	}

	/// The start of each ticket link of `site`.
	static func browseURL(of site: URL) -> String { site.absoluteString + "/browse/" }

	/// The tickets of a JQL search, at most `maxPages` pages.
	func search(_ jql: String, maxPages: Int = 5) async throws -> [[String: Any]] {
		var issues: [[String: Any]] = []
		var pageToken: String?
		for _ in 0..<maxPages {
			var components = URLComponents(url: api.appendingPathComponent("search/jql"), resolvingAgainstBaseURL: false)!
			components.queryItems = [URLQueryItem(name: "jql", value: jql), URLQueryItem(name: "fields", value: Self.fields.joined(separator: ",")),
				URLQueryItem(name: "maxResults", value: "\(Self.pageSize)")] + (pageToken.map { [URLQueryItem(name: "nextPageToken", value: $0)] } ?? [])
			// A `+` in a query value must not reach the server as a space.
			components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
			let json = try await send(URLRequest(url: components.url!))
			issues += json["issues"] as? [[String: Any]] ?? []
			guard json["isLast"] as? Bool != true, let next = json["nextPageToken"] as? String else { break }
			pageToken = next
		}
		return issues
	}

	/// The tickets with the IDs in `keys`. An ID that Jira does not know gives no ticket and no error. The request is a
	/// POST, but it only reads.
	func tickets(_ keys: [String]) async throws -> [[String: Any]] {
		var issues: [[String: Any]] = []
		for start in stride(from: 0, to: keys.count, by: Self.pageSize) {
			var request = URLRequest(url: api.appendingPathComponent("issue/bulkfetch"))
			request.httpMethod = "POST"
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
			request.httpBody = try JSONSerialization.data(withJSONObject: ["issueIdsOrKeys": Array(keys[start..<min(start + Self.pageSize, keys.count)]),
				"fields": Self.fields])
			issues += try await send(request)["issues"] as? [[String: Any]] ?? []
		}
		return issues
	}

	private func send(_ request: URLRequest) async throws -> [String: Any] {
		var request = request
		request.setValue(authorization, forHTTPHeaderField: "Authorization")
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		let (data, status) = try await sendWithRetry(request)
		guard status == 200 else { throw Failure.status(status) }
		return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
	}

	/// A second try covers a short network error, e.g. a stale connection after the Mac woke up.
	private func sendWithRetry(_ request: URLRequest) async throws -> (Data, Int) {
		do {
			return try await get(request)
		} catch is URLError {
			return try await get(request)
		}
	}

	/// The facts of a ticket for the run: its summary, its status, `done`, and the open tickets that block it
	/// (`blockedBy`) and that it blocks (`blocks`). A ticket is `blocked` with the status »Blocked« or with a ticket in
	/// `blockedBy`. `nil` for an answer without a key.
	static func facts(of issue: [String: Any]) -> (key: String, facts: [String: Any])? {
		guard let key = issue["key"] as? String else { return nil }
		let fields = issue["fields"] as? [String: Any] ?? [:]
		let status = (fields["status"] as? [String: Any])?["name"] as? String ?? ""
		var blockedBy: [String] = []
		var blocks: [String] = []
		for link in fields["issuelinks"] as? [[String: Any]] ?? [] {
			let type = link["type"] as? [String: Any] ?? [:]
			// An `inwardIssue` stands on the inward side of the link: this ticket »is blocked by« it.
			if (type["inward"] as? String)?.lowercased() == "is blocked by", let other = openKey(of: link["inwardIssue"]) { blockedBy.append(other) }
			if (type["outward"] as? String)?.lowercased() == "blocks", let other = openKey(of: link["outwardIssue"]) { blocks.append(other) }
		}
		return (key, ["summary": fields["summary"] as? String ?? "", "status": status, "done": isDone(fields),
			"blocked": status.lowercased() == "blocked" || !blockedBy.isEmpty, "blockedBy": blockedBy, "blocks": blocks])
	}

	/// The key of a linked ticket that is not done.
	private static func openKey(of issue: Any?) -> String? {
		guard let issue = issue as? [String: Any], !isDone(issue["fields"] as? [String: Any] ?? [:]) else { return nil }
		return issue["key"] as? String
	}

	/// The status of the ticket is in the category »Done«, e.g. »Done« or »Closed«.
	private static func isDone(_ fields: [String: Any]) -> Bool {
		((fields["status"] as? [String: Any])?["statusCategory"] as? [String: Any])?["key"] as? String == "done"
	}

	/// The name of the status of a ticket in an answer.
	static func status(of issue: [String: Any]) -> String? {
		((issue["fields"] as? [String: Any])?["status"] as? [String: Any])?["name"] as? String
	}
}
