import SwiftUI

/// The buttons of a report in the menu, side by side: update, or stop while it runs, and open. The view follows the
/// report, so a run that starts or ends while the menu is open changes it.
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
					Text("Open")
					if report.isUnread { Text("●").foregroundStyle(Color(nsColor: Spinner.reportColor)) }
				}
			}
			.disabled(!FileManager.default.fileExists(atPath: report.fileURL.path))
			Spacer(minLength: 0)
		}
		.controlSize(.small)
		.padding(.horizontal, 14)
		.padding(.vertical, 3)
	}

	private var updateTitle: String {
		report.isRunning ? isHovering ? Self.stopTitle : Self.updatingTitle
			: report.failure == nil ? "Update Now" : "Try Again"
	}
}
