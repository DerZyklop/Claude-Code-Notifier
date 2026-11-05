import AppKit
import os
import SwiftUI

/// Runs `claude auth login` for one account folder. The command opens the login page of Claude in the browser and ends
/// when the login is done.
@MainActor
final class AccountLogin: ObservableObject {
	static let shared = AccountLogin()

	/// The folder of the login that runs now.
	@Published private(set) var directory: URL?
	/// The login page, from the output of the command.
	@Published private(set) var url: URL?
	@Published private(set) var failure: String?
	/// The result of the last login that did not add an account, for example because the account is in the list.
	@Published private(set) var notice: String?
	/// Whether the app created the folder for this login, see ``startNew()``.
	private var isNew = false
	private var process: Process?
	/// The output of the command so far, for the reason of a failure.
	private var output = ""
	/// Stays open while the login runs, so that the prompt of the command for a code does not end it with an empty input.
	private var input: FileHandle?

	/// Logs in to a new folder. The login page decides the account. The folder joins the list only when no other
	/// folder has the same account, see ``AccountUsageStore/adopt(_:)``.
	func startNew() {
		do {
			let directory = try AccountUsageStore.createDirectory()
			AccountUsageStore.shared.hold(directory)
			start(directory: directory, isNew: true)
		} catch {
			failure = "The folder for the account could not be created: \(error.localizedDescription)"
		}
	}

	/// Logs in to a folder of the list again.
	func start(directory: URL) {
		start(directory: directory, isNew: false)
	}

	private func start(directory: URL, isNew: Bool) {
		cancel()
		failure = nil
		output = ""
		notice = nil
		url = nil
		self.isNew = isNew
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
			let rest = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
			Task { @MainActor in await self.ended(ended, rest: rest) }
		}
		self.directory = directory
		do {
			try process.run()
		} catch {
			failure = "»claude auth login« could not start: \(error.localizedDescription)"
			finish(success: false)
			return
		}
		// A command that ends without reading its input must not stop the app with SIGPIPE.
		_ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
		self.process = process
		input = stdin.fileHandleForWriting
	}

	/// Sends the code from the login page to the command. The browser shows the code when it cannot give the login
	/// back to the command by itself.
	func send(code: String) {
		let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !code.isEmpty, let input else { return }
		try? input.write(contentsOf: Data((code + "\n").utf8))
	}

	func cancel() {
		process?.terminationHandler = nil
		process?.terminate()
		finish(success: false)
	}

	private func read(_ text: String) {
		output += text
		guard url == nil, let range = text.range(of: #"https://\S+oauth/authorize\S*"#, options: .regularExpression) else { return }
		url = URL(string: String(text[range]))
	}

	private func ended(_ ended: Process, rest: String) async {
		guard ended === process else { return }
		output += rest
		if ended.terminationStatus != 0 {
			failure = Self.failureText(output: output)
			Self.log.error("claude auth login ended with \(ended.terminationStatus): \(self.output, privacy: .public)")
		}
		finish(success: ended.terminationStatus == 0)
	}

	private static let log = Logger(subsystem: "local.claude-code-notifier.app", category: "AccountLogin")

	/// The last line of the output, without the prompt and terminal colors, for example »The login failed: Request
	/// failed with status code 400.«
	nonisolated static func failureText(output: String) -> String {
		let plain = output.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
			.replacingOccurrences(of: "Paste code here if prompted >", with: "\n")
		let line = plain.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
		guard var reason = line else { return "The login failed. Try again." }
		if reason.lowercased().hasPrefix("login failed:") { reason = String(reason.dropFirst("login failed:".count)).trimmingCharacters(in: .whitespaces) }
		return "The login failed: \(reason.prefix(200))" + (reason.hasSuffix(".") ? "" : ".")
	}

	/// A new folder joins the list after a login, else it goes away.
	private func finish(success: Bool) {
		let directory = directory
		let isNew = isNew
		process = nil
		input = nil
		self.directory = nil
		self.isNew = false
		guard let directory else { return }
		let store = AccountUsageStore.shared
		Task {
			if !isNew {
				store.refreshAll()
			} else if success {
				notice = await store.adopt(directory)
			} else {
				await store.remove(directory)
			}
		}
	}
}

/// The tab of the accounts in the setup window: the list of the accounts, a login for each, and a new account.
struct AccountsView: View {
	@ObservedObject private var store = AccountUsageStore.shared
	@ObservedObject private var login = AccountLogin.shared
	@State private var removal: AccountUsageEntry?
	@State private var code = ""

	private func sendCode() {
		login.send(code: code)
		code = ""
	}

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
			if let notice = login.notice {
				Text(notice).foregroundStyle(.secondary)
			}

			Divider()
			HStack {
				Button("Add Account …") { login.startNew() }
					.disabled(login.directory != nil)
				Text("Opens the login page of Claude. The account that you log in to joins the list.")
					.font(.caption).foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}

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
		.confirmationDialog(removal.map { "Remove \($0.name)?" } ?? "", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
			presenting: removal) { entry in
			Button("Remove", role: .destructive) { Task { await store.remove(entry.directory) } }
		} message: { entry in
			Text(AccountUsageStore.isCreatedByApp(entry.directory)
				? "The app logs out of the account and deletes the folder \(Self.folder(entry))."
				: "The account leaves the list. The folder \(Self.folder(entry)) and its login stay, because Claude Code can use them.")
		}
	}

	static func folder(_ entry: AccountUsageEntry) -> String {
		(entry.directory.path as NSString).abbreviatingWithTildeInPath
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
			Button {
				removal = entry
			} label: {
				Image(systemName: "minus.circle")
			}
			.buttonStyle(.borderless)
			.disabled(login.directory != nil)
			.help("Remove from the list")
		}
	}

	private func status(_ entry: AccountUsageEntry) -> CheckStatus {
		if entry.isLoading || login.directory == entry.directory { return .waiting }
		if entry.needsLogin || entry.failure != nil { return .failed }
		return entry.usage == nil ? .inactive : .ok
	}

	private func detail(_ entry: AccountUsageEntry) -> String {
		let folder = Self.folder(entry)
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
			Text("Log in to the account in your browser. The list updates when the login is done. If the browser shows a code, paste it here.")
				.fixedSize(horizontal: false, vertical: true)
			HStack {
				TextField("Code", text: $code)
					.textFieldStyle(.roundedBorder)
					.onSubmit(sendCode)
				Button("Send", action: sendCode)
					.disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
				if let url = login.url {
					Link("Open the login page again", destination: url)
				}
				Spacer()
				Button("Cancel") { login.cancel() }
			}
		}
		.padding(10)
		.background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
	}
}
