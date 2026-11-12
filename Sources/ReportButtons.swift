import SwiftUI

/// The buttons of a report in the menu, side by side: update, or stop while it runs, open, and stats for a kind with a
/// stats file. The view follows the report, so a run that starts or ends while the menu is open changes it.
struct ReportButtons: View {
	static let updatingTitle = "Updating …"
	static let stopTitle = "Stop It!"

	@ObservedObject var report: Report
	/// Closes the menu after a click, like a menu item.
	var close: () -> Void
	@State private var isHovering = false

	var body: some View {
		HStack(spacing: 8) {
			Button(updateTitle) {
				if report.isRunning {
					report.stop()
				} else {
					Task { await report.update() }
				}
				close()
			}
			// The button of a running report says what a click does while the mouse is on it.
			.onHover { isHovering = $0 }
			Button {
				report.openFile()
				close()
			} label: {
				HStack(spacing: 4) {
					// The main action of the group.
					Text("Open").fontWeight(.semibold)
					if report.isUnread { Text("●").foregroundStyle(Color(nsColor: Spinner.reportColor)) }
				}
			}
			.disabled(!Self.exists(report.fileURL))
			if report.kind.statsFileName != nil {
				Button("Stats") {
					report.openStats()
					close()
				}
				.disabled(!Self.exists(report.statsFileURL))
			}
			Spacer(minLength: 0)
		}
		.controlSize(.small)
		.padding(.horizontal, 14)
		.padding(.vertical, 3)
	}

	private static func exists(_ file: URL?) -> Bool {
		file.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
	}

	private var updateTitle: String {
		report.isRunning ? isHovering ? Self.stopTitle : Self.updatingTitle
			: report.failure == nil ? "Update Now" : "Try Again"
	}
}
