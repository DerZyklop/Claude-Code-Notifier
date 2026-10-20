import SwiftUI

/// Ticks every second while the menu is open, for the running times in ``SessionCard``.
@MainActor
final class MenuClock: ObservableObject {
	@Published private(set) var now = Date()

	func tick() {
		now = Date()
	}
}

/// The sessions in the menu: a bordered card with a header and one row per session. The header names the status of
/// the app on the right. The card only shows information.
struct SessionCard: View {
	@ObservedObject var store: SessionStore
	@ObservedObject var setup: HookSetup
	@ObservedObject var clock: MenuClock
	@State private var hoveredID: String?

	var body: some View {
		let sessions = store.sortedSessions
		VStack(spacing: 0) {
			header
			if sessions.isEmpty {
				Text("No Claude Code sessions yet")
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(.horizontal, 6)
					.padding(.vertical, 4)
			}
			ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
				if index > 0 { Divider().padding(.horizontal, 6) }
				row(session)
			}
		}
		.padding(4)
		.background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
		.overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
		.padding(.horizontal, 10)
		.padding(.vertical, 4)
		.font(.system(size: NSFont.systemFontSize))
		.frame(minWidth: 300)
	}

	private var header: some View {
		HStack(spacing: 4) {
			Text("Sessions")
				.fontWeight(.semibold)
				.foregroundStyle(.secondary)
			Spacer(minLength: 16)
			if let problem = setup.problem {
				Image(systemName: "exclamationmark.triangle.fill")
					.foregroundStyle(.orange)
				Text(problem)
					.foregroundStyle(.orange)
			} else {
				Circle().fill(.green).frame(width: 6, height: 6)
				Text("Listening on 127.0.0.1:\(String(eventPort))")
					.foregroundStyle(.secondary)
			}
		}
		.font(.system(size: NSFont.smallSystemFontSize))
		.padding(.horizontal, 6)
		.padding(.top, 3)
		.padding(.bottom, 5)
	}

	private func row(_ session: Session) -> some View {
		HStack(spacing: 7) {
			stateIcon(session)
			Text(session.name)
				.lineLimit(1)
				.truncationMode(.tail)
				.frame(maxWidth: 300, alignment: .leading)
				.help(session.project)
			Spacer(minLength: 16)
			Text(Self.elapsed(from: session.started, to: clock.now))
				.monospacedDigit()
				.foregroundStyle(.secondary)
		}
		.padding(.horizontal, 6)
		.padding(.vertical, 4)
		.background(
			RoundedRectangle(cornerRadius: 5, style: .continuous)
				.fill(Color.primary.opacity(hoveredID == session.id ? 0.07 : 0))
		)
		.contentShape(Rectangle())
		.onHover { isHovered in
			if isHovered {
				hoveredID = session.id
			} else if hoveredID == session.id {
				hoveredID = nil
			}
		}
	}

	/// The icon shows the state, its name is in the tooltip. A background task adds a small dot to the hourglass.
	private func stateIcon(_ session: Session) -> some View {
		let state = session.shownState
		// Filled and a little heavier: a thin outline in color has too little contrast on the card.
		return Image(systemName: state.symbol)
			.fontWeight(.semibold)
			.foregroundStyle(state.color)
			.frame(width: 16)
			.overlay(alignment: .bottomTrailing) {
				if session.hasBackgroundTask {
					Circle()
						.fill(state.color)
						.frame(width: 5, height: 5)
						.offset(x: 1, y: 1)
				}
			}
			.help(session.stateTitle)
	}

	/// Seconds for the first minute (»58s«), a ticking clock for the first hour (»4:07«), then hours and minutes
	/// (»1h 09m«), then also days (»2d 4h 03m«).
	private static func elapsed(from start: Date, to now: Date) -> String {
		let seconds = max(0, Int(now.timeIntervalSince(start)))
		let (days, hours, minutes) = (seconds / 86_400, seconds / 3600 % 24, seconds / 60 % 60)
		if days > 0 { return String(format: "%dd %dh %02dm", days, hours, minutes) }
		if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
		if minutes > 0 { return String(format: "%d:%02d", minutes, seconds % 60) }
		return "\(seconds)s"
	}
}

private extension SessionState {
	/// The system green is too light on the light card and weak on the dark one. This green is darker in light mode
	/// and brighter in dark mode.
	private var yourTurnGreen: NSColor {
		NSColor(name: nil) { appearance in
			appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
				? NSColor(srgbRed: 0.30, green: 0.87, blue: 0.45, alpha: 1)
				: NSColor(srgbRed: 0.10, green: 0.56, blue: 0.24, alpha: 1)
		}
	}

	var color: Color {
		switch self {
		case .asksYou: .orange
		case .yourTurn: Color(nsColor: yourTurnGreen)
		case .working: .accentColor
		case .ended: .secondary
		}
	}
}
