import Foundation
import SwiftUI
import Testing
@testable import ClaudeCodeNotifier

@MainActor @Suite struct ReportTests {
	@Test(arguments: [
		("2026-10-27 06:00", 1_793_080_800),
		("soon", nil),
	] as [(String, TimeInterval?)])
	func updatedReadsTheDateAndTheTime(line: String, seconds: TimeInterval?) {
		#expect(Report.updated(in: "# Title\n\nUpdated: \(line)\n", calendar: utcCalendar) == seconds.map(Date.init(timeIntervalSince1970:)))
		#expect(Report.updated(in: "# Title\n", calendar: utcCalendar) == nil)
	}

	@Test func dueMomentOnlyOnTheDaysOfTheScheduleFromItsHourOn() {
		let schedule = Report.Schedule(weekdays: [3], hour: 6)
		let sixOClock = tuesdayMorning.addingTimeInterval(-3_600)
		#expect(schedule.dueMoment(at: tuesdayMorning, calendar: utcCalendar) == sixOClock)
		#expect(schedule.dueMoment(at: sixOClock, calendar: utcCalendar) == sixOClock)
		#expect(schedule.dueMoment(at: sixOClock.addingTimeInterval(-1), calendar: utcCalendar) == nil)
		#expect(schedule.dueMoment(at: tuesdayMorning.addingTimeInterval(86_400), calendar: utcCalendar) == nil)
	}

	@Test func buttonsRenderSideBySide() throws {
		let fixture = try ReportFixture()
		defer { fixture.cleanUp() }
		let image = ImageRenderer(content: ReportButtons(report: fixture.report) {}).nsImage
		#expect(image.map { $0.size.width > $0.size.height * 3 } == true)
	}

