import SwiftUI

/// The usage limits of each Claude account, below ``SessionCard``. Each row has the same lines with and without data,
/// so that the height of the card does not change while the data loads.
struct AccountUsageCard: View {
	@ObservedObject var store: AccountUsageStore
	@ObservedObject var clock: MenuClock
	/// Opens the accounts tab of the setup window.
	var openSetup: () -> Void = {}

	var body: some View {
		VStack(spacing: 0) {
			header
			ForEach(Array(store.entries.enumerated()), id: \.element.id) { index, entry in
				if index > 0 { Divider().padding(.horizontal, 6) }
				row(entry)
			}
		}
		.menuCard()
	}

	private var header: some View {
		HStack(spacing: 4) {
			Text("Usage")
				.fontWeight(.semibold)
				.foregroundStyle(.secondary)
			Spacer(minLength: 16)
			if store.isLoading {
				ProgressView().controlSize(.mini)
			} else if let updated = store.entries.compactMap(\.updated).min() {
				Text("Updated \(SessionCard.elapsed(from: updated, to: clock.now)) ago")
					.monospacedDigit()
					.foregroundStyle(.secondary)
			}
			Button {
				store.refreshAll()
			} label: {
				Image(systemName: "arrow.clockwise")
			}
			.buttonStyle(.plain)
			.foregroundStyle(.secondary)
			.disabled(store.isLoading)
			.help("Update now. Each update uses a prompt of one token per account.")
			Button("Accounts …", action: openSetup)
				.buttonStyle(.link)
				.help("Add an account or log in to one")
		}
		.font(.system(size: NSFont.smallSystemFontSize))
		.padding(.horizontal, 6)
		.padding(.top, 3)
		.padding(.bottom, 5)
	}

	/// The name and the reset time, then one ``UsagePipe``. Without data, the pipe stays empty and the name line names
	/// the reason.
	private func row(_ entry: AccountUsageEntry) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(spacing: 4) {
				Text(entry.shortName)
					.lineLimit(1)
					.truncationMode(.middle)
					.help("\(entry.name)\n\(entry.directory.path)")
				if entry.isSessionAccount {
					Text("VS Code")
						.font(.system(size: NSFont.smallSystemFontSize - 1, weight: .medium))
						.foregroundStyle(.secondary)
						.padding(.horizontal, 4)
						.background(Capsule().fill(Color.primary.opacity(0.1)))
						.help("The Claude Code sessions in VS Code use this account.")
				}
				Spacer(minLength: 8)
				Group {
					status(entry)
					if let reset = entry.usage?.resetsAt {
						Text(Self.resetText(reset, now: clock.now))
							.monospacedDigit()
							.foregroundStyle(.secondary)
							.help("Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
					}
				}
				.font(.system(size: NSFont.smallSystemFontSize))
				.lineLimit(1)
			}
			UsagePipe(usage: entry.usage, now: clock.now)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(.horizontal, 6)
		.padding(.vertical, 4)
	}

	@ViewBuilder
	private func status(_ entry: AccountUsageEntry) -> some View {
		if let failure = entry.failure {
			Label(entry.usage == nil ? failure : "Old data", systemImage: "exclamationmark.triangle.fill")
				.foregroundStyle(.orange)
				.help(failure)
		} else if entry.usage == nil {
			Text("Loading …").foregroundStyle(.secondary)
		}
	}

	/// The time for a reset in the next 24 hours, else also the weekday: »17:30« or »Mon 08:00«.
	static func resetText(_ reset: Date, now: Date) -> String {
		let soon = reset.timeIntervalSince(now) < 24 * 3600
		return reset.formatted(soon ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated).hour().minute())
	}
}

/// One rounded pipe for both weekly limits: the week fills the upper half, Fable the lower half, each from the left.
/// Each half shows its percentage on hover. From 80 % on, a half is red.
struct UsagePipe: View {
	let usage: AccountUsage?
	let now: Date

	/// Bootstrap info, cyan-600 and danger.
	static let weekColor = Color(red: 0x0d / 255, green: 0xca / 255, blue: 0xf0 / 255)
	static let fableColor = Color(red: 0x0a / 255, green: 0xa2 / 255, blue: 0xc0 / 255)
	static let fullColor = Color(red: 0xdc / 255, green: 0x35 / 255, blue: 0x45 / 255)

	var body: some View {
		VStack(spacing: 0) {
			half(usage?.sevenDay, color: Self.weekColor)
				.help(Self.tooltip("Week", usage?.sevenDay, hasData: usage != nil, reset: usage?.resetsAt, now: now))
			half(usage?.fable, color: Self.fableColor)
				.help(Self.tooltip("Fable", usage?.fable, hasData: usage != nil, reset: usage?.resetsAt, now: now))
		}
		.frame(height: 10)
		.background(Color.primary.opacity(0.12))
		.clipShape(Capsule())
	}

	private func half(_ window: AccountUsage.Window?, color: Color) -> some View {
		GeometryReader { geometry in
			Rectangle()
				.fill((window?.percent ?? 0) >= 80 ? Self.fullColor : color)
				.frame(width: geometry.size.width * min(max((window?.percent ?? 0) / 100, 0), 1))
		}
		.contentShape(Rectangle())
	}

	/// For example »Week: 25 %«. A reset time that differs from `reset`, the time on the name line, is added.
	static func tooltip(_ title: String, _ window: AccountUsage.Window?, hasData: Bool, reset: Date?, now: Date) -> String {
		guard let window else { return hasData ? "No \(title) limit" : "\(title): no data yet" }
		var text = "\(title): \(Int(window.percent.rounded())) %"
		if let own = window.resetsAt, own != reset {
			text += ", resets \(AccountUsageCard.resetText(own, now: now))"
		}
		return text
	}
}
