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
/// the app on the right. With sessions of more than one project, a subheadline names the project above its sessions. On hover, a button in place of the state icon removes the session from the card, see ``SessionStore/hide(_:)``.
struct SessionCard: View {
	@ObservedObject var store: SessionStore
	@ObservedObject var setup: HookSetup
	@ObservedObject var clock: MenuClock
	/// The running ones get a row above the sessions. The card reads them again with each tick of the clock.
	var reports: [Report] = Report.all
	@State private var hoveredID: String?

	var body: some View {
		let sessions = store.sortedSessions
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
			let groups = Self.groups(sessions)
			ForEach(groups, id: \.project) { group in
				if groups.count > 1 { projectHeadline(group.project, isFirst: group.project == groups.first?.project && running.isEmpty) }
				ForEach(Array(group.sessions.enumerated()), id: \.element.id) { index, session in
					if index > 0 { Divider().padding(.horizontal, 6) }
					row(session)
				}
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

	/// The sessions by ``Session/project``. The groups have the order of their first session, and each group keeps
	/// the order of `sessions`.
	static func groups(_ sessions: [Session]) -> [(project: String, sessions: [Session])] {
		var groups: [(project: String, sessions: [Session])] = []
		for session in sessions {
			if let index = groups.firstIndex(where: { $0.project == session.project }) {
				groups[index].sessions.append(session)
			} else {
				groups.append((session.project, [session]))
			}
		}
		return groups
	}

	/// Small like the header. Below the header or a row, it gets more space above.
	private func projectHeadline(_ project: String, isFirst: Bool) -> some View {
		Text(project)
			.font(.system(size: NSFont.smallSystemFontSize, weight: .semibold))
			.foregroundStyle(.secondary)
			.lineLimit(1)
			.truncationMode(.tail)
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.horizontal, 6)
			.padding(.top, isFirst ? 2 : 8)
			.padding(.bottom, 2)
	}

	private func row(_ session: Session) -> some View {
		HStack(alignment: .center, spacing: 8) {
			if hoveredID == session.id {
				hideButton(session)
			} else {
				stateIcon(session)
			}
			Text(session.name)
				.lineLimit(1)
				.truncationMode(.tail)
				.frame(maxWidth: 300, alignment: .leading)
				.help(session.project)
			Spacer(minLength: 16)
			if !session.agents.isEmpty { agentCount(session.agents.count) }
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
			Image(systemName: SessionState.working.symbol)
				.rowIcon()
				.foregroundStyle(Color(nsColor: Spinner.reportColor))
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

	/// The subagents that run for the session. The menu bar counts the session only once.
	private func agentCount(_ count: Int) -> some View {
		HStack(spacing: 2) {
			Image(systemName: "person.2.fill")
			Text("\(count)").monospacedDigit()
		}
		.font(.system(size: NSFont.smallSystemFontSize, weight: .semibold))
		.foregroundStyle(.secondary)
		.help(count == 1 ? "1 subagent runs" : "\(count) subagents run")
	}

	/// Takes the place of the state icon while the pointer is on the row, with the same size.
	private func hideButton(_ session: Session) -> some View {
		Button {
			store.hide(session.id)
		} label: {
			Image(systemName: "xmark.circle.fill")
				.rowIcon()
				.foregroundStyle(.red)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.help("Remove from the list until the state changes (now: \(session.stateTitle))")
	}

	/// The icon shows the state, its name is in the tooltip. A background task shows a gray hourglass with a blue
	/// badge.
	private func stateIcon(_ session: Session) -> some View {
		let state = session.shownState
		// Filled and a little heavier: a thin outline in color has too little contrast on the card.
		return Image(systemName: state.symbol)
			.rowIcon()
			.foregroundStyle(session.hasBackgroundTask ? Color.secondary : state.color)
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

private extension Image {
	/// The icon at the start of a row. All rows use this size, so that their texts line up.
	func rowIcon() -> some View {
		font(.system(size: 17, weight: .semibold)).frame(width: 22, height: 22)
	}
}
