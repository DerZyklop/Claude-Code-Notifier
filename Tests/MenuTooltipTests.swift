import AppKit
import SwiftUI
import Testing
@testable import ClaudeCodeNotifier

@MainActor @Suite struct MenuTooltipTests {
	private func size(_ text: String) -> CGSize {
		NSHostingView(rootView: TooltipBubble(text: text)).fittingSize
	}

	@Test func aLongTextWrapsIntoMoreLines() {
		let short = size("Week: 25 %")
		let long = size("Claude Code in VS Code uses this account. Change it with /login in VS Code.")
		#expect(long.width <= TooltipBubble.maxWidth + 12)
		#expect(long.width > short.width)
		#expect(long.height > short.height * 1.5)
	}

	@Test func eachLineGetsItsHeight() {
		#expect(size("Week: 25 %\nFable: 6 %").height > size("Week: 25 %").height * 1.5)
	}

	@Test func showsAboveTheViewOrBelowItAtTheTopOfTheScreen() {
		let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
		let size = CGSize(width: 100, height: 30)
		let anchor = CGRect(x: 200, y: 500, width: 50, height: 10)
		#expect(TooltipPanel.frame(size: size, anchor: anchor, alignsTrailing: false, screen: screen)
			== CGRect(x: 200, y: 512, width: 100, height: 30))
		#expect(TooltipPanel.frame(size: size, anchor: anchor, alignsTrailing: true, screen: screen).minX == 150)
		let top = CGRect(x: 200, y: 780, width: 50, height: 10)
		#expect(TooltipPanel.frame(size: size, anchor: top, alignsTrailing: false, screen: screen).maxY == 778)
	}

	@Test func staysOnTheScreen() {
		let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
		let size = CGSize(width: 300, height: 30)
		#expect(TooltipPanel.frame(size: size, anchor: CGRect(x: 900, y: 100, width: 50, height: 10), alignsTrailing: false, screen: screen).maxX == 1000)
		#expect(TooltipPanel.frame(size: size, anchor: CGRect(x: 10, y: 100, width: 50, height: 10), alignsTrailing: true, screen: screen).minX == 0)
	}
}
