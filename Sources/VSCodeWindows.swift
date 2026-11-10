import AppKit

/// An open VS Code window, from the extension in `vscode-extension/`.
struct VSCodeWindow: Decodable, Equatable {
	/// The workspace folders of the window.
	let folders: [String]
	/// The `.code-workspace` file of the window, if it shows a workspace.
	let workspaceFile: String?

	/// The path that VS Code opens in this window: VS Code opens a new window for a folder that a window shows only as
	/// part of a workspace.
	var path: String? { workspaceFile ?? folders.first }

	/// The length of the longest folder of the window that holds `cwd`, or `nil` if no folder holds it.
	func match(_ cwd: String) -> Int? {
		folders.filter { cwd == $0 || cwd.hasPrefix($0 + "/") }.map(\.count).max()
	}
}

/// The message of the VS Code extension when a window opens, closes, or gets or loses the focus.
private struct WindowEvent: Decodable {
	static let name = "Window"

	let hook_event_name: String
	let window: VSCodeWindow
	let focused: Bool
	let closed: Bool?
}

/// The open VS Code windows, and the opening of a Claude chat in the window of its session.
@MainActor
final class VSCodeWindows {
	static let shared = VSCodeWindows()

	private(set) var windows: [VSCodeWindow] = []
	/// The window that has the focus, or `nil` while VS Code is in the background.
	private(set) var focused: VSCodeWindow?
	/// The session to open as soon as its window has the focus, and the window.
	private var pending: (sessionID: String, window: VSCodeWindow)?
	private var pendingTimeout: DispatchWorkItem?

	/// Returns `false` if the data is no window event.
	@discardableResult
	func handle(_ data: Data) -> Bool {
		guard let event = try? JSONDecoder().decode(WindowEvent.self, from: data), event.hook_event_name == WindowEvent.name else { return false }
		windows.removeAll { $0.path == event.window.path }
		if event.closed == true {
			if focused?.path == event.window.path { focused = nil }
			return true
		}
		windows.append(event.window)
		if event.focused {
			focused = event.window
			if let pending, pending.window.path == event.window.path { openChat(pending.sessionID) }
		} else if focused?.path == event.window.path {
			focused = nil
		}
		return true
	}

	/// The window with the deepest folder that holds `cwd`.
	static func window(for cwd: String, in windows: [VSCodeWindow]) -> VSCodeWindow? {
		windows.compactMap { window in window.match(cwd).map { (window, $0) } }.max { $0.1 < $1.1 }?.0
	}

	/// The link of the Claude Code extension that opens the chat of the session in the front window.
	static func chatURL(sessionID: String) -> URL? {
		var components = URLComponents(string: "vscode://anthropic.claude-code/open")
		components?.queryItems = [URLQueryItem(name: "session", value: sessionID)]
		return components?.url
	}

	/// Brings the window of the session to the front, then opens the chat of the session in it. Without a known
	/// window, VS Code opens the folder of the session.
	func open(_ session: Session) {
		let window = session.cwd.flatMap { Self.window(for: $0, in: windows) }
		if let window, window == focused {
			activateVSCode()
			openChat(session.id)
			return
		}
		guard let path = window?.path ?? session.cwd, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") else {
			openChat(session.id)
			return
		}
		// VS Code brings the window of an open folder or workspace to the front. The chat link goes to the front window,
		// so it waits for the focus event of the window. Without the extension, no event comes.
		pending = (session.id, window ?? VSCodeWindow(folders: [path], workspaceFile: nil))
		let timeout = DispatchWorkItem { [weak self] in self?.openChat(session.id) }
		pendingTimeout = timeout
		DispatchQueue.main.asyncAfter(deadline: .now() + (window == nil ? 1.5 : 2), execute: timeout)
		NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
	}

	private func openChat(_ sessionID: String) {
		pending = nil
		pendingTimeout?.cancel()
		pendingTimeout = nil
		if let url = Self.chatURL(sessionID: sessionID) { NSWorkspace.shared.open(url) }
	}
}
