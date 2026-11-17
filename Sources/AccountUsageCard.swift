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
			ForEach(Array(Self.sorted(store.entries).enumerated()), id: \.element.id) { index, entry in
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
					.menuTooltip(entry.name)
				if entry.isSessionAccount {
					Text("VS Code")
						.font(.system(size: NSFont.smallSystemFontSize - 1, weight: .medium))
						.foregroundStyle(.secondary)
						.padding(.horizontal, 4)
						.background(Capsule().fill(Color.primary.opacity(0.1)))
						.menuTooltip("Claude Code in VS Code uses this account. Change it with /login in VS Code.")
				}
				Spacer(minLength: 8)
				Group {
					status(entry)
					if let reset = entry.usage?.resetsAt {
						Text(Self.resetText(reset, now: clock.now))
							.monospacedDigit()
							.foregroundStyle(.secondary)
							.menuTooltip("Resets \(reset.formatted(date: .abbreviated, time: .shortened))", alignment: .trailing)
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
				.menuTooltip(failure, alignment: .trailing)
		} else if entry.usage == nil {
			Text("Loading …").foregroundStyle(.secondary)
		}
	}

	/// The account of VS Code first, then the others by their reset time, the soonest first. An account without a reset
	/// time comes last. Accounts with the same reset time keep their order.
	static func sorted(_ entries: [AccountUsageEntry]) -> [AccountUsageEntry] {
		entries.enumerated().sorted { first, second in
			let (a, b) = (first.element, second.element)
			if a.isSessionAccount != b.isSessionAccount { return a.isSessionAccount }
			switch (a.usage?.resetsAt, b.usage?.resetsAt) {
			case let (x?, y?) where x != y: return x < y
			case (_?, nil): return true
			case (nil, _?): return false
			default: return first.offset < second.offset
			}
		}.map(\.element)
	}

	/// For example »Reset in 8d«.
	static func resetText(_ reset: Date, now: Date) -> String {
		"Reset in \(SessionCard.elapsed(from: now, to: reset, largestUnitOnly: true))"
	}
}

/// One rounded pipe for both weekly limits: the week fills the upper 2/3, Fable the lower 1/3, each from the left.
/// From 80 % on, a part is red. On hover, one tooltip shows both percentages. The hover area covers the full pipe, and
/// also the free space above and below it.
struct UsagePipe: View {
	let usage: AccountUsage?
	let now: Date

	/// Bootstrap 4 info, its darker hover color, and Bootstrap danger.
	static let weekColor = Color(red: 0x17 / 255, green: 0xa2 / 255, blue: 0xb8 / 255)
	static let fableColor = Color(red: 0x11 / 255, green: 0x7a / 255, blue: 0x8b / 255)
	static let fullColor = Color(red: 0xdc / 255, green: 0x35 / 255, blue: 0x45 / 255)
	/// The free space above and below the pipe in the row, see `AccountUsageCard.row(_:)`.
	static let hoverMargin: CGFloat = 4
	/// The week gets 2/3 of the height, Fable 1/3.
	static let weekHeight: CGFloat = 12
	static let fableHeight: CGFloat = 6

	var body: some View {
		VStack(spacing: 0) {
			part(usage?.sevenDay, color: Self.weekColor)
				.frame(height: Self.weekHeight)
			part(usage?.fable, color: Self.fableColor)
				.frame(height: Self.fableHeight)
		}
		.background(Color.primary.opacity(0.12))
		.clipShape(Capsule())
		.overlay {
			Rectangle()
				.fill(Color.clear)
				.contentShape(Rectangle())
				.menuTooltip(Self.tooltip(usage, now: now))
				.padding(.vertical, -Self.hoverMargin)
		}
	}

	private func part(_ window: AccountUsage.Window?, color: Color) -> some View {
		GeometryReader { geometry in
			Rectangle()
				.fill((window?.percent ?? 0) >= 80 ? Self.fullColor : color)
				.frame(width: geometry.size.width * min(max((window?.percent ?? 0) / 100, 0), 1))
		}
	}

	/// For example »Week: 25 %« and »Fable: 6 %« in two lines.
	static func tooltip(_ usage: AccountUsage?, now: Date) -> String {
		guard let usage else { return "No data yet" }
		return [tooltip("Week", usage.sevenDay, hasData: true, reset: usage.resetsAt, now: now),
			tooltip("Fable", usage.fable, hasData: true, reset: usage.resetsAt, now: now)].joined(separator: "\n")
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

/// The small box of a tooltip in the menu, see ``MenuTooltip``.
struct TooltipBubble: View {
	let text: String

	var body: some View {
		Text(text)
			.font(.system(size: NSFont.smallSystemFontSize))
			.monospacedDigit()
			.lineLimit(4)
			.frame(maxWidth: 280, alignment: .leading)
			.fixedSize(horizontal: false, vertical: true)
			.padding(.horizontal, 6)
			.padding(.vertical, 2)
			.background(RoundedRectangle(cornerRadius: 4).fill(.background))
			.overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.2)))
			.shadow(color: .black.opacity(0.2), radius: 2, y: 1)
			.fixedSize()
			.allowsHitTesting(false)
	}
}

/// A tooltip that also shows in the menu, where the system tooltip of `help(_:)` does not show. The bubble shows
/// above the view. It covers only the views that draw before it, so the view above must come earlier in its stack.
struct MenuTooltip: ViewModifier {
	let text: String
	var alignment: HorizontalAlignment = .leading
	@State private var isHovered = false

	func body(content: Content) -> some View {
		content
			.onHover { isHovered = $0 }
			.overlay(alignment: Alignment(horizontal: alignment, vertical: .top)) {
				if isHovered {
					TooltipBubble(text: text)
						.alignmentGuide(.top) { $0[.bottom] + 2 }
				}
			}
	}
}

extension View {
	func menuTooltip(_ text: String, alignment: HorizontalAlignment = .leading) -> some View {
		modifier(MenuTooltip(text: text, alignment: alignment))
	}
}
