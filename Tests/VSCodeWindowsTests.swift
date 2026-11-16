import Foundation
import Testing
@testable import ClaudeCodeNotifier

@MainActor @Suite struct VSCodeWindowsTests {
	private func event(_ folders: [String], workspaceFile: String? = nil, focused: Bool, closed: Bool = false) -> Data {
		let window = VSCodeWindow(folders: folders, workspaceFile: workspaceFile)
		let file = window.workspaceFile.map { "\"\($0)\"" } ?? "null"
		let list = folders.map { "\"\($0)\"" }.joined(separator: ",")
		return Data(#"{"hook_event_name":"Window","window":{"folders":[\#(list)],"workspaceFile":\#(file)},"focused":\#(focused),"closed":\#(closed)}"#.utf8)
	}

	@Test func picksTheDeepestFolder() {
		let windows = [VSCodeWindow(folders: ["/s"], workspaceFile: nil), VSCodeWindow(folders: ["/s/app", "/s/lib"], workspaceFile: "/s/app.code-workspace")]
		#expect(VSCodeWindows.window(for: "/s/app/sub", in: windows) == windows[1])
		#expect(VSCodeWindows.window(for: "/s/other", in: windows) == windows[0])
		#expect(VSCodeWindows.window(for: "/s/application", in: [windows[1]]) == nil)
		#expect(VSCodeWindows.window(for: "/x", in: windows) == nil)
	}

	@Test func opensTheWorkspaceFileOfAWorkspace() {
		#expect(VSCodeWindow(folders: ["/s/app"], workspaceFile: "/s/app.code-workspace").path == "/s/app.code-workspace")
		#expect(VSCodeWindow(folders: ["/s/app"], workspaceFile: nil).path == "/s/app")
	}

	@Test func tracksTheOpenAndTheFocusedWindows() {
		let windows = VSCodeWindows()
		#expect(windows.handle(event(["/a"], focused: true)))
		#expect(windows.handle(event(["/b"], focused: false)))
		#expect(windows.windows.map(\.path) == ["/a", "/b"])
		#expect(windows.focused?.path == "/a")
		windows.handle(event(["/a"], focused: false))
		#expect(windows.focused == nil)
		#expect(windows.windows.count == 2)
		windows.handle(event(["/b"], focused: true, closed: true))
		#expect(windows.windows.map(\.path) == ["/a"])
	}

	@Test func findsTheWorkspaceFileAboveTheFolder() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("VSCodeWindowsTests-\(UUID().uuidString)").standardized
		defer { try? FileManager.default.removeItem(at: root) }
		let app = root.appendingPathComponent("s/app")
		try FileManager.default.createDirectory(at: app.appendingPathComponent("sub"), withIntermediateDirectories: true)
		// VS Code allows comments and trailing commas.
		try #"{ "folders": [ { "path": "./" }, ], // all of s"#.appending("\n}").write(to: root.appendingPathComponent("s/all.code-workspace"), atomically: true, encoding: .utf8)
		try #"{"folders": [{"path": "app"}, {"path": "/x"}]}"#.write(to: root.appendingPathComponent("s/app.code-workspace"), atomically: true, encoding: .utf8)
		try "no json".write(to: root.appendingPathComponent("s/broken.code-workspace"), atomically: true, encoding: .utf8)

		let s = root.appendingPathComponent("s").path
		#expect(VSCodeWindows.workspace(for: app.appendingPathComponent("sub").path)
			== VSCodeWindow(folders: [app.path, "/x"], workspaceFile: s + "/app.code-workspace"))
		#expect(VSCodeWindows.workspace(for: s)?.workspaceFile == s + "/all.code-workspace")
		#expect(VSCodeWindows.workspace(for: root.path) == nil)
	}

	@Test func ignoresOtherEvents() {
		#expect(!VSCodeWindows().handle(Data(#"{"hook_event_name":"TabFocus","tab":null}"#.utf8)))
	}

	@Test func chatURL() {
		#expect(VSCodeWindows.chatURL(sessionID: "8c1f0d2e-1b2a-4c3d-9e8f-0a1b2c3d4e5f")?.absoluteString
			== "vscode://anthropic.claude-code/open?session=8c1f0d2e-1b2a-4c3d-9e8f-0a1b2c3d4e5f")
	}
}
