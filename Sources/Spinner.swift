import AppKit
import Combine

/// The menu bar spinner while sessions work: an arc that turns around a ring. In the middle, a sparkle for one working
/// session, or the number of working sessions.
@MainActor
final class Spinner: ObservableObject {
	static let shared = Spinner()

	private static let frameCount = 12
	private static let frameInterval = 0.1
	private static let color = NSColor.systemOrange

	@Published private(set) var frame = 0

	private var timer: Timer?
	private var subscription: AnyCancellable?
	private var cache: [String: NSImage] = [:]

	private init() {
		// The timer runs only while a session works.
		subscription = SessionStore.shared.$sessions
			.map { sessions in sessions.values.contains { $0.state == .working } }
			.removeDuplicates()
			.sink { [weak self] isWorking in self?.run(isWorking) }
	}

	/// - Parameter isDark: Whether the menu bar is dark. The number in the middle takes the text color of the menu bar.
	func image(workingCount: Int, isDark: Bool) -> NSImage {
		let key = "\(frame)-\(workingCount)-\(isDark)"
		if let image = cache[key] { return image }
		let image = Self.draw(frame: frame, workingCount: workingCount, isDark: isDark)
		cache[key] = image
		return image
	}

	private func run(_ isWorking: Bool) {
		timer?.invalidate()
		timer = nil
		guard isWorking else { return }
		timer = Timer.scheduledTimer(withTimeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
			Task { @MainActor in
				guard let self else { return }
				self.frame = (self.frame + 1) % Self.frameCount
			}
		}
	}

	/// The ring, the arc and the sparkle are orange, so that a working session stands out from the other icons in the
	/// menu bar. The number has the text color of the menu bar.
	private static func draw(frame: Int, workingCount: Int, isDark: Bool) -> NSImage {
		let size = NSSize(width: 18, height: 18)
		let image = NSImage(size: size, flipped: false) { _ in
			let center = NSPoint(x: size.width / 2, y: size.height / 2)
			let radius = 7.4
			let progress = Double(frame) / Double(frameCount)

			let track = NSBezierPath()
			track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
			track.lineWidth = 1.6
			color.withAlphaComponent(0.3).setStroke()
			track.stroke()

			let start = 90 - progress * 360
			let arc = NSBezierPath()
			arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: start - 110, clockwise: true)
			arc.lineWidth = 1.8
			arc.lineCapStyle = .round
			color.setStroke()
			arc.stroke()

			if workingCount > 1 {
				drawCount(workingCount, at: center, color: isDark ? .white : NSColor.black.withAlphaComponent(0.85))
			} else {
				// The sparkle twinkles: it grows and shrinks a little with each turn.
				drawSparkle(at: center, scale: 1 + 0.14 * sin(progress * 2 * .pi))
			}
			return true
		}
		return image
	}

	private static func drawSparkle(at center: NSPoint, scale: Double) {
		let configuration = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold).applying(NSImage.SymbolConfiguration(paletteColors: [color]))
		guard let sparkle = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
		let width = sparkle.size.width * scale
		let height = sparkle.size.height * scale
		sparkle.draw(in: NSRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height))
	}

	/// Centers the visible outline of the digits. The line box of the text has room for descenders, so centering it
	/// would put the digits too high.
	private static func drawCount(_ count: Int, at center: NSPoint, color: NSColor) {
		let text = count > 9 ? "9+" : "\(count)"
		let font = NSFont.monospacedDigitSystemFont(ofSize: count > 9 ? 6.5 : 9.5, weight: .bold)
		let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
		let outline = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
		guard let context = NSGraphicsContext.current?.cgContext else { return }
		context.textPosition = CGPoint(x: center.x - outline.midX, y: center.y - outline.midY)
		CTLineDraw(line, context)
	}
}
