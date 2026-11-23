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
/// the app on the right. With sessions of more than one project, a subheadline names the project above its sessions. On hover, a button in place of the state icon removes the session from the card, see ``SessionStore/hide(_:)``, and a check box at the end of the row marks the session as important, see ``Session/holdsRing``. The check box of an important session always shows. A click on a row opens the chat of the session in VS Code. Each row has a wave between its texts, see ``RowWave``: green while the session works, purple for a report, else still.
/// The card is a stack of menu items, one for each ``Part``, so that the arrow keys reach each session, see
/// ``SessionCardItems``. This view shows the part at one place of the stack.
struct SessionCard: View {
	@ObservedObject var model: SessionCardModel
	/// The place of the part in ``SessionCardModel/parts``.
	let slot: Int
	@ObservedObject var setup: HookSetup
	@ObservedObject var clock: MenuClock
	/// Opens the chat of the session, see ``VSCodeWindows/open(_:)``.
	var open: (Session) -> Void = { _ in }
	/// Removes the session from the card, see ``SessionStore/hide(_:)``.
	var hide: (Session) -> Void = { _ in }
	/// Marks the session as important or removes the mark, see ``SessionStore/toggleImportant(_:)``.
	var toggleImportant: (Session) -> Void = { _ in }
	/// Whether the pointer is on the menu item.
	@State private var isHovered = false

	/// One menu item of the card.
	struct Part: Equatable {
		enum Content: Equatable {
			case header
			/// A running report.
			case report(title: String, started: Date?)
			/// The text in place of the rows, without sessions and reports.
			case empty(hasHidden: Bool)
			case headline(project: String, isFirst: Bool)
			case session(Session)
		}

		var content: Content
		/// A line above the part, between two rows.
		var hasDivider = false
		/// The last part has the bottom edge of the card.
		var isLast = false

		var session: Session? {
			if case .session(let session) = content { session } else { nil }
		}

		/// Whether the view of the part is as high as the one of `other`.
		func hasHeight(of other: Part) -> Bool {
			guard hasDivider == other.hasDivider, isLast == other.isLast else { return false }
			switch (content, other.content) {
			case (.header, .header), (.report, .report), (.empty, .empty), (.session, .session): return true
			case (.headline(_, let isFirst), .headline(_, let otherIsFirst)): return isFirst == otherIsFirst
			default: return false
			}
		}
	}

	/// The parts of the card from the top: the header, the running reports, then the sessions by ``groups(_:order:)``.
	/// `running` has the title and the start of each running report.
	static func parts(sessions: [Session], order: [String] = [], running: [(title: String, started: Date?)] = [],
		hasHidden: Bool = false) -> [Part] {
		var parts = [Part(content: .header)]
		for (index, report) in running.enumerated() {
			parts.append(Part(content: .report(title: report.title, started: report.started), hasDivider: index > 0))
		}
		if sessions.isEmpty && running.isEmpty { parts.append(Part(content: .empty(hasHidden: hasHidden))) }
		let groups = groups(sessions, order: order)
		// The line between the reports and the sessions.
		var needsDivider = !running.isEmpty
		for group in groups {
			if groups.count > 1 {
				let isFirst = group.project == groups.first?.project && running.isEmpty
				parts.append(Part(content: .headline(project: group.project, isFirst: isFirst), hasDivider: needsDivider))
				needsDivider = false
			}
			for (index, session) in group.sessions.enumerated() {
				parts.append(Part(content: .session(session), hasDivider: index > 0 || needsDivider))
				needsDivider = false
			}
		}
		parts[parts.count - 1].isLast = true
		return parts
	}

	var body: some View {
		// An item that the menu removes next has no part.
		if model.parts.indices.contains(slot) {
			let part = model.parts[slot]
			VStack(spacing: 0) {
				if part.hasDivider { Divider().padding(.horizontal, 6) }
				content(part.content)
			}
			.cardPart(isFirst: slot == 0, isLast: part.isLast)
			// The menu highlights the full item, so the full item takes the click.
			.contentShape(Rectangle())
			.onTapGesture { if let session = part.session { open(session) } }
			.onHover { isHovered = $0 }
		}
	}

	@ViewBuilder
	private func content(_ content: Part.Content) -> some View {
		switch content {
		case .header:
			header
		case .report(let title, let started):
			reportRow(title: title, started: started)
		case .empty(let hasHidden):
			Text(hasHidden ? "No sessions to show" : "No Claude Code sessions yet")
				.foregroundStyle(.secondary)
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.horizontal, 6)
				.padding(.vertical, 4)
		case .headline(let project, let isFirst):
			projectHeadline(project, isFirst: isFirst)
		case .session(let session):
			row(session)
		}
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

