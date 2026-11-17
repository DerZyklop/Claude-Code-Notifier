import AppKit
import SwiftUI

extension View {
	/// A tooltip that also shows in the menu, where the system tooltip of `help(_:)` does not show. The bubble is a
	/// window of its own above the view, so the menu does not clip it, and it gets the size of its text. Near the top
	/// of the screen, it shows below the view.
	func menuTooltip(_ text: String, alignment: HorizontalAlignment = .leading) -> some View {
		background(TooltipAnchor(text: text, alignsTrailing: alignment == .trailing))
	}
}

/// The box of a tooltip: the text wraps at ``maxWidth``.
struct TooltipBubble: View {
	static let maxWidth: CGFloat = 280
	let text: String

	var body: some View {
		WrappingWidth(maxWidth: Self.maxWidth) {
			Text(text)
				.font(.system(size: NSFont.smallSystemFontSize))
				.monospacedDigit()
		}
		.padding(.horizontal, 6)
		.padding(.vertical, 3)
		.background(RoundedRectangle(cornerRadius: 4).fill(.background))
		.overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.2)))
	}
}

/// Gives its view `maxWidth` and takes the size that the view needs in it, for any proposal. A text gets the width
/// of its longest line.
private struct WrappingWidth: Layout {
	let maxWidth: CGFloat

	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		subviews.first?.sizeThatFits(.init(width: maxWidth, height: nil)) ?? .zero
	}

	func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
		subviews.first?.place(at: bounds.origin, proposal: .init(width: bounds.width, height: bounds.height))
	}
}

/// An empty view behind the view of the tooltip. It shows ``TooltipPanel`` while the pointer is in its frame.
private struct TooltipAnchor: NSViewRepresentable {
	let text: String
	let alignsTrailing: Bool

	func makeNSView(context: Context) -> TooltipAnchorView { TooltipAnchorView() }

	func updateNSView(_ view: TooltipAnchorView, context: Context) {
		view.text = text
		view.alignsTrailing = alignsTrailing
	}
}

final class TooltipAnchorView: NSView {
	var text = "" {
		didSet { if isHovered && text != oldValue { TooltipPanel.shared.show(text, at: self) } }
	}
	var alignsTrailing = false
	private var isHovered = false

	override func hitTest(_ point: NSPoint) -> NSView? { nil }

	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		trackingAreas.forEach(removeTrackingArea)
		addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
	}

	override func mouseEntered(with event: NSEvent) {
		isHovered = true
		TooltipPanel.shared.show(text, at: self)
	}

	override func mouseExited(with event: NSEvent) {
		isHovered = false
		TooltipPanel.shared.hide(from: self)
	}

	override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		if window == nil, isHovered {
			isHovered = false
			TooltipPanel.shared.hide(from: self)
		}
	}
}

/// The one window that shows the tooltip of the menu. It is above the menu and ignores the mouse. It closes with the
/// menu.
@MainActor
final class TooltipPanel {
	static let shared = TooltipPanel()
	/// The space between the view and the bubble.
	static let gap: CGFloat = 2

	private let panel: NSPanel
	private let hostingView = NSHostingView(rootView: TooltipBubble(text: ""))
	private weak var anchor: NSView?

	private init() {
		panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
		panel.isOpaque = false
		panel.backgroundColor = .clear
		panel.hasShadow = true
		panel.ignoresMouseEvents = true
		panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
		panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
		panel.contentView = hostingView
		NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { _ in
			MainActor.assumeIsolated { TooltipPanel.shared.hide() }
		}
	}

	func show(_ text: String, at view: TooltipAnchorView) {
		guard let window = view.window, !text.isEmpty else { return hide() }
		anchor = view
		hostingView.rootView = TooltipBubble(text: text)
		panel.appearance = window.effectiveAppearance
		let size = hostingView.fittingSize
		let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
		panel.setFrame(Self.frame(size: size, anchor: rect, alignsTrailing: view.alignsTrailing,
			screen: (window.screen ?? NSScreen.main)?.visibleFrame), display: true)
		panel.invalidateShadow()
		panel.orderFrontRegardless()
	}

	/// Hides the tooltip, but only if it belongs to `view`, or always without a view.
	func hide(from view: NSView? = nil) {
		guard view == nil || view === anchor else { return }
		anchor = nil
		panel.orderOut(nil)
	}

	/// Above the anchor, or below it without space above. On the left edge of the anchor, or on its right edge. The
	/// frame stays on the screen.
	static func frame(size: CGSize, anchor: CGRect, alignsTrailing: Bool, screen: CGRect?) -> CGRect {
		var frame = CGRect(origin: CGPoint(x: alignsTrailing ? anchor.maxX - size.width : anchor.minX, y: anchor.maxY + gap), size: size)
		guard let screen else { return frame }
		if frame.maxY > screen.maxY { frame.origin.y = anchor.minY - gap - size.height }
		frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - size.width)
		return frame
	}
}
