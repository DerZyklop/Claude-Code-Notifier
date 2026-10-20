import AppKit
import QuartzCore

/// The menu bar spinner while sessions work: an orange arc that turns around a faint orange ring. In the middle, a
/// sparkle for one working session, or the number of working sessions.
///
/// The middle is the template image of the button, so it takes the menu bar color. The ring and the arc are layers
/// above it, and Core Animation turns the arc. The window server runs that animation, so the app does no work per
/// frame.
@MainActor
final class Spinner {
	static let size = NSSize(width: 18, height: 18)
	private static let radius = 7.6
	private static let lineWidth = 2.6
	/// One turn in 1.2 s.
	private static let turnDuration = 1.2
	private static let color = NSColor.systemOrange

	private let ring = CAShapeLayer()
	private let arc = CAShapeLayer()
	private weak var button: NSStatusBarButton?
	private var cache: [Int: NSImage] = [:]

	init(button: NSStatusBarButton) {
		self.button = button
		button.wantsLayer = true
		let center = CGPoint(x: Self.size.width / 2, y: Self.size.height / 2)

		let circle = CGMutablePath()
		circle.addArc(center: center, radius: Self.radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
		ring.path = circle
		ring.strokeColor = Self.color.withAlphaComponent(0.3).cgColor

		// 130° of the ring, starting at the top.
		let part = CGMutablePath()
		part.addArc(center: center, radius: Self.radius, startAngle: .pi / 2, endAngle: .pi / 2 - 130 * .pi / 180, clockwise: true)
		arc.path = part
		arc.strokeColor = Self.color.cgColor
		arc.lineCap = .round

		for layer in [ring, arc] {
			layer.bounds = CGRect(origin: .zero, size: Self.size)
			layer.fillColor = nil
			layer.lineWidth = Self.lineWidth
			layer.isHidden = true
			button.layer?.addSublayer(layer)
		}
	}

	/// The sparkle or the number for the middle of the ring, as a template image for the button.
	func image(workingCount: Int) -> NSImage {
		let key = min(workingCount, 10)
		if let image = cache[key] { return image }
		let image = NSImage(size: Self.size, flipped: false) { rect in
			let center = NSPoint(x: rect.midX, y: rect.midY)
			if workingCount > 1 {
				Self.drawCount(workingCount, at: center)
			} else {
				Self.drawSparkle(at: center)
			}
			return true
		}
		image.isTemplate = true
		cache[key] = image
		return image
	}

	/// Shows the ring and the turning arc around the given image frame of the button, or hides them with `nil`.
	func show(around imageFrame: NSRect?) {
		guard let imageFrame else {
			ring.isHidden = true
			arc.isHidden = true
			arc.removeAllAnimations()
			return
		}
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		for layer in [ring, arc] {
			layer.position = CGPoint(x: imageFrame.midX, y: imageFrame.midY)
			layer.contentsScale = button?.window?.backingScaleFactor ?? 2
			layer.isHidden = false
		}
		CATransaction.commit()
		guard arc.animation(forKey: "turn") == nil else { return }
		let turn = CABasicAnimation(keyPath: "transform.rotation.z")
		// In a flipped view, the y axis points down, so a positive angle turns clockwise.
		turn.byValue = (button?.isFlipped ?? true) ? 2 * Double.pi : -2 * Double.pi
		turn.duration = Self.turnDuration
		turn.repeatCount = .infinity
		// 30 frames per second look smooth and keep the work of the window server low.
		if #available(macOS 12, *) {
			turn.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
		}
		arc.add(turn, forKey: "turn")
	}

	private static func drawSparkle(at center: NSPoint) {
		let configuration = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
		guard let sparkle = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
		sparkle.draw(in: NSRect(x: center.x - sparkle.size.width / 2, y: center.y - sparkle.size.height / 2, width: sparkle.size.width, height: sparkle.size.height))
	}

	/// Centers the visible outline of the digits. The line box of the text has room for descenders, so centering it
	/// would put the digits too high. The bubble of the waiting sessions uses it too, so both numbers have one size.
	static func drawCount(_ count: Int, at center: NSPoint, color: NSColor = .black) {
		let text = count > 9 ? "9+" : "\(count)"
		let font = NSFont.monospacedDigitSystemFont(ofSize: count > 9 ? 6.5 : 9.5, weight: .bold)
		let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
		let outline = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
		guard let context = NSGraphicsContext.current?.cgContext else { return }
		context.textPosition = CGPoint(x: center.x - outline.midX, y: center.y - outline.midY)
		CTLineDraw(line, context)
	}
}