	/// The sessions by ``Session/project``. The groups with an important session come first. Then the groups have the
	/// order of `order`, then the order of their first session. Each group keeps the order of `sessions`.
	static func groups(_ sessions: [Session], order: [String] = []) -> [(project: String, sessions: [Session])] {
		var groups: [(project: String, sessions: [Session])] = []
		for session in sessions {
			if let index = groups.firstIndex(where: { $0.project == session.project }) {
				groups[index].sessions.append(session)
			} else {
				groups.append((session.project, [session]))
			}
		}
		let pin = { (group: (project: String, sessions: [Session])) in group.sessions.contains(where: \.isImportant) ? 0 : 1 }
		let rank = { (project: String) in order.firstIndex(of: project) ?? order.count }
		return groups.enumerated().sorted {
			(pin($0.element), rank($0.element.project), $0.offset) < (pin($1.element), rank($1.element.project), $1.offset)
		}.map(\.element)
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

	/// Whether the row of a session shows the highlight. The menu highlights the item for the pointer and for the arrow
	/// keys. A press of the mouse removes that highlight, so the pointer alone counts while the menu highlights no item.
	private var isHighlighted: Bool {
		model.highlightedSlot == slot || isHovered && !model.hasHighlight
	}

	private func row(_ session: Session) -> some View {
		HStack(alignment: .center, spacing: 8) {
			// Not while the arrow keys highlight another item.
			if isHovered && isHighlighted {
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
			Text(Self.elapsed(from: session.interacted ?? session.started, to: clock.now))
				.monospacedDigit()
				.foregroundStyle(.secondary)
				.fixedSize()
				.menuTooltip(Self.timeTooltip(session, now: clock.now), alignment: .trailing)
			if session.isImportant || isHovered && isHighlighted { importantButton(session) }
		}
		.padding(.horizontal, 6)
		.padding(.vertical, 3)
		.background(
			RoundedRectangle(cornerRadius: 5, style: .continuous)
				.fill(Color.primary.opacity(isHighlighted ? 0.07 : 0))
		)
	}

	/// A running report, with a purple hourglass and a purple wave like the menu bar during a report.
	private func reportRow(title: String, started: Date?) -> some View {
		HStack(alignment: .center, spacing: 8) {
			Image(systemName: SessionState.working.symbol)
				.rowIcon()
				.foregroundStyle(Color(nsColor: Spinner.reportColor))
				.help("updating the report")
			Text(title)
				.lineLimit(1)
			wave(color: Spinner.reportColor)
			if let started {
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

	/// Takes the place of the state icon while the pointer is on the highlighted item, with the same size.
	private func hideButton(_ session: Session) -> some View {
		Button {
			hide(session)
		} label: {
			Image(systemName: "xmark.circle.fill")
				.rowIcon()
				.foregroundStyle(.red)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.help("Remove from the list until the state changes (now: \(session.stateTitle))")
	}

	/// The check box of an important session, at the end of the row. It shifts the time to the left.
	private func importantButton(_ session: Session) -> some View {
		Toggle("Important", isOn: Binding(get: { session.isImportant }, set: { _ in toggleImportant(session) }))
			.toggleStyle(.checkbox)
			.labelsHidden()
			.fixedSize()
			.help(session.isImportant ? "Important: the red lights stay on while it waits for you. Click to remove the mark."
			: "Mark as important: the red lights stay on while it waits for you")
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

	/// The tooltip of the time: what the time counts from, and how long ago the session started.
	static func timeTooltip(_ session: Session, now: Date) -> String {
		let started = "Started \(elapsed(from: session.started, to: now)) ago"
		return session.interacted == nil ? started : "Since your last input. \(started)."
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

	/// One part of a bordered card that is a stack of menu items, like ``SessionCard``. The parts touch, and together
	/// they look like one ``menuCard()``. The part fills its menu item.
	func cardPart(isFirst: Bool, isLast: Bool) -> some View {
		let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
		// The shape reaches beyond each side of the part that is no edge of the card. So only the other sides show.
		let overhang: CGFloat = 24
		let beyond = EdgeInsets(top: isFirst ? 0 : -overhang, leading: 0, bottom: isLast ? 0 : -overhang, trailing: 0)
		return padding(.horizontal, 4)
			.padding(.top, isFirst ? 4 : 0)
			.padding(.bottom, isLast ? 4 : 0)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
			.background(shape.fill(Color.primary.opacity(0.04)).padding(beyond).clipped())
			.overlay(shape.strokeBorder(Color.primary.opacity(0.15)).padding(beyond).clipped().allowsHitTesting(false))
			.padding(.horizontal, 10)
			.padding(.top, isFirst ? 4 : 0)
			.padding(.bottom, isLast ? 4 : 0)
			.font(.system(size: NSFont.systemFontSize))
			.frame(minWidth: 300)
	}

	/// The bordered card of a menu item, like ``AccountUsageCard``.
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

