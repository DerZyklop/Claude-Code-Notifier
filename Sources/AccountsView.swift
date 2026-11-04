import AppKit
import SwiftUI

/// Runs `claude auth login` for one account folder. The command opens the login page of Claude in the browser. When
/// the page shows a code instead of a confirmation, the user pastes it into ``sendCode(_:)``.
@MainActor
final class AccountLogin: ObservableObject {
	static let shared = AccountLogin()

	/// The folder of the login that runs now.
	@Published private(set) var directory: URL?
	/// The login page, from the output of the command.
	@Published private(set) var url: URL?
	@Published private(set) var failure: String?
	private var process: Process?
	private var input: FileHandle?

	func start(directory: URL) {
		cancel()
		failure = nil
		url = nil
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let command = AccountUsageProbe.command(["auth", "login", "--claudeai"], directory: directory, timeout: 0)
		let process = Process()
		process.executableURL = URL(fileURLWithPath: command.executable)
		process.arguments = command.arguments
		process.currentDirectoryURL = command.directory
		process.environment = Report.childEnvironment(of: ProcessInfo.processInfo.environment)
		let stdin = Pipe(), stdout = Pipe()
		process.standardInput = stdin
		process.standardOutput = stdout
		process.standardError = stdout
		stdout.fileHandleForReading.readabilityHandler = { handle in
			let text = String(decoding: handle.availableData, as: UTF8.self)
			Task { @MainActor in self.read(text) }
		}
		process.terminationHandler = { ended in
			stdout.fileHandleForReading.readabilityHandler = nil
			Task { @MainActor in self.ended(ended) }
		}
		do {
			try process.run()
		} catch {
			failure = "»claude auth login« could not start: \(error.localizedDescription)"
			return
		}
		// A command that ends without reading its input must not stop the app with SIGPIPE.
		_ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
		self.process = process
		input = stdin.fileHandleForWriting
		self.directory = directory
	}

	func sendCode(_ code: String) {
		try? input?.write(contentsOf: Data((code.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8))
	}

	func cancel() {
		process?.terminationHandler = nil
		process?.terminate()
		process = nil
		input = nil
		directory = nil
	}

	private func read(_ text: String) {
		guard url == nil, let range = text.range(of: #"https://\S+oauth/authorize\S*"#, options: .regularExpression) else { return }
		url = URL(string: String(text[range]))
		// The command wrote the `.claude.json` of the folder by now, so the folder shows in the list.
		AccountUsageStore.shared.refreshAll()
	}

	private func ended(_ ended: Process) {
		guard ended === process else { return }
		process = nil
		input = nil
		directory = nil
		if ended.terminationStatus != 0 { failure = "The login failed. Try again." }
		AccountUsageStore.shared.refreshAll()
	}
}

/// The tab of the accounts in the setup window: the list of the accounts, a login for each, and a new account.
struct AccountsView: View {
	@ObservedObject private var store = AccountUsageStore.shared
	@ObservedObject private var login = AccountLogin.shared
	@State private var name = ""
	@State private var code = ""

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text("The menu shows the usage limits of each Claude account. Each account has its own Claude Code configuration folder and its own login.")
				.fixedSize(horizontal: false, vertical: true)

			VStack(alignment: .leading, spacing: 10) {
				ForEach(store.entries) { entry in row(entry) }
			}

			if login.directory != nil { loginBox }
			if let failure = login.failure {
				Text(failure).foregroundStyle(.red)
			}

			Divider()
			addAccount

			HStack {
				Text("A login and each update of the usage start the `claude` command of your login shell.")
					.font(.caption).foregroundStyle(.secondary)
				Spacer()
				Button("Update Usage") { store.refreshAll() }
					.disabled(store.isLoading)
				Button("Done") { SetupWindow.close() }
					.keyboardShortcut(.defaultAction)
			}
		}
		.padding(20)
		.frame(width: 600)
		.onAppear { store.refreshIfStale() }
	}

	private func row(_ entry: AccountUsageEntry) -> some View {
		HStack(alignment: .firstTextBaseline) {
			CheckRow(status: status(entry), title: entry.name, detail: detail(entry))
			Spacer()
			if login.directory == entry.directory {
				ProgressView().controlSize(.small)
			} else if entry.needsLogin {
				Button("Log In") { login.start(directory: entry.directory) }
			}
		}
	}

	private func status(_ entry: AccountUsageEntry) -> CheckStatus {
		if entry.isLoading || login.directory == entry.directory { return .waiting }
		if entry.needsLogin || entry.failure != nil { return .failed }
		return entry.usage == nil ? .inactive : .ok
	}

	private func detail(_ entry: AccountUsageEntry) -> String {
		let folder = (entry.directory.path as NSString).abbreviatingWithTildeInPath
		let state: String
		if entry.isLoading {
			state = "Updating …"
		} else if let failure = entry.failure {
			state = failure
		} else if let usage = entry.usage {
			state = [("5 h", usage.fiveHour), ("Week", usage.sevenDay)]
				.map { "\($0.0) \($0.1.map { "\(Int($0.percent.rounded())) %" } ?? "–")" }.joined(separator: ", ")
		} else {
			state = "No data yet."
		}
		return "\(folder): \(state)"
	}

	private var loginBox: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("Log in to the account in your browser. The account here updates when the login is done.")
				.fixedSize(horizontal: false, vertical: true)
			if let url = login.url {
				Link("Open the login page again", destination: url)
			}
			HStack {
				TextField("If the page shows a code, paste it here", text: $code)
					.onSubmit(send)
				Button("Send Code", action: send).disabled(code.isEmpty)
				Button("Cancel") { login.cancel() }
			}
		}
		.padding(10)
		.background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
	}

	private func send() {
		login.sendCode(code)
		code = ""
	}

	private var addAccount: some View {
		let directory = AccountUsageStore.newDirectory(named: name)
		return VStack(alignment: .leading, spacing: 6) {
			HStack {
				TextField("Name of the new account, for example »work«", text: $name)
					.onSubmit(add)
				Button("Add Account", action: add)
					.disabled(directory == nil || login.directory != nil)
			}
			Text(directory.map { "The account gets the folder \(($0.path as NSString).abbreviatingWithTildeInPath). In a terminal, use it with »CLAUDE_CONFIG_DIR=\($0.path) claude«." }
				?? "Use lowercase letters, digits and »-«. Each name can have only one account.")
				.font(.caption).foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	private func add() {
		guard let directory = AccountUsageStore.newDirectory(named: name), login.directory == nil else { return }
		name = ""
		login.start(directory: directory)
	}
}
