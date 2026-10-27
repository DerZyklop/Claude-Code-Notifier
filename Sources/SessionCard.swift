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
/// the app on the right. A button left of each row removes the session from the card, see ``SessionStore/hide(_:)``.
struct SessionCard: View {
	@ObservedObject var store: SessionStore
	@ObservedObject var setup: HookSetup
	@ObservedObject var clock: MenuClock
	/// The running ones get a row above the sessions. The card reads them again with each tick of the clock.
	var reports: [Report] = Report.all
	@State private var hoveredID: String?

	var body: some View {
		// A report has its own row, so its headless session stays out of the list.
		let sessions = store.sortedSessions.filter { !$0.isReport }
		let running = reports.filter(\.isRunning)
		let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
		VStack(spacing: 0) {
			header
			ForEach(Array(running.enumerated()), id: \.element.kind.notificationID) { index, report in
				if index > 0 { Divider().padding(.horizontal, 6) }
				reportRow(report)
			}
			if !running.isEmpty && !sessions.isEmpty { Divider().padding(.horizontal, 6) }
			if sessions.isEmpty && running.isEmpty {
				Text(store.hiddenStates.isEmpty ? "No Claude Code sessions yet" : "No sessions to show")
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
		.background(shape.fill(Color.primary.opacity(0.04)))
		.overlay(shape.strokeBorder(Color.primary.opacity(0.15)))
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
		HStack(alignment: .center, spacing: 8) {
			hideButton(session)
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
		.padding(.vertical, 3)
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

	/// A running report, with a purple hourglass like the wave during a report.
	private func reportRow(_ report: Report) -> some View {
		HStack(alignment: .center, spacing: 8) {
			// Keeps the icon in line with the icons of the sessions.
			Image(systemName: "xmark.circle.fill").hidden()
			Image(systemName: SessionState.working.symbol)
				.font(.system(size: 17, weight: .semibold))
				.foregroundStyle(Color(nsColor: Spinner.reportColor))
				.frame(width: 22, height: 22)
				.help("updating the report")
			Text(report.kind.title)
				.lineLimit(1)
			Spacer(minLength: 16)
			if let started = report.runStarted {
				Text(Self.elapsed(from: started, to: clock.now))
					.monospacedDigit()
					.foregroundStyle(.secondary)
			}
		}
		.padding(.horizontal, 6)
		.padding(.vertical, 3)
	}

	/// Faint, and clearer while the pointer is on the row.
	private func hideButton(_ session: Session) -> some View {
		Button {
			store.hide(session.id)
		} label: {
			Image(systemName: "xmark.circle.fill")
				.foregroundStyle(hoveredID == session.id ? .secondary : .quaternary)
		}
		.buttonStyle(.plain)
		.help("Remove from the list until the state changes")
	}

	/// The icon shows the state, its name is in the tooltip. A background task shows a gray hourglass with a blue
	/// badge.
	private func stateIcon(_ session: Session) -> some View {
		let state = session.shownState
		// Filled and a little heavier: a thin outline in color has too little contrast on the card.
		return Image(systemName: state.symbol)
			.font(.system(size: 17, weight: .semibold))
			.foregroundStyle(session.hasBackgroundTask ? Color.secondary : state.color)
			.frame(width: 22, height: 22)
			.overlay(alignment: .bottomTrailing) {
				if session.hasBackgroundTask {
					Circle()
						.fill(state.color)
						.frame(width: 8, height: 8)
						.offset(x: 1, y: 0)
				}
			}
			.help(session.stateTitle)
	}

	/// Seconds for the first minute (»58s«), a ticking clock for the first hour (»4:07«), then hours and minutes
	/// (»1h 09m«), then also days (»2d 4h 03m«).
	static func elapsed(from start: Date, to now: Date) -> String {
		let seconds = max(0, Int(now.timeIntervalSince(start)))
		let (days, hours, minutes) = (seconds / 86_400, seconds / 3600 % 24, seconds / 60 % 60)
		if days > 0 { return String(format: "%dd %dh %02dm", days, hours, minutes) }
		if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
		if minutes > 0 { return String(format: "%d:%02d", minutes, seconds % 60) }
		return "\(seconds)s"
	}
}

extension SessionState {
	/// The system green is too light on the light card and weak on the dark one. This green is darker in light mode
	/// and brighter in dark mode.
	var yourTurnGreen: NSColor {
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