	@Test func hashLinksBecomeCode() {
		#expect(Report.hashLinksAsCode(in: "- [ ] [#4213](https://x/4213) [\\#7](https://x/7) [#dev](https://s) [PLANO-1](https://y) PR #12 [#8]")
			== "- [ ] [`#4213`](https://x/4213) [`#7`](https://x/7) [`#dev`](https://s) [PLANO-1](https://y) PR #12 [#8]")
		// Escaped brackets of plain text stay.
		#expect(Report.hashLinksAsCode(in: "see \\[#5\\](https://x)") == "see \\[#5\\](https://x)")
	}

	@Test func forNotificationFindsTheReport() {
		#expect(Report.forNotification("morning-overview") === Report.morningOverview)
		#expect(Report.forNotification("didi") === Report.didi)
		#expect(Report.forNotification("morning-overview-failed") == nil)
		#expect(Report.forNotification("session-1") == nil)
	}

	@Test func loginEnvironmentLeavesOutEmptyVariables() async throws {
		let fixture = try ReportFixture(kind: .morningOverview, claudeOutput: overviewText, environment: ["A_B": "x y", "EMPTY": ""],
			body: { ReportFixture.morningBody(of: $0) })
		defer { fixture.cleanUp() }
		#expect(await fixture.report.loginEnvironment(["A_B", "EMPTY", "MISSING"]) == ["A_B": "x y"])
		let script = try #require(fixture.log.commands.last?.arguments[4])
		#expect(script == #"printf '%s\0' "$A_B" "$EMPTY" "$MISSING""#)
	}

	@Test func runThatReadsOnlyItsInputGetsNoToolAndAnEmptyFolder() async throws {
		let fixture = try ReportFixture(kind: .didi, claudeOutput: "", body: { _ in bitbucketPage([]) })
		defer { fixture.cleanUp() }
		await fixture.report.update()
		let run = try #require(fixture.claudeRun)
		#expect(run.arguments[1] == "exec env -u BITBUCKET_API_TOKEN -u SLACK_USER_TOKEN \"$0\" \"$@\"")
		#expect(run.directory.path == fixture.root.appendingPathComponent("support/run").path)
		#expect(try FileManager.default.contentsOfDirectory(atPath: run.directory.path).isEmpty)
		#expect(fixture.value(of: "--tools") == "")
		#expect(fixture.value(of: "--disallowedTools") == "mcp__*")
		#expect(fixture.value(of: "--setting-sources") == "")
		#expect(fixture.value(of: "--output-format") == "json")
		#expect(fixture.value(of: "--json-schema") == DiDi.schema)
		for flag in ["--restricted", "--strict-mcp-config", "--no-session-persistence"] { #expect(run.arguments.contains(flag)) }
		for flag in ["--allowedTools", "--add-dir", "--mcp-config"] { #expect(!run.arguments.contains(flag)) }
	}

	@Test func schemaIsValidJSON() throws {
		#expect(try JSONSerialization.jsonObject(with: Data(DiDi.schema.utf8)) is [String: Any])
	}

	@Test func gitNeverStagesTheFile() async throws {
		let fixture = try ReportFixture()
		defer { fixture.cleanUp() }
		let git = fixture.folder.appendingPathComponent(".git")
		try FileManager.default.createDirectory(at: git.appendingPathComponent("info"), withIntermediateDirectories: true)
		try "ref: refs/heads/main\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
		let exclude = git.appendingPathComponent("info/exclude")
		try "# own rules\n*.log".write(to: exclude, atomically: true, encoding: .utf8)
		await fixture.report.update()
		await fixture.report.update()
		#expect(try String(contentsOf: exclude, encoding: .utf8) == "# own rules\n*.log\n/morning-overview.md\n")
	}

	@Test func worktreeFolderGetsNoExclude() async throws {
		let fixture = try ReportFixture()
		defer { fixture.cleanUp() }
		try "gitdir: /work/repo/.git/worktrees/x\n".write(to: fixture.folder.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
		await fixture.report.update()
		#expect(fixture.report.failure == nil)
		#expect(FileManager.default.fileExists(atPath: fixture.fileURL.path))
	}

	@Test func runAllIfDueRunsEachDueReport() async throws {
		let first = try ReportFixture()
		let second = try ReportFixture(kind: .didi, claudeOutput: "", body: { _ in bitbucketPage([]) })
		defer {
			first.cleanUp()
			second.cleanUp()
		}
		await Report.runAllIfDue([first.report, second.report])
		#expect(first.claudeRun != nil)
		#expect(second.claudeRun != nil)
		#expect(!first.report.isRunning && !second.report.isRunning)
	}

	@Test func unreadableOldFileStopsTheWrite() async throws {
		let fixture = try ReportFixture()
		defer { fixture.cleanUp() }
		try "# Morning overview\n\nUpdated: 2026-10-26 06:30\n".write(to: fixture.fileURL, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: fixture.fileURL.path)
		await fixture.report.update()
		#expect(fixture.report.failure?.hasPrefix("The old file could not be read: ") == true)
		try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.fileURL.path)
		#expect(try String(contentsOf: fixture.fileURL, encoding: .utf8).contains("2026-10-26"))
	}

	@Test func mutedSendsNoReadyNotification() async throws {
		let fixture = try ReportFixture()
		defer { fixture.cleanUp() }
		fixture.defaults.set(true, forKey: SettingsKey.muted)
		await fixture.report.update()
		#expect(fixture.log.posts.isEmpty)
		#expect(fixture.report.isUnread)
		#expect(fixture.log.ready == 1)
	}

	@Test func missingClaudeFailsWithAClearReason() async throws {
		let fixture = try ReportFixture()
		defer { fixture.cleanUp() }
		let report = Report(kind: .morningOverview, system: {
			var system = fixture.report.system
			let run = system.run
			system.run = { command in
				command.isClaudeRun ? .init(status: 127, output: "", error: "zsh: not found") : await run(command)
			}
			return system
		}())
		await report.update()
		#expect(report.failure == "The command »claude« was not found.")
	}

	@Test func theStartOfARunRemovesTheFailureOfTheLastRun() async throws {
		let fixture = try ReportFixture()
		defer { fixture.cleanUp() }
		let shared = Locked<Report?>(nil)
		let failureAtStart = Locked<String??>(nil)
		let claudeRuns = Locked(0)
		var system = fixture.report.system
		let run = system.run
		system.run = { command in
			guard command.isClaudeRun else { return await run(command) }
			if claudeRuns.update({ $0 += 1; return $0 }) == 1 { return .init(status: 127, output: "", error: "zsh: not found") }
			let failure = await MainActor.run { shared.update { $0 }?.failure }
			failureAtStart.update { $0 = .some(failure) }
			return await run(command)
		}
		let report = Report(kind: .morningOverview, system: system)
		shared.update { $0 = report }
		await report.update()
		#expect(report.failure == "The command »claude« was not found.")
		fixture.log.removed = []
		await report.update()
		#expect(failureAtStart.update { $0 } == .some(nil))
		#expect(fixture.log.removed.first == "morning-overview-failed")
	}

	@Test func stopEndsTheRunWithoutAFileAndWithoutAFailure() async throws {
		let fixture = try ReportFixture()
		defer { fixture.cleanUp() }
		let shared = Locked<Report?>(nil)
		var system = fixture.report.system
		let run = system.run
		system.run = { command in
			guard command.isClaudeRun else { return await run(command) }
			await MainActor.run { shared.update { $0 }?.stop() }
			return .init(status: 143, output: "", error: "")
		}
		let report = Report(kind: .morningOverview, system: system)
		shared.update { $0 = report }
		await report.update()
		#expect(report.isStopped)
		#expect(!report.isRunning)
		#expect(report.failure == nil)
		#expect(!FileManager.default.fileExists(atPath: report.fileURL.path))
		#expect(fixture.log.posts.isEmpty)
	}

	@Test func stopWhileTheInputIsCollectedStartsNoClaude() async throws {
		let fixture = try ReportFixture()
		defer { fixture.cleanUp() }
		let shared = Locked<Report?>(nil)
		var system = fixture.report.system
		let run = system.run
		system.run = { command in
			if !command.isClaudeRun { await MainActor.run { shared.update { $0 }?.stop() } }
			return await run(command)
		}
		let report = Report(kind: .morningOverview, system: system)
		shared.update { $0 = report }
		await report.update()
		#expect(report.isStopped)
		#expect(fixture.claudeRun == nil)
		#expect(report.failure == nil)
		#expect(fixture.log.posts.isEmpty)
	}

	@Test func stopDoesNothingWithoutARun() throws {
		let fixture = try ReportFixture()
		defer { fixture.cleanUp() }
		fixture.report.stop()
		#expect(!fixture.report.isStopped)
	}

	@Test func updateKeepsTheStartOfTheRun() async throws {
		let fixture = try ReportFixture()
		defer { fixture.cleanUp() }
		#expect(fixture.report.runStarted == nil)
		await fixture.report.update()
		#expect(fixture.report.runStarted == fixture.report.system.now())
	}

	@Test func theMarkStaysAfterARestart() async throws {
		let fixture = try ReportFixture()
		defer { fixture.cleanUp() }
		await fixture.report.update()
		#expect(Report(kind: fixture.report.kind, system: fixture.report.system).isUnread)
		fixture.report.openFile()
		#expect(!Report(kind: fixture.report.kind, system: fixture.report.system).isUnread)
	}

	@Test func openFileOpensItAndRemovesTheMark() async throws {
		let fixture = try ReportFixture()
		defer { fixture.cleanUp() }
		await fixture.report.update()
		fixture.report.openFile()
		#expect(!fixture.report.isUnread)
		#expect(fixture.log.opened == [fixture.fileURL])
	}

	@Test func remoteServersOnly() {
		#expect(Report.remoteServers(in: Data(#"{"mcpServers": {"lint": {"command": "npx"}}}"#.utf8)) == nil)
		#expect(Report.remoteServers(in: Data("no json".utf8)) == nil)
	}
}

@Suite struct ReportExecuteTests {
	private func command(_ executable: String, _ arguments: [String], input: String = "", timeout: TimeInterval = 5) -> Report.Command {
		Report.Command(executable: executable, arguments: arguments, directory: FileManager.default.temporaryDirectory,
			input: Data(input.utf8), timeout: timeout)
	}

	@Test func passesTheInputAndReadsBothStreams() async {
		let result = await Report.execute(command("/bin/sh", ["-c", "cat; echo oops >&2; exit 3"], input: "hello"))
		#expect(result.output == "hello")
		#expect(result.error == "oops\n")
		#expect(result.status == 3)
		#expect(!result.timedOut)
	}

	@Test func loginShellFormRunsTheProgramWithItsArguments() async {
		let result = await Report.execute(command("/bin/sh", ["-c", "exec \"$0\" \"$@\"", "/bin/echo", "a b", "c"]))
		#expect(result.output == "a b c\n")
	}

	@Test func programDoesNotGetTheRemovedVariables() async {
		let script = "SECRET=1; KEEP=2; export SECRET KEEP; exec env -u SECRET \"$0\" \"$@\""
		let result = await Report.execute(command("/bin/sh", ["-c", script, "/bin/sh", "-c", "echo \"[$SECRET][$KEEP]\""]))
		#expect(result.output == "[][2]\n")
	}

	@Test func endsTheProgramAfterTheTimeout() async {
		let result = await Report.execute(command("/bin/sleep", ["5"], timeout: 0.2))
		#expect(result.timedOut)
	}

	@Test func childGetsOnlyTheBasicVariables() {
		let environment = ["HOME": "/Users/me", "PATH": "/usr/bin", "CLAUDECODE": "1", "NODE_USE_ENV_PROXY": "1", "LANG": "en_US.UTF-8"]
		#expect(Report.childEnvironment(of: environment) == ["HOME": "/Users/me", "PATH": "/usr/bin", "LANG": "en_US.UTF-8"])
	}

	@Test func cancelEndsTheProgram() async {
		let start = Date()
		let task = Task { await Report.execute(command("/bin/sleep", ["5"])) }
		try? await Task.sleep(for: .milliseconds(200))
		task.cancel()
		let result = await task.value
		#expect(result.status == SIGTERM)
		#expect(!result.timedOut)
		#expect(Date().timeIntervalSince(start) < 2)
	}

	@Test func missingProgramGivesStatus127() async {
		let result = await Report.execute(command("/no/such/program", []))
		#expect(result.status == 127)
	}
}
