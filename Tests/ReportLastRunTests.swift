import Foundation
import Testing
@testable import ClaudeCodeNotifier

@MainActor @Suite struct ReportLastRunTests {
	@Test func aRunSavesItsCommandAndInputForAReplay() async throws {
		let fixture = try ReportFixture()
		defer { fixture.cleanUp() }
		await fixture.report.update()
		let data = try Data(contentsOf: fixture.report.lastRunURL)
		let run = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
		let arguments = try #require(run["arguments"] as? [String])
		#expect(arguments.contains("claude") && arguments.contains("-p"))
		// The login shell removes the tokens, so the replay does too.
		#expect(arguments.contains { $0.contains("env -u \(Bitbucket.tokenVariable)") })
		#expect(run["directory"] as? String == fixture.folder.path)
		let input = try Data(contentsOf: fixture.report.supportFolder.appendingPathComponent("last-run-input.json"))
		#expect(input == fixture.claudeRun?.input)
	}
}
