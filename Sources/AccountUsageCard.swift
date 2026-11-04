import SwiftUI

/// The usage limits of each Claude account, below ``SessionCard``. Each row has two lines, so that the height of the
/// card does not change while the data loads.
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

	private func row(_ entry: AccountUsageEntry) -> some View {
		VStack(alignment: .leading, spacing: 1) {
			HStack(spacing: 4) {
				Text(entry.name)
					.lineLimit(1)
					.truncationMode(.middle)
					.help(entry.directory.path)
				if entry.failure != nil && entry.usage != nil {
					Image(systemName: "exclamationmark.triangle.fill")
						.foregroundStyle(.orange)
						.help(entry.failure ?? "")
				}
			}
			detail(entry)
				.font(.system(size: NSFont.smallSystemFontSize))
				.foregroundStyle(.secondary)
				.lineLimit(1)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(.horizontal, 6)
		.padding(.vertical, 3)
	}

	@ViewBuilder
	private func detail(_ entry: AccountUsageEntry) -> some View {
		if let usage = entry.usage {
			HStack(spacing: 12) {
				window("5 h", usage.fiveHour)
				window("Week", usage.sevenDay)
			}
		} else if let failure = entry.failure {
			Text(failure).foregroundStyle(.orange).help(failure)
		} else {
			Text("Loading …")
		}
	}

	/// For example »5 h 12 % · 17:30«. From 80 % on, the percentage is orange.
	private func window(_ title: String, _ window: AccountUsage.Window?) -> some View {
		HStack(spacing: 4) {
			Text(title)
			if let window {
				Text("\(Int(window.percent.rounded())) %")
					.monospacedDigit()
					.fontWeight(.semibold)
					.foregroundStyle(window.percent >= 80 ? Color.orange : Color.primary)
				if let reset = window.resetsAt {
					Text("· \(Self.resetText(reset, now: clock.now))")
						.monospacedDigit()
						.help("Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
				}
			} else {
				Text("–")
			}
		}
	}

	/// The time for a reset in the next 24 hours, else also the weekday: »17:30« or »Mon 08:00«.
	static func resetText(_ reset: Date, now: Date) -> String {
		let soon = reset.timeIntervalSince(now) < 24 * 3600
		return reset.formatted(soon ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated).hour().minute())
	}
}
