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

	/// For example »Reset in 8d«.
	static func resetText(_ reset: Date, now: Date) -> String {
		"Reset in \(SessionCard.elapsed(from: now, to: reset, largestUnitOnly: true))"
	}
}

/// One rounded pipe for both weekly limits: the week fills the upper half, Fable the lower half, each from the left.
/// Each half shows its percentage on hover. Its hover area covers the full width of the half, and also the free space
/// above or below the pipe. From 80 % on, a half is red. The pipe draws its own tooltip, because the system tooltip of
/// `help(_:)` does not show in the menu.
struct UsagePipe: View {
	let usage: AccountUsage?
	let now: Date

	/// The text of the hovered half, and the x position of the pointer.
	@State private var hover: (text: String, x: CGFloat)?
	@State private var bubbleWidth: CGFloat = 0

	/// Bootstrap 4 info, its darker hover color, and Bootstrap danger.
	static let weekColor = Color(red: 0x17 / 255, green: 0xa2 / 255, blue: 0xb8 / 255)
	static let fableColor = Color(red: 0x11 / 255, green: 0x7a / 255, blue: 0x8b / 255)
	static let fullColor = Color(red: 0xdc / 255, green: 0x35 / 255, blue: 0x45 / 255)
	/// The free space above and below the pipe in the row, see `AccountUsageCard.row(_:)`.
	static let hoverMargin: CGFloat = 4

	var body: some View {
		VStack(spacing: 0) {
			half(usage?.sevenDay, color: Self.weekColor)
			half(usage?.fable, color: Self.fableColor)
		}
		.frame(height: 14)
		.background(Color.primary.opacity(0.12))
		.clipShape(Capsule())
		.overlay {
			VStack(spacing: 0) {
				hoverArea(Self.tooltip("Week", usage?.sevenDay, hasData: usage != nil, reset: usage?.resetsAt, now: now))
				hoverArea(Self.tooltip("Fable", usage?.fable, hasData: usage != nil, reset: usage?.resetsAt, now: now))
			}
			.padding(.vertical, -Self.hoverMargin)
		}
		.overlay(alignment: .topLeading) {
			GeometryReader { geometry in
				if let hover {
					bubble(hover.text)
						.offset(x: min(max(hover.x - bubbleWidth / 2, 0), max(geometry.size.width - bubbleWidth, 0)),
							y: -Self.hoverMargin - 20)
				}
			}
		}
	}

	/// A tooltip above the pipe at the pointer, inside the row.
	private func bubble(_ text: String) -> some View {
		Text(text)
			.font(.system(size: NSFont.smallSystemFontSize))
			.monospacedDigit()
			.fixedSize()
			.padding(.horizontal, 6)
			.padding(.vertical, 2)
			.background(RoundedRectangle(cornerRadius: 4).fill(.background))
			.overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.2)))
			.shadow(color: .black.opacity(0.2), radius: 2, y: 1)
			.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { bubbleWidth = $0 }
			.allowsHitTesting(false)
	}

	private func half(_ window: AccountUsage.Window?, color: Color) -> some View {
		GeometryReader { geometry in
			Rectangle()
				.fill((window?.percent ?? 0) >= 80 ? Self.fullColor : color)
				.frame(width: geometry.size.width * min(max((window?.percent ?? 0) / 100, 0), 1))
		}
	}

	private func hoverArea(_ text: String) -> some View {
		Rectangle()
			.fill(Color.clear)
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.contentShape(Rectangle())
			.onContinuousHover { phase in
				switch phase {
				case .active(let location): hover = (text, location.x)
				case .ended: if hover?.text == text { hover = nil }
				}
			}
	}

	/// For example »Week: 25 %«. A reset time that differs from `reset`, the time on the name line, is added.
	static func tooltip(_ title: String, _ window: AccountUsage.Window?, hasData: Bool, reset: Date?, now: Date) -> String {
		guard let window else { return hasData ? "No \(title) limit" : "\(title): no data yet" }
		var text = "\(title): \(Int(window.percent.rounded())) %"
		if let own = window.resetsAt, own != reset {
			text += ", reset in \(SessionCard.elapsed(from: now, to: own, largestUnitOnly: true))"
		}
		return text
	}
}
