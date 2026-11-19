import SwiftUI

/// The buttons of a report in the menu, side by side: update, or stop while it runs, open, and stats for a kind with a
/// stats file. The view follows the report, so a run that starts or ends while the menu is open changes it.
struct ReportButtons: View {
	static let updatingTitle = "Updating …"
	static let stopTitle = "Stop It!"
	static let updateID = "update"
	static let openID = "open"
	static let statsID = "stats"

	@ObservedObject var report: Report
	/// The button that the keys press, see ``MenuButtonsItem``.
	@ObservedObject var focus = MenuButtonFocus()
	/// Closes the menu after a click, like a menu item.
	var close: () -> Void
	@State private var isHovering = false

	var body: some View {
		HStack(spacing: 8) {
			Button(updateTitle, action: update)
				// The button of a running report says what a click does while the mouse or the ring is on it.
				.onHover { isHovering = $0 }
				.keyFocusRing(focus.buttonID == Self.updateID)
			Button(action: open) {
				HStack(spacing: 4) {
					// The main action of the group.
					Text("Open").fontWeight(.semibold)
					if report.isUnread { Text("●").foregroundStyle(Color(nsColor: Spinner.reportColor)) }
				}
			}
			.disabled(!canOpen)
			.keyFocusRing(focus.buttonID == Self.openID)
			if hasStats {
				Button("Stats", action: stats)
					.disabled(!canOpenStats)
					.keyFocusRing(focus.buttonID == Self.statsID)
			}
			Spacer(minLength: 0)
		}
		.controlSize(.small)
		.padding(.horizontal, 14)
		.padding(.vertical, 3)
	}

	/// The buttons from left to right, for the keys.
	var keyButtons: [MenuKeyButton] {
		[
			MenuKeyButton(id: Self.updateID, isEnabled: true, press: update),
			MenuKeyButton(id: Self.openID, isEnabled: canOpen, press: open),
		] + (hasStats ? [MenuKeyButton(id: Self.statsID, isEnabled: canOpenStats, press: stats)] : [])
	}

	private var hasStats: Bool { report.kind.statsFileName != nil }
	private var canOpen: Bool { Self.exists(report.fileURL) }
	private var canOpenStats: Bool { Self.exists(report.statsFileURL) }

	private func update() {
		if report.isRunning {
			report.stop()
		} else {
			Task { await report.update() }
		}
		close()
	}

	private func open() {
		report.openFile()
		close()
	}

	private func stats() {
		report.openStats()
		close()
	}

	private static func exists(_ file: URL?) -> Bool {
		file.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
	}

	private var updateTitle: String {
		report.isRunning ? isHovering || focus.buttonID == Self.updateID ? Self.stopTitle : Self.updatingTitle
			: report.failure == nil ? "Update Now" : "Try Again"
	}
}
