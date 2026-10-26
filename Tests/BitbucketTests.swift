import Foundation
import Testing
@testable import ClaudeCodeNotifier

@Suite struct BitbucketTests {
	private static let environment = [Bitbucket.emailVariable: "me@example.com", Bitbucket.tokenVariable: "token"]

	@Test(arguments: [
		("git@bitbucket.org:drplanoteam/drplano.git\n", "drplanoteam/drplano"),
		("https://nils@bitbucket.org/ws/repo.git", "ws/repo"),
		("https://bitbucket.org/ws/repo", "ws/repo"),
		("git@github.com:me/app.git", nil),
		("", nil),
	] as [(String, String?)])
	func repositoryFromTheRemote(remote: String, repository: String?) {
		#expect(Bitbucket.repository(remote: remote) == repository)
	}

	@Test func needsTheRemoteAndTheCredentials() {
		let get: (URLRequest) async throws -> (Data, Int) = { _ in (Data(), 200) }
		#expect(throws: Bitbucket.Failure.self) { try Bitbucket(remote: "git@github.com:me/app.git", environment: Self.environment, get: get) }
		#expect(throws: Bitbucket.Failure.self) {
			try Bitbucket(remote: "git@bitbucket.org:ws/repo.git", environment: [Bitbucket.emailVariable: "me@example.com"], get: get)
		}
	}

	@Test func valuesFollowTheNextPagesOnBitbucketOnly() async throws {
		let requests = Locked<[URL]>([])
		let bitbucket = try Bitbucket(remote: "git@bitbucket.org:ws/repo.git", environment: Self.environment) { request in
			let count = requests.update { $0.append(request.url!); return $0.count }
			let next: String? = switch count {
			case 1: "https://api.bitbucket.org/2.0/repositories/ws/repo/pullrequests?page=2"
			case 2: "https://evil.example.com/steal?page=3"
			default: nil
			}
			return (bitbucketPage([["id": count]], next: next), 200)
		}
		let values = try await bitbucket.values("/pullrequests", query: ["q": "state=\"MERGED\""], fields: ["id", "title"])
		#expect(values.map { $0["id"] as? Int } == [1, 2])
		let urls = requests.update { $0 }
		#expect(urls.map(\.host) == ["api.bitbucket.org", "api.bitbucket.org"])
		let query = URLComponents(url: urls[0], resolvingAgainstBaseURL: false)?.queryItems ?? []
		#expect(query.first { $0.name == "fields" }?.value == "next,values.id,values.title")
		#expect(query.first { $0.name == "q" }?.value == "state=\"MERGED\"")
		#expect(urls[1].query == "page=2")
	}

	@Test func valuesStopAfterMaxPages() async throws {
		let count = Locked(0)
		let bitbucket = try Bitbucket(remote: "git@bitbucket.org:ws/repo.git", environment: Self.environment) { _ in
			count.update { $0 += 1 }
			return (bitbucketPage([["id": 1]], next: "https://api.bitbucket.org/2.0/next"), 200)
		}
		#expect(try await bitbucket.values("/x", query: [:], fields: ["id"], maxPages: 3).count == 3)
		#expect(count.update { $0 } == 3)
	}

	@Test func otherStatusThrows() async throws {
		let bitbucket = try Bitbucket(remote: "git@bitbucket.org:ws/repo.git", environment: Self.environment) { _ in (Data(), 403) }
		await #expect(throws: Bitbucket.Failure.self) { try await bitbucket.values("/x", query: [:], fields: []) }
	}

	@Test func cutAddsAnEllipsis() {
		#expect("abcdef".cut(to: 3) == "abc…")
		#expect("abc".cut(to: 3) == "abc")
	}
}
