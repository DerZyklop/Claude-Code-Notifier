import Foundation
import Testing
@testable import ClaudeCodeNotifier

/// A `stream-json` output with one `rate_limit_event`, like Claude Code 2.1 writes it.
private func output(fiveHour: String = #"{"utilization":0.12,"resetsAt":2000}"#, sevenDay: String = #"{"utilization":0.405,"resetsAt":9000}"#) -> String {
	"""
	{"type":"system","subtype":"init","session_id":"s"}
	{"type":"assistant","message":{"content":[{"type":"text","text":"OK"}]}}
	{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":\(fiveHour),"seven_day":\(sevenDay)}}}
	{"type":"result","subtype":"success"}
	"""
}

@Suite struct AccountUsageParseTests {
	@Test func readsBothWindows() {
		let usage = AccountUsage.parse(streamJSON: output(), now: Date(timeIntervalSince1970: 1000))
		#expect(usage == AccountUsage(fiveHour: .init(percent: 12, resetsAt: Date(timeIntervalSince1970: 2000)),
			sevenDay: .init(percent: 40.5, resetsAt: Date(timeIntervalSince1970: 9000))))
	}

	@Test func countsAWindowAfterItsResetAsUnused() {
		let usage = AccountUsage.parse(streamJSON: output(), now: Date(timeIntervalSince1970: 5000))
		#expect(usage?.fiveHour == .init(percent: 0))
		#expect(usage?.sevenDay?.percent == 40.5)
	}

	@Test func leavesOutAMissingWindow() {
		let text = #"{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"seven_day":{"utilization":1}}}}"#
		#expect(AccountUsage.parse(streamJSON: text) == AccountUsage(sevenDay: .init(percent: 100)))
	}

	@Test func givesNilWithoutAnEvent() {
		#expect(AccountUsage.parse(streamJSON: #"{"type":"result"}"# + "\nnot json") == nil)
	}
}

@Suite struct AccountUsageDirectoryTests {
	@Test func findsTheFoldersOfClaudeCode() throws {
		let home = FileManager.default.temporaryDirectory.appendingPathComponent("AccountUsageTests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: home) }
		for name in [".claude", ".claude-work", ".claude-b", ".claude-tool", ".other"] {
			try FileManager.default.createDirectory(at: home.appendingPathComponent(name), withIntermediateDirectories: true)
		}
		for name in [".claude-work", ".claude-b", ".other"] {
			FileManager.default.createFile(atPath: home.appendingPathComponent("\(name)/.claude.json").path, contents: Data("{}".utf8))
		}
		let directories = AccountUsageStore.configDirectories(home: home, defaultDirectory: home.appendingPathComponent(".claude"))
		#expect(directories.map(\.lastPathComponent) == [".claude", ".claude-b", ".claude-work"])
	}
}

@MainActor @Suite struct AccountUsageStoreTests {
	private let usage = AccountUsage(fiveHour: .init(percent: 5))

	@Test func updatesOnlyStaleAccounts() async throws {
		var fetched: [String] = []
		let store = AccountUsageStore(directories: { [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")] }, fetch: { url in
			fetched.append(url.path)
			return .init(email: "\(url.lastPathComponent)@example.com", usage: AccountUsage(fiveHour: .init(percent: 5)))
		})
		store.refreshIfStale()
		try await waitUntil { !store.isLoading }
		#expect(fetched.sorted() == ["/a", "/b"])
		#expect(store.entries.map(\.name) == ["a@example.com", "b@example.com"])
		#expect(store.entries.allSatisfy { $0.usage == usage })

		store.refreshIfStale()
		#expect(!store.isLoading)
		store.refreshIfStale(now: Date().addingTimeInterval(AccountUsageStore.maxAge + 1))
		try await waitUntil { !store.isLoading }
		#expect(fetched.count == 4)
	}

	@Test func keepsTheOldUsageAfterAFailure() async throws {
		var result = AccountUsageStore.Fetch(usage: AccountUsage(fiveHour: .init(percent: 5)))
		let store = AccountUsageStore(directories: { [URL(fileURLWithPath: "/a")] }, fetch: { _ in result })
		store.refreshAll()
		try await waitUntil { !store.isLoading }
		result = .init(failure: "offline")
		store.refreshAll()
		try await waitUntil { !store.isLoading }
		#expect(store.entries.first?.usage == usage)
		#expect(store.entries.first?.failure == "offline")
	}

	private struct Timeout: Error {}

	private func waitUntil(_ condition: () -> Bool) async throws {
		let deadline = Date().addingTimeInterval(5)
		while !condition() {
			guard Date() < deadline else { throw Timeout() }
			try await Task.sleep(nanoseconds: 10_000_000)
		}
	}
}
