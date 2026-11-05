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

	/// The name, then one bar for each limit. Without data, the bars stay empty and the name line names the reason.
	private func row(_ entry: AccountUsageEntry) -> some View {
		VStack(alignment: .leading, spacing: 3) {
			HStack(spacing: 4) {
				Text(entry.name)
					.lineLimit(1)
					.truncationMode(.middle)
					.help(entry.directory.path)
				Spacer(minLength: 8)
				status(entry)
					.font(.system(size: NSFont.smallSystemFontSize))
					.lineLimit(1)
			}
			window("5 h", entry.usage?.fiveHour)
			window("Week", entry.usage?.sevenDay)
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

	/// For example »5 h ▬▬▬▭▭▭ 12 % 17:30«. From 80 % on, the bar is orange.
	private func window(_ title: String, _ window: AccountUsage.Window?) -> some View {
		HStack(spacing: 6) {
			Text(title)
				.frame(width: 34, alignment: .leading)
			UsageBar(fraction: (window?.percent ?? 0) / 100, color: (window?.percent ?? 0) >= 80 ? .orange : .accentColor)
			Text(window.map { "\(Int($0.percent.rounded())) %" } ?? "–")
				.monospacedDigit()
				.fontWeight(.semibold)
				.foregroundStyle(.primary)
				.frame(width: 38, alignment: .trailing)
			Text(window?.resetsAt.map { Self.resetText($0, now: clock.now) } ?? "")
				.monospacedDigit()
				.frame(width: 72, alignment: .trailing)
				.help(window?.resetsAt.map { "Resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
		}
		.font(.system(size: NSFont.smallSystemFontSize))
		.foregroundStyle(.secondary)
	}

	/// The time for a reset in the next 24 hours, else also the weekday: »17:30« or »Mon 08:00«.
	static func resetText(_ reset: Date, now: Date) -> String {
		let soon = reset.timeIntervalSince(now) < 24 * 3600
		return reset.formatted(soon ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated).hour().minute())
	}
}

/// A thin bar that fills from the left. The fraction goes from 0 to 1.
struct UsageBar: View {
	let fraction: Double
	let color: Color

	var body: some View {
		GeometryReader { geometry in
			ZStack(alignment: .leading) {
				Capsule().fill(Color.primary.opacity(0.12))
				Capsule().fill(color)
					.frame(width: geometry.size.width * min(max(fraction, 0), 1))
			}
		}
		.frame(height: 5)
	}
}
