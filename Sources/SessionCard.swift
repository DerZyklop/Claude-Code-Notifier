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
			// Filled and a little heavier: a thin outline in color has too little contrast on the card.
			Image(systemName: session.stateSymbol)
				.fontWeight(.semibold)
				.foregroundStyle(session.shownState.color)
				.frame(width: 16)
			Text(session.name)
				.lineLimit(1)
				.truncationMode(.tail)
				.frame(maxWidth: 260, alignment: .leading)
				.help(session.project)
			Text(session.stateTitle)
				.foregroundStyle(.secondary)
				.lineLimit(1)
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

	/// A running clock: »4:07«, or »1:04:07« from one hour on.
	private static func elapsed(from start: Date, to now: Date) -> String {
		let seconds = max(0, Int(now.timeIntervalSince(start)))
		let (hours, minutes, rest) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
		return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
	}
}

private extension SessionState {
	var color: Color {
		switch self {
		case .asksYou: .orange
		case .yourTurn: .green
		case .working: .accentColor
		case .ended: .secondary
		}
	}
}
