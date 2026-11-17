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
/// the app on the right. With sessions of more than one project, a subheadline names the project above its sessions. On hover, a button in place of the state icon removes the session from the card, see ``SessionStore/hide(_:)``. A click on a row opens the chat of the session in VS Code. Each row has a wave between its texts, see ``RowWave``: green while the session works, purple for a report, else still.
struct SessionCard: View {
	@ObservedObject var store: SessionStore
	@ObservedObject var setup: HookSetup
	@ObservedObject var clock: MenuClock
	/// The running ones get a row above the sessions. The card reads them again with each tick of the clock.
	var reports: [Report] = Report.all
	/// Opens the chat of the session, see ``VSCodeWindows/open(_:)``.
	var open: (Session) -> Void = { _ in }
	@State private var hoveredID: String?

	var body: some View {
		let sessions = store.sortedSessions
		let running = reports.filter(\.isRunning)
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
			let groups = Self.groups(sessions, order: store.projectOrder)
			ForEach(groups, id: \.project) { group in
				if groups.count > 1 { projectHeadline(group.project, isFirst: group.project == groups.first?.project && running.isEmpty) }
				ForEach(Array(group.sessions.enumerated()), id: \.element.id) { index, session in
					if index > 0 { Divider().padding(.horizontal, 6) }
					row(session)
				}
			}
		}
		.menuCard()
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

	/// The sessions by ``Session/project``. The groups have the order of `order`, then the order of their first session.
	/// Each group keeps the order of `sessions`.
	static func groups(_ sessions: [Session], order: [String] = []) -> [(project: String, sessions: [Session])] {
		var groups: [(project: String, sessions: [Session])] = []
		for session in sessions {
			if let index = groups.firstIndex(where: { $0.project == session.project }) {
				groups[index].sessions.append(session)
			} else {
				groups.append((session.project, [session]))
			}
		}
		let rank = { (project: String) in order.firstIndex(of: project) ?? order.count }
		return groups.enumerated().sorted { (rank($0.element.project), $0.offset) < (rank($1.element.project), $1.offset) }.map(\.element)
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
				.help(session.project)
				.ownWidth(upTo: 300)
				// The name gets its room before the wave, and is the only part of the row that gets shorter.
				.layoutPriority(1)
			wave(color: session.shownState == .working ? Spinner.color : nil)
			if !session.agents.isEmpty { agentCount(session.agents.count) }
			Text(Self.elapsed(from: session.started, to: clock.now))
				.monospacedDigit()
				.foregroundStyle(.secondary)
				.fixedSize()
		}
		.padding(.horizontal, 6)
		.padding(.vertical, 3)
		.background(
			RoundedRectangle(cornerRadius: 5, style: .continuous)
				.fill(Color.primary.opacity(hoveredID == session.id ? 0.07 : 0))
		)
		.contentShape(Rectangle())
		.onTapGesture { open(session) }
		.onHover { isHovered in
			if isHovered {
				hoveredID = session.id
			} else if hoveredID == session.id {
				hoveredID = nil
			}
		}
	}

	/// A running report, with a purple hourglass and a purple wave like the menu bar during a report.
	private func reportRow(_ report: Report) -> some View {
		HStack(alignment: .center, spacing: 8) {
			Image(systemName: SessionState.working.symbol)
				.rowIcon()
				.foregroundStyle(Color(nsColor: Spinner.reportColor))
				.help("updating the report")
			Text(report.kind.title)
				.lineLimit(1)
			wave(color: Spinner.reportColor)
			if let started = report.runStarted {
				Text(Self.elapsed(from: started, to: clock.now))
					.monospacedDigit()
					.foregroundStyle(.secondary)
					.fixedSize()
			}
		}
		.padding(.horizontal, 6)
		.padding(.vertical, 3)
	}

	/// The wave between the texts on the left and on the right of a row: moving in `color`, or still for `nil`.
	private func wave(color: NSColor?) -> some View {
		RowWave(color: color)
			.frame(minWidth: 16, maxWidth: .infinity)
			.frame(height: RowWaveView.height)
	}

	/// The subagents that run for the session. The menu bar counts the session only once.
	private func agentCount(_ count: Int) -> some View {
		HStack(spacing: 2) {
			Image(systemName: "person.2.fill")
			Text("\(count)").monospacedDigit()
		}
		.font(.system(size: NSFont.smallSystemFontSize, weight: .semibold))
		.foregroundStyle(.secondary)
		.fixedSize()
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

	/// The icon shows the state, its name is in the tooltip. A background task shows a gray hourglass with a badge
	/// in the text color.
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

	/// Two units at most, fewer for a longer time: »01s«, »03m 22s«, »2h 20m«, »2d 2h«, then from 3 days only days
	/// (»3d«), and from 7 days only weeks (»1w«).
	/// With `largestUnitOnly`, only the largest unit, rounded down, for a time far away: »8d«, »23h«, »59m«. Below 2 of
	/// the unit, it has one decimal: »1.4d«, »1.9h«. A time below 1 minute is »1m«.
	static func elapsed(from start: Date, to now: Date, largestUnitOnly: Bool = false) -> String {
		let interval = max(0, now.timeIntervalSince(start))
		if largestUnitOnly {
			for (unit, size) in [("d", 86_400.0), ("h", 3600.0)] where interval >= size {
				let value = interval / size
				let number = value >= 2 ? String(Int(value)) : String(format: "%.1f", (value * 10).rounded(.down) / 10)
				return (number.hasSuffix(".0") ? String(number.dropLast(2)) : number) + unit
			}
			return "\(max(1, Int(interval / 60)))m"
		}
		let seconds = Int(interval)
		let (days, hours, minutes) = (seconds / 86_400, seconds / 3600 % 24, seconds / 60 % 60)
		if days >= 7 { return "\(days / 7)w" }
		if days >= 3 { return "\(days)d" }
		if days > 0 { return "\(days)d \(hours)h" }
		if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
		if minutes > 0 { return String(format: "%02dm %02ds", minutes, seconds % 60) }
		return String(format: "%02ds", seconds)
	}
}

extension SessionState {
	var color: Color {
		switch self {
		case .asksYou: .orange
		case .yourTurn: .white
		// The green wave of the row shows the work, so the icon keeps the text color.
		case .working: .primary
		}
	}
}

/// Gives its view the width that the view asks for, but at most `maxWidth` and at most the width that the row offers.
private struct OwnWidth: Layout {
	let maxWidth: CGFloat

	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		guard let view = subviews.first else { return .zero }
		let ideal = view.sizeThatFits(.unspecified)
		return CGSize(width: min(ideal.width, maxWidth, proposal.width ?? .infinity), height: ideal.height)
	}

	func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
		subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
	}
}

extension View {
	/// Takes only its own width, up to `maxWidth`, and gets narrower when the row has less room.
	func ownWidth(upTo maxWidth: CGFloat) -> some View {
		OwnWidth(maxWidth: maxWidth) { self }
	}

	/// The bordered card of a menu item, like ``SessionCard``.
	func menuCard() -> some View {
		let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
		return padding(4)
			.background(shape.fill(Color.primary.opacity(0.04)))
			.overlay(shape.strokeBorder(Color.primary.opacity(0.15)))
			.padding(.horizontal, 10)
			.padding(.vertical, 4)
			.font(.system(size: NSFont.systemFontSize))
			.frame(minWidth: 300)
	}
}

private extension Image {
	/// The icon at the start of a row. All rows use this size, so that their texts line up.
	func rowIcon() -> some View {
		font(.system(size: 17, weight: .semibold)).frame(width: 22, height: 22)
	}
}
