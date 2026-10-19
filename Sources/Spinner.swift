import AppKit
import Combine

/// The menu bar spinner while sessions work: an arc that turns around a ring. In the middle, a sparkle for one working
/// session, or the number of working sessions.
@MainActor
final class Spinner: ObservableObject {
	static let shared = Spinner()

	private static let frameCount = 12
	private static let frameInterval = 0.1

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

	func image(workingCount: Int) -> NSImage {
		let key = "\(frame)-\(workingCount)"
		if let image = cache[key] { return image }
		let image = Self.draw(frame: frame, workingCount: workingCount)
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

	/// A template image, so that the menu bar colors it like the other icons.
	private static func draw(frame: Int, workingCount: Int) -> NSImage {
		let size = NSSize(width: 18, height: 18)
		let image = NSImage(size: size, flipped: false) { _ in
			let center = NSPoint(x: size.width / 2, y: size.height / 2)
			let radius = 7.4
			let progress = Double(frame) / Double(frameCount)

			let track = NSBezierPath()
			track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
			track.lineWidth = 1.6
			NSColor.black.withAlphaComponent(0.25).setStroke()
			track.stroke()

			let start = 90 - progress * 360
			let arc = NSBezierPath()
			arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: start - 110, clockwise: true)
			arc.lineWidth = 1.8
			arc.lineCapStyle = .round
			NSColor.black.setStroke()
			arc.stroke()

			if workingCount > 1 {
				drawCount(workingCount, at: center)
			} else {
				// The sparkle twinkles: it grows and shrinks a little with each turn.
				drawSparkle(at: center, scale: 1 + 0.14 * sin(progress * 2 * .pi))
			}
			return true
		}
		image.isTemplate = true
		return image
	}

	private static func drawSparkle(at center: NSPoint, scale: Double) {
		let configuration = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
		guard let sparkle = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
		let width = sparkle.size.width * scale
		let height = sparkle.size.height * scale
		sparkle.draw(in: NSRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height))
	}

	private static func drawCount(_ count: Int, at center: NSPoint) {
		let text = count > 9 ? "9+" : "\(count)"
		let font = NSFont.monospacedDigitSystemFont(ofSize: count > 9 ? 6.5 : 9.5, weight: .bold)
		let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
		let textSize = string.size()
		string.draw(at: NSPoint(x: center.x - textSize.width / 2, y: center.y - textSize.height / 2 + 0.5))
	}
}
